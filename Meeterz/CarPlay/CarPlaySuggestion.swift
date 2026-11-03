import CarPlay
import UIKit

/// Routenvorschlag in CarPlay: kurz nach dem Verbinden (ohne laufende Navigation) ein Hinweis auf der Karte –
/// „Arbeit · 24 Min. · Ankunft 08:12“ mit „Los“. Ein Tipp startet die Route direkt (eine Route, keine Auswahl).
extension CarPlayController {
    func offerRouteSuggestion() {
        Task { @MainActor [weak self] in
            // Standort und Sitzung brauchen nach dem Verbinden einen Moment
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.isConnected, !AppModel.shared.navigation.isNavigating,
                  let suggestion = await RouteSuggestions.shared.refresh(force: true),
                  !AppModel.shared.navigation.isNavigating,
                  await self.waitForAlertSlot(timeout: 20),
                  !AppModel.shared.navigation.isNavigating else { return }
            let go = CPAlertAction(title: String(localized: "Los"), style: .default) { [weak self] _ in
                Task { @MainActor in
                    Diag.log("Routenvorschlag angenommen: \(suggestion.title)")
                    self?.startGuidance(to: suggestion.place, showProgress: true)
                }
            }
            let no = CPAlertAction(title: String(localized: "Nein"), style: .cancel) { _ in }
            let icon: String
            if case .calendar = suggestion.reason { icon = "calendar" } else { icon = "clock.arrow.circlepath" }
            let alert = CPNavigationAlert(titleVariants: [suggestion.title],
                                          subtitleVariants: [suggestion.subtitle],
                                          image: UIImage(systemName: icon),
                                          primaryAction: go, secondaryAction: no, duration: 20)
            if CarPlayUI.shared.alert(alert) { Diag.log("Routenvorschlag gezeigt: \(suggestion.title)") }
        }
    }
}
