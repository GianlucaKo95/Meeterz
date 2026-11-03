import SwiftUI
import CoreLocation
import UserNotifications
import AVFoundation
import EventKit
import CoreMotion

/// Berechtigungen mit eigener Erklärseite davor: Erst sagt Meeterz in Ruhe, wofür es etwas braucht, dann kommt die
/// iOS-Abfrage. Apple achtet bei der Prüfung darauf (vor allem bei „Immer“), und es wird deutlich öfter zugestimmt.
/// Ist die Frage schon beantwortet, gibt es keine Erklärseite – nur das bisherige Ergebnis.
enum PermissionKind: String, Identifiable {
    case location, always, notifications, microphone, camera, calendar, motion
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .location: "location.fill"
        case .always: "location.circle.fill"
        case .notifications: "bell.badge.fill"
        case .microphone: "mic.fill"
        case .camera: "camera.fill"
        case .calendar: "calendar"
        case .motion: "figure.walk.motion"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .location: "Deinen Standort verwenden"
        case .always: "Auch im Hintergrund sichtbar sein"
        case .notifications: "Mitteilungen erlauben"
        case .microphone: "Mikrofon für Sprachschnipsel"
        case .camera: "Kamera für dein Profilfoto"
        case .calendar: "Termine als Ziele vorschlagen"
        case .motion: "Parkplatz automatisch merken"
        }
    }

    /// Wofür, in drei kurzen Punkten
    var points: [LocalizedStringKey] {
        switch self {
        case .location: ["Deine Position auf der Karte und die Navigation",
                         "Teilen nur mit Freunden, die du selbst freigibst",
                         "Pausieren oder Inkognito jederzeit möglich"]
        case .always: ["Freunde sehen dich auch, wenn Meeterz nicht offen ist – etwa während der Fahrt",
                       "CarPlay startet schneller, sobald du einsteigst",
                       "Wähle im nächsten Schritt „Immer erlauben“"]
        case .notifications: ["Freundschaftsanfragen und Nachrichten",
                              "Zusagen und Absagen zu Treffen",
                              "Keine Werbung"]
        case .microphone: ["Kurze Sprachschnipsel (höchstens 5 Sekunden) für deine Freunde",
                           "Nur während du aufnimmst"]
        case .camera: ["Ein Profilfoto, das nur deine Freunde sehen"]
        case .calendar: ["Termine mit Ort erscheinen in CarPlay, sobald du losfahren musst",
                         "Die Termine bleiben auf deinem iPhone"]
        case .motion: ["Meeterz erkennt den Wechsel vom Auto zum Gehen",
                       "So weißt du später, wo dein Auto steht"]
        }
    }
}

@MainActor
enum Permissions {
    /// Noch nie gefragt? Dann vorher die Erklärseite
    static func undetermined(_ kind: PermissionKind) async -> Bool {
        switch kind {
        case .location: return CLLocationManager().authorizationStatus == .notDetermined
        case .always: return AppModel.shared.location.authorization == .authorizedWhenInUse && !AppModel.shared.location.alwaysAskedBefore
        case .notifications: return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .notDetermined
        case .microphone: return AVAudioApplication.shared.recordPermission == .undetermined
        case .camera: return AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined
        case .calendar: return EKEventStore.authorizationStatus(for: .event) == .notDetermined
        case .motion: return CMMotionActivityManager.authorizationStatus() == .notDetermined
        }
    }

    /// Erlaubnis holen: beim ersten Mal mit Erklärseite, sonst direkt (ohne erneut zu fragen)
    static func ask(_ kind: PermissionKind) async -> Bool {
        if await undetermined(kind) {
            guard UIApplication.shared.applicationState == .active, let top = UIApplication.topViewController() else { return false }
            let proceed: Bool = await withCheckedContinuation { continuation in
                var finished = false
                let finish: (Bool) -> Void = { ok in
                    guard !finished else { return }
                    finished = true
                    top.presentedViewController?.dismiss(animated: true)
                    continuation.resume(returning: ok)
                }
                let host = UIHostingController(rootView: PermissionPrimer(kind: kind, finish: finish))
                host.modalPresentationStyle = .pageSheet
                host.sheetPresentationController?.detents = [.large()]
                host.isModalInPresentation = true
                top.present(host, animated: true)
            }
            Diag.log("Erklärseite \(kind.rawValue): \(proceed ? "weiter" : "nicht jetzt")")
            guard proceed else { return false }
            try? await Task.sleep(for: .milliseconds(450))   // Blatt zu, dann die iOS-Abfrage
        }
        return await request(kind)
    }

    /// Die eigentliche iOS-Abfrage (bzw. das bisherige Ergebnis)
    static func request(_ kind: PermissionKind) async -> Bool {
        switch kind {
        case .location:
            let location = AppModel.shared.location
            location.requestPermission()
            for _ in 0..<120 where location.authorization == .notDetermined { try? await Task.sleep(for: .milliseconds(500)) }
            return location.authorization == .authorizedWhenInUse || location.authorization == .authorizedAlways
        case .always:
            let location = AppModel.shared.location
            location.requestAlways()
            for _ in 0..<120 where location.authorization == .authorizedWhenInUse { try? await Task.sleep(for: .milliseconds(500)) }
            return location.authorization == .authorizedAlways
        case .notifications:
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            if granted { UIApplication.shared.registerForRemoteNotifications() }
            return granted
        case .microphone:
            return await AVAudioApplication.requestRecordPermission()
        case .camera:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .calendar:
            return await RouteSuggestions.shared.requestCalendarAccess()
        case .motion:
            // iOS fragt beim ersten Abruf der Bewegungsdaten
            let manager = CMMotionActivityManager()
            return await withCheckedContinuation { continuation in
                manager.queryActivityStarting(from: Date().addingTimeInterval(-60), to: Date(), to: .main) { _, error in
                    continuation.resume(returning: error == nil)
                }
            }
        }
    }
}

/// Die Erklärseite selbst
struct PermissionPrimer: View {
    let kind: PermissionKind
    let finish: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer(minLength: 20)
            Image(systemName: kind.symbol)
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 96, height: 96)
                .background(Circle().fill(Theme.panel))
                .frame(maxWidth: .infinity)
            Text(kind.title)
                .font(Theme.display(28))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(kind.points.enumerated()), id: \.offset) { _, point in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                        Text(point).font(Theme.title(16)).foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 18).fill(Theme.panel))
            Spacer()
            Button("Weiter") { finish(true) }
                .buttonStyle(PrimaryButtonStyle())
            Button("Nicht jetzt") { finish(false) }
                .font(Theme.title(15))
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity)
        }
        .padding(24)
        .background(Theme.ink.ignoresSafeArea())
    }
}
