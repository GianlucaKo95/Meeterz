import UIKit
import MapKit
import Combine
import CoreLocation
import MapboxMaps
import MapboxNavigationCore
import MapboxDirections

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
    /// Gleicht die Kamera bei jedem Bild des Autodisplays ab (vorher 10-mal pro Sekunde – ruckelte wie ein Daumenkino)
    private var displayLink: CADisplayLink?
    private struct CameraKey: Equatable { let lat, lng, zoom, bearing, pitch, top, bottom: Double }
    private var lastCamera: CameraKey?
    private var puckToken: Cancelable?
    /// Weich animierter Standort des Mapbox-Pfeils (statt roher GPS-Sprünge)
    private var puck: (coordinate: CLLocationCoordinate2D, bearing: Double?)?

    private var activeRoutes: NavigationRoutes?
    private var previewRoutes: NavigationRoutes?
    private var routeOverlays: [MKOverlay] = []
    private var friendOverlays: [MKOverlay] = []
    private var pins: [String: MapPin] = [:]
    private var userArrow: UIImageView?

    /// Eigene Ebene über der 3D-Karte: Route und Standortpfeil.
    /// MapKit legt Linien auf den Boden – Flyover-Bäume und -Gebäude verdecken sie dann (nah herangezoomt
    /// verschwand die Route). In dieser Ebene liegt sie immer obenauf, wie bei Apple Karten.
    private let routeView = UIView()
    private let casingLayer = CAShapeLayer()
    private let lineLayer = CAShapeLayer()
    private let arrowLayer = CALayer()
    /// Hauptroute, auf höchstens 25 m Punktabstand verdichtet (sonst fielen lange Geraden hinter der Kamera weg)
    private var mainLine: [CLLocationCoordinate2D] = []
    /// Verkehrslage je Abschnitt (gilt vom Punkt i bis i+1), gleich lang wie `mainLine`
    private var mainLevels: [CongestionLevel] = []
    /// Verkehrsfarben über der blauen Linie (wie Mapbox/Apple Karten: zäh, stockend, Stau)
    private let trafficLayers: [(CongestionLevel, CAShapeLayer)] = [
        (.moderate, CAShapeLayer()), (.heavy, CAShapeLayer()), (.severe, CAShapeLayer()),
    ]

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
        routeView.isUserInteractionEnabled = false
        routeView.backgroundColor = .clear
        for layer in [casingLayer, lineLayer] {
            layer.fillColor = nil
            layer.lineCap = .round
            layer.lineJoin = .round
            routeView.layer.addSublayer(layer)
        }
        casingLayer.strokeColor = UIColor(red: 0.02, green: 0.04, blue: 0.07, alpha: 0.92).cgColor
        casingLayer.lineWidth = 14
        lineLayer.strokeColor = UIColor(red: 0.20, green: 0.55, blue: 1.0, alpha: 1).cgColor
        lineLayer.lineWidth = 10
        for (level, layer) in trafficLayers {
            layer.fillColor = nil
            layer.lineCap = .round
            layer.lineJoin = .round
            layer.lineWidth = 10
            layer.strokeColor = Self.trafficColor(level).cgColor
            routeView.layer.addSublayer(layer)
        }
        arrowLayer.contents = Self.arrowImage.cgImage
        arrowLayer.bounds = CGRect(x: 0, y: 0, width: 52, height: 52)
        arrowLayer.contentsScale = UIScreen.main.scale
        arrowLayer.isHidden = true
        routeView.layer.addSublayer(arrowLayer)
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
        routeView.removeFromSuperview()
        routeView.translatesAutoresizingMaskIntoConstraints = false
        parent.insertSubview(routeView, aboveSubview: mapView)
        NSLayoutConstraint.activate([
            routeView.leadingAnchor.constraint(equalTo: mapView.leadingAnchor),
            routeView.trailingAnchor.constraint(equalTo: mapView.trailingAnchor),
            routeView.topAnchor.constraint(equalTo: mapView.topAnchor),
            routeView.bottomAnchor.constraint(equalTo: mapView.bottomAnchor),
        ])
        parent.layoutIfNeeded()

        cameraToken?.cancel()
        cameraToken = nil
        syncTimer?.invalidate()
        syncTimer = nil
        puckToken?.cancel()
        puckToken = navigationMapView.mapView.location.onPuckRender.observe { [weak self] data in
            MainActor.assumeIsolated {
                self?.puck = (data.location.coordinate, data.location.bearing)
            }
        }
        lastCamera = nil
        displayLink?.invalidate()
        let link = (parent.window?.screen ?? UIScreen.main).displayLink(withTarget: self, selector: #selector(frameTick))
        link?.add(to: .main, forMode: .common)
        displayLink = link
        if let state = navigationMapView.mapView.mapboxMap?.cameraState { apply(state, force: true) }
        redrawRoutes()
    }

    func detach() {
        attachTask?.cancel()
        cameraToken?.cancel()
        cameraToken = nil
        syncTimer?.invalidate()
        displayLink?.invalidate()
        displayLink = nil
        puckToken?.cancel()
        puckToken = nil
        trailing?.cancel()
        timer?.invalidate()
        timer = nil
        subscriptions.removeAll()
        mapView.removeFromSuperview()
        routeView.removeFromSuperview()
    }

    // MARK: Kamera

    /// Übersetzt die Mapbox-Kamera (Mitte, Zoom, Drehung, Neigung, Rand) in eine MapKit-Kamera.
    /// Pro Bild: Kamera nur übernehmen, wenn sie sich bewegt hat; Pfeil immer nachführen
    @objc private func frameTick() {
        MainActor.assumeIsolated {
            guard let s = mapbox?.mapView.mapboxMap?.cameraState else { return }
            let now = CameraKey(lat: s.center.latitude, lng: s.center.longitude, zoom: s.zoom, bearing: s.bearing,
                                pitch: s.pitch, top: Double(s.padding.top), bottom: Double(s.padding.bottom))
            if let last = lastCamera, last == now {
                updateTopLayer()
            } else {
                lastCamera = now
                apply(s, force: true)
            }
        }
    }

    private func apply(_ state: CameraState, force: Bool) {
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
        updateTopLayer()
    }

    /// Route und Pfeil in der eigenen Ebene an die aktuelle Kamera anpassen
    private func updateTopLayer() {
        guard routeView.bounds.width > 1 else { return }
        let cam = mapView.camera
        // Bodenpunkt unter der Kamera; was dahinter liegt, ist nicht sichtbar und würde falsch projiziert
        let back = cam.centerCoordinateDistance * sin(Double(cam.pitch) * .pi / 180)
        let ground = Self.offset(cam.centerCoordinate, bearing: cam.heading, meters: -back)
        let h = cam.heading * .pi / 180
        let cosLat = cos(ground.latitude * .pi / 180)
        let reach = max(3_000, cam.centerCoordinateDistance * 6)
        func local(_ c: CLLocationCoordinate2D) -> (ahead: Double, dist: Double) {
            let dy = (c.latitude - ground.latitude) * 111_320
            let dx = (c.longitude - ground.longitude) * 111_320 * cosLat
            return (dy * cos(h) + dx * sin(h), (dx * dx + dy * dy).squareRoot())
        }

        // Punkte projizieren (nil = nicht sichtbar bzw. hinter der Kamera)
        let points: [CGPoint?] = mainLine.map { c in
            let l = local(c)
            guard l.ahead > 20, l.dist < reach else { return nil }
            let p = mapView.convert(c, toPointTo: routeView)
            guard p.x.isFinite, p.y.isFinite, abs(p.x) < 10_000, abs(p.y) < 10_000 else { return nil }
            return p
        }
        let path = UIBezierPath()
        var traffic: [CongestionLevel: UIBezierPath] = [:]
        var lastBase = -2
        var lastTraffic: [CongestionLevel: Int] = [:]
        for i in 0..<max(0, points.count - 1) {
            guard let a = points[i], let b = points[i + 1] else { continue }
            if lastBase != i - 1 { path.move(to: a) }
            path.addLine(to: b)
            lastBase = i
            let level = i < mainLevels.count ? mainLevels[i] : .unknown
            guard level == .moderate || level == .heavy || level == .severe else { continue }
            let t = traffic[level] ?? UIBezierPath()
            if lastTraffic[level] != i - 1 { t.move(to: a) }
            t.addLine(to: b)
            traffic[level] = t
            lastTraffic[level] = i
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        casingLayer.path = path.cgPath
        lineLayer.path = path.cgPath
        for (level, layer) in trafficLayers { layer.path = traffic[level]?.cgPath }
        let raw = mapView.userLocation.location ?? AppModel.shared.location.lastLocation
        if let coordinate = puck?.coordinate ?? raw?.coordinate {
            let p = mapView.convert(coordinate, toPointTo: routeView)
            arrowLayer.isHidden = !(p.x.isFinite && p.y.isFinite)
            arrowLayer.position = p
            let rawCourse = raw.map { $0.course >= 0 ? $0.course : cameraHeading } ?? cameraHeading
            let course = puck?.bearing ?? rawCourse
            arrowLayer.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat((course - cameraHeading) * .pi / 180)))
        } else {
            arrowLayer.isHidden = true
        }
        CATransaction.commit()
    }

    /// Punkte so einfügen, dass kein Abstand größer als `step` Meter ist
    private static func densify(_ coords: [CLLocationCoordinate2D], levels: [CongestionLevel],
                                step: Double = 25) -> (coords: [CLLocationCoordinate2D], levels: [CongestionLevel]) {
        guard coords.count > 1 else { return (coords, levels) }
        var out: [CLLocationCoordinate2D] = [coords[0]]
        var outLevels: [CongestionLevel] = []
        for (i, (a, b)) in zip(coords, coords.dropFirst()).enumerated() {
            let level = i < levels.count ? levels[i] : .unknown
            let n = Int(a.distance(to: b) / step)
            if n > 1 {
                for k in 1..<n {
                    let t = Double(k) / Double(n)
                    out.append(CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                                      longitude: a.longitude + (b.longitude - a.longitude) * t))
                    outLevels.append(level)
                }
            }
            out.append(b)
            outLevels.append(level)
        }
        outLevels.append(.unknown)
        return (out, outLevels)
    }

    static func trafficColor(_ level: CongestionLevel) -> UIColor {
        switch level {
        case .moderate: UIColor(red: 1.00, green: 0.62, blue: 0.04, alpha: 1)   // zäh
        case .heavy: UIColor(red: 1.00, green: 0.27, blue: 0.23, alpha: 1)      // stockend
        case .severe: UIColor(red: 0.69, green: 0.00, blue: 0.13, alpha: 1)     // Stau
        default: UIColor(red: 0.20, green: 0.55, blue: 1.0, alpha: 1)
        }
    }

    /// Routenpunkte mit Verkehrslage je Abschnitt (aus den Etappen; wie Mapbox es für seine Linie macht)
    private static func traffic(_ route: Route) -> (coords: [CLLocationCoordinate2D], levels: [CongestionLevel])? {
        var coords: [CLLocationCoordinate2D] = []
        var levels: [CongestionLevel] = []
        for leg in route.legs {
            // Der letzte Punkt eines Schritts ist der erste des nächsten – nur einmal nehmen
            let legCoords: [CLLocationCoordinate2D] = leg.steps.enumerated().reduce([]) { all, step in
                let c = step.element.shape?.coordinates ?? []
                return step.offset == 0 ? c : all + c.dropFirst()
            }
            guard legCoords.count > 1 else { continue }
            var legLevels: [CongestionLevel]
            if let numeric = leg.segmentNumericCongestionLevels, numeric.count == legCoords.count - 1 {
                legLevels = numeric.map { value in
                    guard let value else { return .unknown }
                    switch value {
                    case ..<40: return .low
                    case 40..<60: return .moderate
                    case 60..<80: return .heavy
                    default: return .severe
                    }
                }
            } else if let named = leg.segmentCongestionLevels, named.count == legCoords.count - 1 {
                legLevels = named
            } else {
                legLevels = Array(repeating: .unknown, count: legCoords.count - 1)
            }
            legLevels.append(.unknown)
            if let last = coords.last, last.distance(to: legCoords[0]) < 1 {
                coords.removeLast()
                levels.removeLast()
            }
            coords += legCoords
            levels += legLevels
        }
        return coords.count > 1 ? (coords, levels) : nil
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
        // Befahrener Teil verschwindet: prüft alle 2 s, schneidet aber nur alle ~300 m ab (siehe redrawRoutes)
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

    /// Was gerade gezeichnet ist – neu gezeichnet wird nur, wenn sich daran etwas ändert
    private var drawnRouteKey: String?
    private var trimIndex = 0
    private var trimmedAt: CLLocation?

    /// Zeichnet die Route nur bei echten Änderungen neu (neue Route, Vorschau, alle ~300 m Fortschritt).
    ///
    /// Vorher wurde die Linie alle 2–3 s gelöscht und neu gezeichnet. Nah herangezoomt rechnet MapKit dafür
    /// viele Kacheln neu und war vor dem nächsten Löschen nicht fertig – die Linie verschwand.
    /// Neue Linien kommen jetzt dazu, bevor die alten entfernt werden, damit nie eine Lücke entsteht.
    private func redrawRoutes() {
        guard let routes = activeRoutes ?? previewRoutes,
              let shape = routes.mainRoute.route.shape?.coordinates, shape.count > 1 else {
            if !routeOverlays.isEmpty { mapView.removeOverlays(routeOverlays); routeOverlays = [] }
            mainLine = []
            mainLevels = []
            updateTopLayer()
            drawnRouteKey = nil
            trimIndex = 0
            trimmedAt = nil
            return
        }
        let navigating = activeRoutes != nil
        // Verkehrslage je Abschnitt; ändert sich mit der Routenaktualisierung (alle ~2 Min.)
        let withTraffic = Self.traffic(routes.mainRoute.route)
        let main = withTraffic?.coords ?? shape
        let levels = withTraffic?.levels ?? Array(repeating: CongestionLevel.unknown, count: main.count)
        var hasher = Hasher()
        levels.forEach { hasher.combine($0.rawValue) }
        let identity = "\(navigating)-\(main.count)-\(main.first!.latitude)-\(main.last!.latitude)-\(routes.alternativeRoutes.count)-\(hasher.finalize())"
        if !(drawnRouteKey?.hasPrefix(identity + "#") ?? false) {
            trimIndex = 0
            trimmedAt = nil
        }

        // Befahrenen Teil abschneiden – aber höchstens alle 300 m, nie rückwärts
        if navigating, let me = AppModel.shared.location.lastLocation {
            let moved = trimmedAt.map { me.distance(from: $0) } ?? .greatestFiniteMagnitude
            if moved > 300 {
                trimIndex = Self.nearestIndex(main, to: me.coordinate, from: trimIndex)
                trimmedAt = me
            }
        }
        let key = identity + "#\(trimIndex)"
        guard key != drawnRouteKey else { return }
        drawnRouteKey = key

        var overlays: [MKOverlay] = []
        if !navigating {
            for alt in routes.alternativeRoutes {
                guard let coords = alt.route.shape?.coordinates, coords.count > 1 else { continue }
                overlays += Self.styled(coords, color: UIColor(white: 0.75, alpha: 1), width: 7, casing: 11)
            }
        }
        // Hauptroute in der eigenen Ebene (über Bäumen und Gebäuden), Alternativen bleiben Kartenlinien
        let start = min(trimIndex, main.count - 2)
        (mainLine, mainLevels) = Self.densify(Array(main[start...]), levels: Array(levels[start...]))
        updateTopLayer()

        let old = routeOverlays
        routeOverlays = overlays
        for o in overlays { mapView.addOverlay(o, level: .aboveRoads) }
        mapView.removeOverlays(old)
    }

    /// Nächster Routenpunkt zur Position, nur vorwärts ab `from` gesucht (springt nie zurück)
    private static func nearestIndex(_ coords: [CLLocationCoordinate2D], to me: CLLocationCoordinate2D, from: Int) -> Int {
        let here = CLLocation(latitude: me.latitude, longitude: me.longitude)
        var best = from
        var bestDistance = CLLocationDistance.greatestFiniteMagnitude
        for i in from..<coords.count {
            let d = here.distance(from: CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude))
            if d < bestDistance { bestDistance = d; best = i }
        }
        // Einen Punkt zurück, damit die Linie sicher bis unter den Pfeil reicht
        return max(from, best - 1)
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

    private var friendRoutesKey = ""

    func refreshFriends() {
        let model = AppModel.shared
        let show = friendsVisible()

        // Routen der Freunde nur neu zeichnen, wenn sie sich geändert haben (sonst verschwinden sie beim Zoomen)
        let routes = show ? model.routes.friendRoutes.values.filter { $0.coordinates.count > 1 }.sorted { $0.friendId.uuidString < $1.friendId.uuidString } : []
        let key = routes.map { "\($0.friendId)-\($0.coordinates.count)-\($0.eta.timeIntervalSince1970)" }.joined(separator: "|")
        if key != friendRoutesKey {
            friendRoutesKey = key
            let old = friendOverlays
            friendOverlays = routes.flatMap {
                Self.styled($0.coordinates, color: FriendPalette.routeUIColor(for: $0.friendId), width: 7, casing: 11)
            }
            for o in friendOverlays { mapView.insertOverlay(o, at: 0, level: .aboveRoads) }
            mapView.removeOverlays(old)
        }

        var wanted: [String: (coordinate: CLLocationCoordinate2D, kind: MapPin.Kind)] = [:]
        if show {
            for item in model.friendsOnMap {
                wanted["friend-\(item.friend.friendId)"] = (item.position.coordinate, .friend(item))
            }
        }
        for meetup in model.meetups.accepted {
            wanted["meetup-\(meetup.id)"] = (meetup.coordinate, .meetup(meetup.placeName))
        }

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
                // Unsichtbar: der Pfeil liegt in der eigenen Ebene über der Route (siehe updateTopLayer)
                view.subviews.forEach { $0.removeFromSuperview() }
                view.frame = .zero
                view.image = nil
                userArrow = nil
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
        MainActor.assumeIsolated { updateTopLayer() }
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
            UIColor(red: 0.024, green: 0.165, blue: 0.196, alpha: 0.9).setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: pill.height / 2).fill()
            (text as NSString).draw(at: CGPoint(x: rect.minX + 8, y: rect.minY + 3), withAttributes: attrs)
        }
    }
}
