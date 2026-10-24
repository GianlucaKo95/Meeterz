import Foundation
import CoreLocation
import Observation
import SwiftUI

/// Parkplatz merken: Beim Trennen von CarPlay wird die Position gespeichert (nur auf dem Gerät).
@MainActor @Observable
final class ParkingStore {
    struct Spot: Codable, Equatable {
        let lat: Double
        let lng: Double
        let date: Date
        var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
        var place: Place { Place(id: "parked-car", name: "Dein Auto", address: nil, coordinate: coordinate) }
    }

    private(set) var spot: Spot? = {
        guard UserDefaults.standard.bool(forKey: "parking.enabled"),
              let data = UserDefaults.standard.data(forKey: "parking.spot") else { return nil }
        return try? JSONDecoder().decode(Spot.self, from: data)
    }()

    /// Einstellung „Geparktes Auto merken“ (Standard: aus)
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "parking.enabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "parking.enabled")
            if !newValue { AppModel.shared.parking.clear() }   // ausgeschaltet: gemerkten Platz verwerfen
        }
    }

    /// Nur speichern, wenn eingeschaltet und der Standort frisch und genau genug ist
    func save(_ location: CLLocation) {
        guard Self.enabled else { return }
        guard Date().timeIntervalSince(location.timestamp) < 5 * 60, location.horizontalAccuracy < 100 else {
            Diag.log("Parkplatz nicht gemerkt: Standort zu alt oder ungenau")
            return
        }
        spot = Spot(lat: location.coordinate.latitude, lng: location.coordinate.longitude, date: Date())
        persist()
        Diag.log("Parkplatz gemerkt")
    }

    func clear() {
        spot = nil
        persist()
    }

    private func persist() {
        if let spot, let data = try? JSONEncoder().encode(spot) {
            UserDefaults.standard.set(data, forKey: "parking.spot")
        } else {
            UserDefaults.standard.removeObject(forKey: "parking.spot")
        }
    }
}

/// Markierung „Dein Auto“ mit Menü: zu Fuß hin oder vergessen
struct ParkedCarMarker: View {
    @Environment(AppModel.self) private var app
    let spot: ParkingStore.Spot

    var body: some View {
        Menu {
            Button("Zu Fuß hinführen", systemImage: "figure.walk") {
                Task { await app.navigation.planRoute(to: spot.place, mode: .walk) }
            }
            Button("Parkplatz vergessen", systemImage: "trash", role: .destructive) { app.parking.clear() }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "car.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Theme.accent))
                    .overlay(Circle().stroke(Theme.ink, lineWidth: 2))
                Text("Dein Auto · \(Format.time.string(from: spot.date))")
                    .font(.caption2.bold())
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.panel))
            }
        }
        .accessibilityLabel("Dein Auto")
    }
}
