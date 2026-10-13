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
    private var shownInvites = Set<UUID>()
    private var searchTask: Task<Void, Never>?
    private var searchCompletion: (([CPListItem]) -> Void)?

    private lazy var manager: CarPlayManager = {
        let m = CarPlayManager(navigationProvider: navigationProvider, styles: NavigationStyles.carPlay())
        m.delegate = self
        return m
    }()

    func connect(scene: CPTemplateApplicationScene, interfaceController: CPInterfaceController, window: CPWindow) {
        manager.delegate = self
        manager.templateApplicationScene(scene, didConnect: interfaceController, to: window)
        isConnected = true
        watchInvites()
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
        searchTask?.cancel()
        searchTask = nil
        searchCompletion = nil
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

        let inviteItems: [CPListItem] = model.meetups.incomingPending.map { meetup in
            let item = CPListItem(text: meetup.placeName, detailText: "Einladung von \(meetup.otherName)")
            item.handler = { [weak self] _, completion in
                self?.presentInvite(meetup)
                completion()
            }
            return item
        }

        var sections: [CPListSection] = []
        if !inviteItems.isEmpty { sections.append(CPListSection(items: inviteItems, header: "Einladungen", sectionIndexTitle: nil)) }
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

    // MARK: Einladungen empfangen

    /// Neue Einladungen als Hinweis mit Annehmen/Ablehnen anzeigen
    private func watchInvites() {
        guard isConnected else { return }
        withObservationTracking {
            _ = AppModel.shared.meetups.incomingPending
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.isConnected else { return }
                self.presentNewInvites()
                self.watchInvites()
            }
        }
        presentNewInvites()
    }

    private func presentNewInvites() {
        guard let controller = manager.interfaceController, controller.presentedTemplate == nil else { return }
        guard let meetup = AppModel.shared.meetups.incomingPending.first(where: { !shownInvites.contains($0.id) }) else { return }
        shownInvites.insert(meetup.id)
        presentInvite(meetup)
    }

    private func presentInvite(_ meetup: Meetup) {
        guard let controller = manager.interfaceController else { return }
        let alert = CPAlertTemplate(
            titleVariants: ["\(meetup.otherName) lädt dich ein: \(meetup.placeName)", "\(meetup.otherName) lädt dich ein"],
            actions: [
                CPAlertAction(title: "Annehmen", style: .default) { [weak self] _ in
                    self?.manager.interfaceController?.dismissTemplate(animated: true, completion: nil)
                    Task { @MainActor in
                        await AppModel.shared.meetups.respond(meetup, accept: true)
                        self?.go(to: meetup.place)
                    }
                },
                CPAlertAction(title: "Ablehnen", style: .cancel) { [weak self] _ in
                    self?.manager.interfaceController?.dismissTemplate(animated: true, completion: nil)
                    Task { @MainActor in await AppModel.shared.meetups.respond(meetup, accept: false) }
                },
            ]
        )
        controller.presentTemplate(alert, animated: true, completion: nil)
    }

    /// Läuft schon eine Navigation, wird der Ort Zwischenstopp, sonst Routenvorschau
    private func go(to place: Place) {
        if AppModel.shared.navigation.isNavigating {
            Task { await AppModel.shared.navigation.addStop(place) }
        } else {
            preview(to: place.coordinate, name: place.name) {}
        }
    }

    // MARK: Freunde einladen

    private var inviteDestination: Place? {
        AppModel.shared.navigation.destination ?? pendingDestination
    }

    private func showInviteList() {
        guard let place = inviteDestination, let controller = manager.interfaceController else { return }
        let friends = AppModel.shared.friends.accepted
        guard !friends.isEmpty else {
            showNotice("Du hast noch keine Freunde.")
            return
        }

        var items: [CPListItem] = friends.map { friend in
            let item = CPListItem(text: friend.displayName, detailText: "Einladen nach \(place.name)")
            item.handler = { [weak self] _, completion in
                self?.sendInvites(to: [friend.friendId], place: place)
                completion()
            }
            return item
        }
        if friends.count > 1 {
            let all = CPListItem(text: "Alle Freunde", detailText: nil)
            all.handler = { [weak self] _, completion in
                self?.sendInvites(to: friends.map(\.friendId), place: place)
                completion()
            }
            items.insert(all, at: 0)
        }
        let template = CPListTemplate(title: "Einladen", sections: [CPListSection(items: items)])
        controller.pushTemplate(template, animated: true, completion: nil)
    }

    private func sendInvites(to ids: [UUID], place: Place) {
        Task { @MainActor in
            var sent = 0
            for id in ids where await AppModel.shared.meetups.propose(to: id, place: place, silent: true) { sent += 1 }
            manager.interfaceController?.popTemplate(animated: true, completion: nil)
            showNotice(sent == 0 ? "Einladung fehlgeschlagen."
                                 : sent == 1 ? "Einladung gesendet." : "\(sent) Einladungen gesendet.")
        }
    }

    private func showNotice(_ text: String) {
        guard let controller = manager.interfaceController, controller.presentedTemplate == nil else { return }
        let alert = CPAlertTemplate(titleVariants: [text], actions: [
            CPAlertAction(title: "OK", style: .default) { [weak self] _ in
                self?.manager.interfaceController?.dismissTemplate(animated: true, completion: nil)
            }
        ])
        controller.presentTemplate(alert, animated: true, completion: nil)
    }

    // MARK: Suche (Tastatur im Stand, Diktat beim Fahren – das entscheidet CarPlay selbst)

    private func showSearch() {
        let template = CPSearchTemplate()
        template.delegate = self
        manager.interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }
}

extension CarPlayController: CPSearchTemplateDelegate {
    nonisolated func searchTemplate(
        _ searchTemplate: CPSearchTemplate,
        updatedSearchText searchText: String,
        completionHandler: @escaping ([CPListItem]) -> Void
    ) {
        MainActor.assumeIsolated {
            searchCompletion?([])
            searchTask?.cancel()
            searchCompletion = completionHandler
            let query = searchText.trimmingCharacters(in: .whitespaces)
            guard query.count >= 3 else {
                completionHandler([])
                searchCompletion = nil
                return
            }
            searchTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(350))   // Tippen bzw. Diktat abwarten
                guard !Task.isCancelled else { return }
                let near = AppModel.shared.location.lastLocation?.coordinate
                let places = (try? await SearchService.search(query, near: near)) ?? []
                guard !Task.isCancelled, let self else { return }
                let items: [CPListItem] = places.prefix(CPListTemplate.maximumItemCount).map { place in
                    let item = CPListItem(text: place.name, detailText: place.address)
                    item.userInfo = place
                    return item
                }
                self.searchCompletion?(items)
                self.searchCompletion = nil
            }
        }
    }

    nonisolated func searchTemplate(
        _ searchTemplate: CPSearchTemplate,
        selectedResult item: CPListItem,
        completionHandler: @escaping () -> Void
    ) {
        MainActor.assumeIsolated {
            guard let place = item.userInfo as? Place else { completionHandler(); return }
            manager.interfaceController?.popToRootTemplate(animated: true, completion: nil)
            preview(to: place.coordinate, name: place.name, completion: completionHandler)
        }
    }
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
            switch activity {
            case .browsing:
                let search = CPBarButton(title: "Suche") { [weak self] _ in self?.showSearch() }
                let goals = CPBarButton(title: "Ziele") { [weak self] _ in
                    guard let self else { return }
                    manager.interfaceController?.pushTemplate(destinationsTemplate(), animated: true, completion: nil)
                }
                return [search, goals]
            case .previewing, .navigating:
                // Einladen nur, wenn es ein Ziel und Freunde gibt
                guard inviteDestination != nil, !AppModel.shared.friends.accepted.isEmpty else { return nil }
                let invite = CPBarButton(title: "Einladen") { [weak self] _ in self?.showInviteList() }
                return [invite]
            case .panningInBrowsingMode, .panningInNavigationMode:
                return nil
            }
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
