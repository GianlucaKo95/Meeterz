import Foundation
import UIKit
import CoreLocation
import MapboxMaps
import MapboxNavigationCore

/// Kamera-Nachführung für die CarPlay-Karte, die nie anhält.
///
/// Ursache für „Pfeil läuft flüssig, Karte zieht ruckartig nach“: Mapbox' Standard-Nachführung
/// (`NavigationCameraStateTransition`) gleitet nach jeder Standortmeldung genau 1,0 s lang zum neuen Punkt.
/// Die Meldungen kommen aber nicht exakt im Sekundentakt (1,1 s, 1,4 s, manchmal 2 s). Dann steht die Karte
/// zwischendurch still, während der Pfeil (eigene, fließende Einpassung) weiterfährt – bis die nächste Meldung
/// die Karte wieder anschiebt. Hier dauert jedes Nachgleiten etwas länger als der gemessene Abstand der
/// Meldungen: Die Karte ist immer in Bewegung und wird von der nächsten Meldung nahtlos übernommen.
///
/// Übergänge zwischen Zuständen (Folgen ↔ Übersicht) bleiben bei Mapbox' Standard.
final class SmoothCameraTransition: CameraStateTransition {
    weak var mapView: MapView?
    private let standard: NavigationCameraStateTransition

    private var center: BasicCameraAnimator?
    private var bearing: BasicCameraAnimator?
    private var zoom: BasicCameraAnimator?
    private var pitch: BasicCameraAnimator?
    private var framing: BasicCameraAnimator?
    private var previousAnchor: CGPoint?

    private var lastUpdate: Date?
    /// Geglätteter Abstand zwischen zwei Standortmeldungen
    private var interval: TimeInterval = 1.0

    required init(_ mapView: MapView) {
        self.mapView = mapView
        standard = NavigationCameraStateTransition(mapView)
    }

    func transitionTo(_ cameraOptions: CameraOptions, completion: @escaping () -> Void) {
        stopAll()
        lastUpdate = nil
        previousAnchor = cameraOptions.anchor
        standard.transitionTo(cameraOptions, completion: completion)
    }

    func cancelPendingTransition() {
        standard.cancelPendingTransition()
        stopAll()
    }

    /// Zoom ist fest vorgegeben (Fahrer hat gezoomt oder Heranzoomen vor dem Manöver)? Dann folgt die Kamera dem
    /// Standort selbst statt Mapbox' vorausschauendem Mittelpunkt.
    var zoomPinned: () -> Bool = { false }

    func update(to cameraOptions: CameraOptions, state: NavigationCameraState) {
        guard let mapView, var target = cameraOptions.center, CLLocationCoordinate2DIsValid(target) else { return }
        // Übersicht (Route im Ganzen) wie bei Mapbox: dort zählt das Einrahmen, nicht das Mitlaufen
        guard state == .following else { standard.update(to: cameraOptions, state: state); return }

        // Ursache für „Pfeil verschwindet beim Heranzoomen hinter dem Straßennamen“: Während der Navigation setzt
        // Mapbox den Mittelpunkt nicht auf den Standort, sondern ein Stück die Route voraus und legt diesen Punkt
        // unten ins Bild. Das passt nur zu Mapbox' eigenem Zoom (der rahmt die Strecke so, dass der Standort sichtbar
        // bleibt). Ist der Zoom fest und nah, liegt der Standort weit UNTER dem Mittelpunkt – unter dem Straßenschild
        // oder außerhalb. Bei festem Zoom darum den Standort selbst als Mittelpunkt nehmen.
        if zoomPinned(), let here = navigationProvider.mapboxNavigation.navigation().currentLocationMatching?.enhancedLocation.coordinate,
           CLLocationCoordinate2DIsValid(here) {
            target = here
        }

        let now = Date()
        if let last = lastUpdate {
            let gap = now.timeIntervalSince(last)
            if gap > 0.2, gap < 4 { interval = interval * 0.7 + gap * 0.3 }
        }
        lastUpdate = now
        // Etwas länger als bis zur nächsten Meldung: läuft weiter, bis sie kommt (dann nahtlose Übernahme)
        let duration = min(max(interval * 1.2, 0.8), 3.0)
        let camera = mapView.mapboxMap.cameraState

        // Mitte: nur bei merklicher Bewegung (wie Mapbox: 2 Pixel)
        let zoomLevel = cameraOptions.zoom ?? camera.zoom
        let metersPerPixel = 156_543.03 * cos(target.latitude * .pi / 180) / pow(2, zoomLevel)
        if camera.center.distance(to: target) > 2 * metersPerPixel {
            center = restart(center, duration) { $0.center.toValue = target }
        }
        if let value = cameraOptions.bearing, abs(Self.angle(camera.bearing, value)) >= 1 {
            bearing = restart(bearing, duration) { $0.bearing.toValue = value }
        }
        // Zoom, Neigung, Rahmen ändern sich selten – wie bei Mapbox in 1 s
        if let value = cameraOptions.zoom, abs(camera.zoom - value) > 0.01 {
            zoom = restart(zoom, 1.0) { $0.zoom.toValue = value }
        }
        if let value = cameraOptions.pitch, abs(camera.pitch - value) >= 1 {
            pitch = restart(pitch, 1.0) { $0.pitch.toValue = value }
        }
        let anchorChanged = cameraOptions.anchor != nil && cameraOptions.anchor != previousAnchor
        let paddingChanged = cameraOptions.padding.map { $0 != camera.padding } ?? false
        if anchorChanged || paddingChanged {
            previousAnchor = cameraOptions.anchor ?? previousAnchor
            let anchor = cameraOptions.anchor, padding = cameraOptions.padding
            framing = restart(framing, 1.0) {
                if let anchor { $0.anchor.toValue = anchor }
                if let padding { $0.padding.toValue = padding }
            }
        }
    }

    // MARK: -

    private func restart(_ animator: BasicCameraAnimator?, _ duration: TimeInterval,
                         _ change: @escaping (inout CameraTransition) -> Void) -> BasicCameraAnimator? {
        if let animator, animator.isRunning { animator.stopAnimation() }
        guard let mapView else { return nil }
        // Gleichmäßig (linear): keine Abbrems-/Anfahrbewegung an jeder Meldung
        let next = mapView.camera.makeAnimator(duration: duration, curve: .linear, animations: change)
        next.startAnimation()
        return next
    }

    private func stopAll() {
        for animator in [center, bearing, zoom, pitch, framing] where animator?.isRunning == true {
            animator?.stopAnimation()
        }
        center = nil; bearing = nil; zoom = nil; pitch = nil; framing = nil
    }

    /// Kürzester Winkel von a nach b (−180…180)
    private static func angle(_ a: Double, _ b: Double) -> Double {
        (b - a + 540).truncatingRemainder(dividingBy: 360) - 180
    }
}
