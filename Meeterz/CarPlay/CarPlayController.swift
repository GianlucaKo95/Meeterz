import Foundation
import UIKit
import CarPlay
import CoreLocation
import MapboxDirections
import MapboxNavigationCore
import MapboxNavigationUIKit

/// CarPlay-Szene. Wird über Info.plist (UIApplicationSceneManifest) eingebunden.
final class CarPlaySceneDelegate: NSObject, CPTemplateApplicationSceneDelegate {
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
        to window: CPWindow
    ) {
        MainActor.assumeIsolated {
            CarPlayController.shared.connect(scene: templateApplicationScene, interfaceController: interfaceController, window: window)
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController,
        from window: CPWindow
    ) {
        MainActor.assumeIsolated {
            CarPlayController.shared.disconnect(scene: templateApplicationScene, interfaceController: interfaceController, window: window)
        }
    }
}

/// Karte mit Freunden, Navigation (über Mapbox CarPlayManager), Freundesliste als Ziele.
@MainActor
final class CarPlayController: NSObject {
    static let shared = CarPlayController()

    private(set) var isConnected = false
    private var friendsVisible = true
    private var browseOverlay: FriendOverlay?
    private var navigationOverlay: FriendOverlay?

    private lazy var manager: CarPlayManager = {
        let m = CarPlayManager(navigationProvider: navigationProvider, styles: NavigationStyles.carPlay())
        m.delegate = self
        return m
    }()

    func connect(scene: CPTemplateApplicationScene, interfaceController: CPInterfaceController, window: CPWindow) {
        manager.delegate = self
        manager.templateApplicationScene(scene, didConnect: interfaceController, to: window)
        isConnected = true
        // Läuft auf dem iPhone schon eine Navigation, übernimmt CarPlay sie
        if AppModel.shared.navigation.isNavigating {
            beginNavigationIfConnected()
        }
    }

    func disconnect(scene: CPTemplateApplicationScene, interfaceController: CPInterfaceController, window: CPWindow) {
        browseOverlay?.stop()
        navigationOverlay?.stop()
        browseOverlay = nil
        navigationOverlay = nil
        manager.templateApplicationScene(scene, didDisconnect: interfaceController, from: window)
        manager.delegate = nil
        isConnected = false
    }

    func beginNavigationIfConnected() {
        guard isConnected, manager.currentActivity != .navigating,
              let location = AppModel.shared.location.lastLocation
        else { return }
        manager.beginNavigationWithCarPlay(using: location.coordinate)
    }

    func endNavigationIfNeeded() {
        guard isConnected, manager.currentActivity == .navigating else { return }
        manager.carPlayNavigationViewController?.exitNavigation(byCanceling: true)
    }

    // MARK: Freunde-Schaltfläche und Freundesliste

    private func friendsButton() -> CPMapButton {
        let button = CPMapButton { [weak self] _ in
            guard let self else { return }
            friendsVisible.toggle()
            browseOverlay?.refresh()
            navigationOverlay?.refresh()
            if let template = manager.interfaceController?.topTemplate as? CPMapTemplate {
                manager.resetPanButtons(template)
            }
        }
        let symbol = friendsVisible ? "person.2.fill" : "person.2.slash"
        button.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold))
        return button
    }

    /// Ziele aus Meeterz: vereinbarte Treffpunkte und Freunde
    private func destinationsTemplate() -> CPListTemplate {
        let model = AppModel.shared

        let meetupItems: [CPListItem] = model.meetups.accepted.map { meetup in
            let item = CPListItem(text: meetup.placeName, detailText: "Treffen mit \(meetup.otherName)")
            item.handler = { [weak self] _, completion in
                self?.preview(to: meetup.coordinate, name: meetup.placeName, completion: completion)
            }
            return item
        }

        let friendItems: [CPListItem] = model.friendsOnMap.map { item in
            let route = model.routes.friendRoutes[item.friend.friendId]
            let detail = route.flatMap { r in r.destinationName.map { "Unterwegs nach \($0)" } } ?? "Zum aktuellen Standort"
            let listItem = CPListItem(text: item.friend.displayName, detailText: detail)
            listItem.handler = { [weak self] _, completion in
                self?.preview(to: item.position.coordinate, name: item.friend.displayName, completion: completion)
            }
            return listItem
        }

        var sections: [CPListSection] = []
        if !meetupItems.isEmpty { sections.append(CPListSection(items: meetupItems, header: "Treffpunkte", sectionIndexTitle: nil)) }
        sections.append(CPListSection(items: friendItems.isEmpty
            ? [CPListItem(text: "Gerade ist niemand unterwegs", detailText: nil)]
            : friendItems,
            header: "Freunde", sectionIndexTitle: nil))
        return CPListTemplate(title: "Meeterz", sections: sections)
    }

    private func preview(to coordinate: CLLocationCoordinate2D, name: String, completion: @escaping () -> Void) {
        let waypoint = Waypoint(coordinate: coordinate, name: name)
        pendingDestination = Place(id: UUID().uuidString, name: name, address: nil, coordinate: coordinate)
        manager.previewRoutes(to: waypoint, completionHandler: completion)
    }

    private var pendingDestination: Place?
}

extension CarPlayController: CarPlayManagerDelegate {
    nonisolated func carPlayManager(_ carPlayManager: CarPlayManager, didSetup navigationMapView: NavigationMapView) {
        MainActor.assumeIsolated {
            browseOverlay?.stop()
            let overlay = FriendOverlay(mapView: navigationMapView.mapView) { [weak self] in self?.friendsVisible ?? true }
            overlay.start()
            browseOverlay = overlay
        }
    }

    nonisolated func carPlayManager(
        _ carPlayManager: CarPlayManager,
        didPresent navigationViewController: CarPlayNavigationViewController
    ) {
        MainActor.assumeIsolated {
            navigationViewController.routeLineTracksTraversal = true
            guard let mapView = navigationViewController.navigationMapView?.mapView else { return }
            navigationOverlay?.stop()
            let overlay = FriendOverlay(mapView: mapView) { [weak self] in self?.friendsVisible ?? true }
            overlay.start()
            navigationOverlay = overlay
        }
    }

    nonisolated func carPlayManager(
        _ carPlayManager: CarPlayManager,
        mapButtonsCompatibleWith traitCollection: UITraitCollection,
        in template: CPTemplate,
        for activity: CarPlayActivity
    ) -> [CPMapButton]? {
        MainActor.assumeIsolated {
            switch activity {
            case .browsing:
                guard let map = carPlayManager.carPlayMapViewController else { return nil }
                // Zentrieren auf den Live-Standort, Freunde ein/aus, Zoom
                return [map.recenterButton, friendsButton(), map.zoomInButton, map.zoomOutButton]
            case .navigating, .previewing, .panningInBrowsingMode, .panningInNavigationMode:
                return nil
            }
        }
    }

    nonisolated func carPlayManager(
        _ carPlayManager: CarPlayManager,
        trailingNavigationBarButtonsCompatibleWith traitCollection: UITraitCollection,
        in template: CPMapTemplate,
        for activity: CarPlayActivity
    ) -> [CPBarButton]? {
        MainActor.assumeIsolated {
            guard activity == .browsing else { return nil }
            let button = CPBarButton(title: "Ziele") { [weak self] _ in
                guard let self else { return }
                manager.interfaceController?.pushTemplate(destinationsTemplate(), animated: true, completion: nil)
            }
            return [button]
        }
    }

    nonisolated func carPlayManagerDidBeginNavigation(_ carPlayManager: CarPlayManager) {
        MainActor.assumeIsolated {
            let coordinator = AppModel.shared.navigation
            if !coordinator.isNavigating {
                coordinator.didBeginOnCarPlay(destination: pendingDestination)
            }
        }
    }

    nonisolated func carPlayManagerDidEndNavigation(_ carPlayManager: CarPlayManager, byCanceling canceled: Bool) {
        MainActor.assumeIsolated {
            navigationOverlay?.stop()
            navigationOverlay = nil
            pendingDestination = nil
            AppModel.shared.navigation.stop()
        }
    }

    nonisolated func carPlayManager(_ carPlayManager: CarPlayManager, shouldPresentArrivalUIFor waypoint: Waypoint) -> Bool {
        true
    }
}
