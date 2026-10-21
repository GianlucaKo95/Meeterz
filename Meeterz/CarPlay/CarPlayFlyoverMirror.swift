import UIKit
import MapKit
import Combine
import CoreLocation
import MapboxMaps
import MapboxNavigationCore

/// Apple-Flyover-Karte auf CarPlay.
///
/// Die Mapbox-Navigation (Abbiegehinweise, Routenvorschau, Ankunft, Umleitung …) läuft unverändert weiter.
/// Über ihre Karte legen wir eine MapKit-Karte mit Flyover-Satellitenbild, deren Kamera der Mapbox-Kamera folgt.
/// Route, Standort, Freunde und Treffpunkte zeichnet die MapKit-Karte selbst – so passen sie genau auf das Bild.
@MainActor
final class CarPlayFlyoverMirror: NSObject, MKMapViewDelegate {
    /// In den iPhone-Einstellungen („Karte in CarPlay“) abschaltbar
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: "carplay.flyover") as? Bool ?? true }

    let mapView = MKMapView()

    private let friendsVisible: () -> Bool
    private weak var mapbox: NavigationMapView?
    private var cameraToken: Cancelable?
    private var lastApply = Date.distantPast
    private var cameraHeading: CLLocationDirection = 0
    private var subscriptions = Set<AnyCancellable>()
    private var timer: Timer?
    private var attachTask: Task<Void, Never>?
    private var trailing: Task<Void, Never>?
    private var syncTimer: Timer?

    private var activeRoutes: NavigationRoutes?
    private var previewRoutes: NavigationRoutes?
    private var routeOverlays: [MKOverlay] = []
    private var friendOverlays: [MKOverlay] = []
    private var pins: [String: MapPin] = [:]
    private var userArrow: UIImageView?

    init(friendsVisible: @escaping () -> Bool) {
        self.friendsVisible = friendsVisible
        super.init()
        mapView.delegate = self
        mapView.mapType = .hybridFlyover
        mapView.showsUserLocation = true
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.isUserInteractionEnabled = false      // Bedienung läuft über CarPlay (und damit die Mapbox-Kamera)
        mapView.pointOfInterestFilter = MKPointOfInterestFilter(including: [.restaurant, .cafe, .parking, .gasStation, .publicTransport, .hospital])
        observeRoutes()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshFriends() }
        }
        refreshFriends()
    }

    // MARK: Einbinden

    /// Legt die Flyover-Karte direkt über die Mapbox-Karte (unter Tempolimit, Straßenname und Co.) und folgt ihrer Kamera.
    func attach(to navigationMapView: NavigationMapView) {
        attachTask?.cancel()
        attachTask = Task { @MainActor [weak self] in
            // Die Ansicht hängt kurz nach dem Aufbau noch nicht im Fenster
            for _ in 0..<20 {
                guard let self, !Task.isCancelled else { return }
                if let parent = navigationMapView.superview {
                    self.install(in: parent, above: navigationMapView)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func install(in parent: UIView, above navigationMapView: NavigationMapView) {
        mapbox = navigationMapView
        mapView.removeFromSuperview()
        mapView.translatesAutoresizingMaskIntoConstraints = false
        parent.insertSubview(mapView, aboveSubview: navigationMapView)
        NSLayoutConstraint.activate([
            mapView.leadingAnchor.constraint(equalTo: navigationMapView.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: navigationMapView.trailingAnchor),
            mapView.topAnchor.constraint(equalTo: navigationMapView.topAnchor),
            mapView.bottomAnchor.constraint(equalTo: navigationMapView.bottomAnchor),
        ])
        parent.layoutIfNeeded()

        let map = navigationMapView.mapView.mapboxMap
        cameraToken?.cancel()
        cameraToken = map?.onCameraChanged.observe { [weak self] event in
            MainActor.assumeIsolated { self?.apply(event.cameraState, force: false) }
        }
        if let state = map?.cameraState { apply(state, force: true) }
        // Sicherheitsnetz: Kamera alle 0,5 s abgleichen, falls ein Ereignis ausbleibt
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let s = self.mapbox?.mapView.mapboxMap?.cameraState else { return }
                self.apply(s, force: false)
            }
        }
        redrawRoutes()
    }

    func detach() {
        attachTask?.cancel()
        cameraToken?.cancel()
        cameraToken = nil
        syncTimer?.invalidate()
        trailing?.cancel()
        timer?.invalidate()
        timer = nil
        subscriptions.removeAll()
        mapView.removeFromSuperview()
    }

    // MARK: Kamera

    /// Übersetzt die Mapbox-Kamera (Mitte, Zoom, Drehung, Neigung, Rand) in eine MapKit-Kamera.
    private func apply(_ state: CameraState, force: Bool) {
        guard force || Date().timeIntervalSince(lastApply) > 0.1 else {
            // Gedrosselt: den letzten Stand nachholen, sonst bleibt die Karte beim Ruhigwerden der Kamera stehen
            trailing?.cancel()
            trailing = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, !Task.isCancelled, let s = self.mapbox?.mapView.mapboxMap?.cameraState else { return }
                self.apply(s, force: true)
            }
            return
        }
        let size = mapView.bounds.size
        guard size.height > 1 else { return }
        lastApply = Date()

        let center = state.center
        // Meter je Punkt in Bildmitte (Mapbox: 512 Punkte Weltbreite bei Zoom 0)
        let metersPerPoint = 40_075_016.686 * cos(center.latitude * .pi / 180) / (512 * pow(2, state.zoom))
        var target = center
        // Die Mapbox-Kamera setzt ihre Mitte in den Bereich innerhalb des Randes (z. B. Standort weiter unten);
        // MapKit zentriert auf die Bildmitte – also um den halben Randunterschied nach vorne verschieben.
        let dy = Double(state.padding.top - state.padding.bottom) / 2
        if abs(dy) > 1 { target = Self.offset(center, bearing: state.bearing, meters: dy * metersPerPoint) }

        // Abstand so, dass der Maßstab in Bildmitte etwa dem der Mapbox-Karte entspricht
        let distance = min(max(1.5 * Double(size.height) * metersPerPoint * 1.2, 80), 80_000)
        let camera = MKMapCamera(
            lookingAtCenter: target,
            fromDistance: distance,
            pitch: CGFloat(min(max(state.pitch, 0), 75)),
            heading: state.bearing
        )
        mapView.setCamera(camera, animated: false)
        cameraHeading = state.bearing
        updateArrow()
    }

    private static func offset(_ c: CLLocationCoordinate2D, bearing: Double, meters: Double) -> CLLocationCoordinate2D {
        let b = bearing * .pi / 180
        let dLat = meters * cos(b) / 111_320
        let dLon = meters * sin(b) / (111_320 * max(cos(c.latitude * .pi / 180), 0.01))
        return CLLocationCoordinate2D(latitude: c.latitude + dLat, longitude: c.longitude + dLon)
    }

    // MARK: Route

    private func observeRoutes() {
        let core = navigationProvider.mapboxNavigation
        core.tripSession().navigationRoutes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] routes in
                self?.activeRoutes = routes
                self?.redrawRoutes()
            }
            .store(in: &subscriptions)
        // Befahrener Teil verschwindet: Route alle 2 s ab der aktuellen Position neu zeichnen
        core.navigation().routeProgress
            .compactMap { $0?.routeProgress }
            .throttle(for: .seconds(2), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.redrawRoutes() }
            .store(in: &subscriptions)
    }

    func showPreview(_ routes: NavigationRoutes?) {
        previewRoutes = routes
        redrawRoutes()
    }

    private func redrawRoutes() {
        mapView.removeOverlays(routeOverlays)
        routeOverlays = []
        guard let routes = activeRoutes ?? previewRoutes else { return }
        let navigating = activeRoutes != nil

        var overlays: [MKOverlay] = []
        if !navigating {
            for alt in routes.alternativeRoutes {
                guard let coords = alt.route.shape?.coordinates, coords.count > 1 else { continue }
                overlays += Self.styled(coords, color: UIColor(white: 0.75, alpha: 1), width: 7, casing: 11)
            }
        }
        if var coords = routes.mainRoute.route.shape?.coordinates, coords.count > 1 {
            if navigating, let me = AppModel.shared.location.lastLocation?.coordinate {
                coords = Self.remaining(coords, from: me)
            }
            if coords.count > 1 {
                overlays += Self.styled(coords, color: UIColor(red: 0.20, green: 0.55, blue: 1.0, alpha: 1), width: 10, casing: 14)
            }
        }
        routeOverlays = overlays
        for o in overlays { mapView.addOverlay(o, level: .aboveRoads) }
    }

    /// Route ab dem Punkt, der der Position am nächsten liegt
    private static func remaining(_ coords: [CLLocationCoordinate2D], from me: CLLocationCoordinate2D) -> [CLLocationCoordinate2D] {
        let here = CLLocation(latitude: me.latitude, longitude: me.longitude)
        var best = 0
        var bestDistance = CLLocationDistance.greatestFiniteMagnitude
        for (i, c) in coords.enumerated() {
            let d = here.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
            if d < bestDistance { bestDistance = d; best = i }
        }
        return Array(coords[best...])
    }

    private static func styled(_ coords: [CLLocationCoordinate2D], color: UIColor, width: CGFloat, casing: CGFloat) -> [MKOverlay] {
        var c = coords
        let outline = StyledPolyline(coordinates: &c, count: c.count)
        outline.color = UIColor(red: 0.02, green: 0.04, blue: 0.07, alpha: 0.92)
        outline.width = casing
        let line = StyledPolyline(coordinates: &c, count: c.count)
        line.color = color
        line.width = width
        return [outline, line]
    }

    // MARK: Freunde und Treffpunkte

    func refreshFriends() {
        mapView.removeOverlays(friendOverlays)
        friendOverlays = []
        let model = AppModel.shared
        let show = friendsVisible()

        var wanted: [String: (coordinate: CLLocationCoordinate2D, kind: MapPin.Kind)] = [:]
        if show {
            for route in model.routes.friendRoutes.values where route.coordinates.count > 1 {
                friendOverlays += Self.styled(route.coordinates, color: FriendPalette.routeUIColor(for: route.friendId), width: 7, casing: 11)
            }
            for item in model.friendsOnMap {
                wanted["friend-\(item.friend.friendId)"] = (item.position.coordinate, .friend(item))
            }
        }
        for meetup in model.meetups.accepted {
            wanted["meetup-\(meetup.id)"] = (meetup.coordinate, .meetup(meetup.placeName))
        }
        for o in friendOverlays { mapView.insertOverlay(o, at: 0, level: .aboveRoads) }

        // Pins abgleichen
        for (key, pin) in pins where wanted[key] == nil {
            mapView.removeAnnotation(pin)
            pins.removeValue(forKey: key)
        }
        for (key, value) in wanted {
            if let pin = pins[key] {
                pin.coordinate = value.coordinate
                pin.kind = value.kind
                (mapView.view(for: pin))?.image = pin.image()
            } else {
                let pin = MapPin(kind: value.kind)
                pin.coordinate = value.coordinate
                pins[key] = pin
                mapView.addAnnotation(pin)
            }
        }
        redrawRoutes()
    }

    // MARK: Standortpfeil

    private func updateArrow() {
        guard let arrow = userArrow else { return }
        let course = mapView.userLocation.location?.course ?? -1
        guard course >= 0 else { arrow.transform = .identity; return }
        arrow.transform = CGAffineTransform(rotationAngle: CGFloat((course - cameraHeading) * .pi / 180))
    }

    private static let arrowImage: UIImage = {
        let size = CGSize(width: 52, height: 52)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 26, y: 4))
            path.addLine(to: CGPoint(x: 44, y: 46))
            path.addLine(to: CGPoint(x: 26, y: 37))
            path.addLine(to: CGPoint(x: 8, y: 46))
            path.close()
            c.setShadow(offset: .zero, blur: 6, color: UIColor.black.withAlphaComponent(0.5).cgColor)
            UIColor.white.setStroke()
            UIColor(red: 0.20, green: 0.55, blue: 1.0, alpha: 1).setFill()
            path.lineWidth = 4
            path.lineJoinStyle = .round
            path.fill()
            path.stroke()
        }
    }()

    // MARK: MKMapViewDelegate

    nonisolated func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        guard let line = overlay as? StyledPolyline else { return MKOverlayRenderer(overlay: overlay) }
        let renderer = MKPolylineRenderer(polyline: line)
        renderer.strokeColor = line.color
        renderer.lineWidth = line.width
        renderer.lineCap = .round
        renderer.lineJoin = .round
        return renderer
    }

    nonisolated func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        MainActor.assumeIsolated {
            if annotation is MKUserLocation {
                let id = "me"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.canShowCallout = false
                view.subviews.forEach { $0.removeFromSuperview() }
                view.frame = CGRect(x: 0, y: 0, width: 52, height: 52)
                let arrow = UIImageView(image: Self.arrowImage)
                arrow.frame = view.bounds
                view.addSubview(arrow)
                userArrow = arrow
                updateArrow()
                return view
            }
            guard let pin = annotation as? MapPin else { return nil }
            let id = "pin"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) ?? MKAnnotationView(annotation: pin, reuseIdentifier: id)
            view.annotation = pin
            view.canShowCallout = false
            view.image = pin.image()
            view.centerOffset = CGPoint(x: 0, y: -(view.image?.size.height ?? 0) / 2)
            view.displayPriority = .required
            return view
        }
    }

    nonisolated func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
        MainActor.assumeIsolated { updateArrow() }
    }
}

/// Linie mit Farbe und Breite (zum Zeichnen mit Umrandung braucht jede Route zwei davon)
final class StyledPolyline: MKPolyline {
    var color = UIColor.systemBlue
    var width: CGFloat = 8
}

/// Freund oder Treffpunkt auf der Karte
final class MapPin: MKPointAnnotation {
    enum Kind {
        case friend(AppModel.FriendOnMap)
        case meetup(String)
    }

    var kind: Kind

    init(kind: Kind) {
        self.kind = kind
        super.init()
    }

    @MainActor
    func image() -> UIImage {
        switch kind {
        case .friend(let item):
            let stale = item.position.age > 5 * 60
            let photo = AppModel.shared.avatars.image(for: item.friend.friendId)
            let avatar = AvatarRenderer.image(
                initials: item.friend.initials,
                color: FriendPalette.uiColor(for: item.friend.friendId),
                faded: stale, photo: photo)
            return Self.compose(avatar: avatar, text: "\(item.friend.displayName) · \(Format.age(item.position.age))")
        case .meetup(let name):
            return Self.compose(avatar: AvatarRenderer.meetupPin(), text: name)
        }
    }

    /// Symbol mit Namensschild darunter
    @MainActor
    private static func compose(avatar: UIImage, text: String) -> UIImage {
        let font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let pill = CGSize(width: textSize.width + 16, height: textSize.height + 6)
        let size = CGSize(width: max(avatar.size.width, pill.width), height: avatar.size.height + 2 + pill.height)
        return UIGraphicsImageRenderer(size: size).image { _ in
            avatar.draw(at: CGPoint(x: (size.width - avatar.size.width) / 2, y: 0))
            let rect = CGRect(x: (size.width - pill.width) / 2, y: avatar.size.height + 2, width: pill.width, height: pill.height)
            UIColor(red: 0.05, green: 0.07, blue: 0.09, alpha: 0.9).setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: pill.height / 2).fill()
            (text as NSString).draw(at: CGPoint(x: rect.minX + 8, y: rect.minY + 3), withAttributes: attrs)
        }
    }
}
