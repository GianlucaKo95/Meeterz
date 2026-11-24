import SwiftUI
import MapboxMaps
import CoreLocation

struct MainView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme

    /// Kartenart wie in CarPlay: „satellite“ (Mapbox-Luftbild), „classic“ (Mapbox-Karte), „flyover“ (Apple, experimentell)
    @AppStorage("map.style") private var mapStyleKey = "satellite"
    private var flyover: Bool { mapStyleKey == "flyover" }
    private func setMapStyle(_ key: String) {
        MapPreferences.setStyle(MapPreferences.Style(rawValue: key) ?? .satellite)   // gilt auch in CarPlay
    }
    @AppStorage("map.3d") private var threeD = true
    @AppStorage("map.northUp") private var northUp = false

    @State private var viewport: Viewport = .idle
    @State private var showFriends = false
    /// „Unterwegs“-Fenster (öffnet über das Freunde-Symbol) und Folgeaktion nach dem Schließen
    @State private var showSearch = false
    @State private var plannedMeetup: MeetupCandidate?
    @State private var recenterTick = 0
    @State private var showIncognito = false
    /// Zoomstufen über die Plus/Minus-Knöpfe (0 = Standard)
    @State private var zoomSteps = 0
    /// Ein Tipp auf die Karte blendet alle Bedienelemente aus, der nächste Tipp holt sie zurück
    @State private var chromeHidden = false
    /// Per langem Druck auf die Karte gesetzter Pin
    @State private var droppedPin: Place?
    /// Der „Pin“ ist ein angetippter POI: kein roter Pin auf dem Symbol, „Schließen“ statt „Entfernen“ (22.11.)
    @State private var pinIsPoi = false
    @State private var showStoryComposer = false
    @State private var lastPoiTap = Date.distantPast
    @State private var poiDetail: PlaceDetailItem?
    /// POI angetippt, Apple-Suche läuft bzw. Apples Ortskarte ist offen: eigene Karte unten noch nicht zeigen
    /// (sonst lagen beide übereinander und man musste zweimal schließen)
    @State private var poiResolving = false
    /// Mapbox-Ortsdetails, wenn Apple den POI nicht kennt
    @State private var poiInfo: SearchService.Details?
    /// Aktuelle Kamera der Mapbox-Karte (zum Zoomen an Ort und Stelle, wenn sie mir gerade nicht folgt)
    @State private var cameraNow: CameraState?
    @Environment(\.scenePhase) private var scenePhase

    /// Kamera folgt dem eigenen Standort – in 3D schräg von hinten, in Fahrtrichtung gedreht; in 2D genordet.
    /// (Ohne Angabe drehte Mapbox auch in 2D mit der Kompassrichtung des iPhones mit – der Kompass-Knopf nordete
    /// nur kurz, dann drehte die Karte zurück, bis man sie einmal selbst gedreht hatte. 21.11.)
    /// Eine Ausrichtung für alles (2D, 3D, Fahrt, CarPlay): Fahrtrichtung oben oder Norden oben – umschalten per Ortungspfeil
    private var followViewport: Viewport {
        threeD
            ? .followPuck(zoom: 16.5 + Double(zoomSteps), bearing: northUp ? .constant(0) : .course, pitch: 60)
            : .followPuck(zoom: 13 + Double(zoomSteps), bearing: northUp ? .constant(0) : .heading, pitch: 0)
    }

    /// Aufgeteilt, sonst schafft der Compiler die Typprüfung nicht mehr in der Zeit
    var body: some View { cameraHandlers(sheets(mainBody)) }

    @ViewBuilder private var mainBody: some View {
        @Bindable var navigation = app.navigation

        ZStack(alignment: .top) {
            if flyover {
                // Flyover (experimentell): Apples fotorealistische 3D-Städte
                FlyoverMapView(plannedMeetup: $plannedMeetup, droppedPin: $droppedPin, onLongPress: { dropPin(at: $0) }, threeD: threeD, recenterTick: recenterTick, zoomSteps: zoomSteps)
                    .simultaneousGesture(TapGesture().onEnded { toggleChrome() })
            } else {
                map
            }

            VStack(spacing: 10) {
                topBar
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        SharingPill { showIncognito = true }
                        BackgroundHint()
                    }
                    Spacer()
                    mapControls
                }
                if let banner = app.banner {
                    BannerView(banner: banner) { app.dismissBanner() }
                }
                MeetingPointCard()
                ConvoyPausePrompt()
            }
            .padding(.horizontal, 16)
            .chromeVisibility(hidden: chromeHidden)

            VStack(spacing: 10) {
                Spacer()
                if let pin = droppedPin, !poiResolving {
                    PinCard(pin: pin, details: poiInfo, isPoi: pinIsPoi) {
                        droppedPin = nil
                        Task { await app.navigation.planRoute(to: pin) }
                    } onRemove: { droppedPin = nil }
                }
                SocialCards(plannedMeetup: $plannedMeetup)
                // Ladeanzeige unten wie die übrigen Karten (vorher oben unter der Suche – 23.11.)
                if ChargingSession.shared.active, !ChargingSession.shared.hiddenOnPhone {
                    ChargingCard()
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .chromeVisibility(hidden: chromeHidden)
        }
        // Neue Hinweise oder Karten sollen nie unsichtbar bleiben
        .onChange(of: app.banner) { _, new in if new != nil { setChrome(hidden: false) } }
        .onChange(of: plannedMeetup?.id) { _, new in if new != nil { setChrome(hidden: false) } }
        .onChange(of: navigation.isNavigating) { _, _ in setChrome(hidden: false) }
        .overlay {
            if navigation.isCalculating {
                ProgressView(String(localized: "Route wird berechnet …"))
                    .padding(20)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
            }
        }
        .task { await app.startSession() }
    }

    private func sheets<Content: View>(_ content: Content) -> some View {
        @Bindable var navigation = app.navigation
        return content
        .confirmationDialog("Inkognito", isPresented: $showIncognito, titleVisibility: .visible) {
            Button("15 Minuten") { Task { await app.startIncognito(for: 15 * 60) } }
            Button("1 Stunde") { Task { await app.startIncognito(for: 60 * 60) } }
            Button("3 Stunden") { Task { await app.startIncognito(for: 3 * 60 * 60) } }
            Button("Bis ich es ausschalte") { Task { await app.startIncognito(for: nil) } }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Freunde sehen weder deinen Standort noch deine Route – und erfahren nicht, dass du inkognito bist.")
        }
        .sheet(isPresented: Binding(get: { app.selectedFriend != nil }, set: { if !$0 { app.selectedFriend = nil } })) {
            if let id = app.selectedFriend { FriendActionSheet(friendId: id).environment(app) }
        }
        .sheet(isPresented: $showFriends) { FriendsView() }
        .sheet(isPresented: $showStoryComposer) { StoryComposer().environment(app) }
        .sheet(item: $poiDetail, onDismiss: {
            // Apples Ortskarte geschlossen: auch der Pin dazu verschwindet – nichts Zweites zum Schließen
            droppedPin = nil
            poiResolving = false
        }) { item in
            PlaceDetailSheet(item: item) { place in
                droppedPin = nil
                Task { await app.navigation.planRoute(to: place) }
            }
        }
        .sheet(isPresented: $showSearch) { SearchView() }
        .sheet(item: $plannedMeetup) { MeetupPlannerView(candidate: $0) }
        .sheet(item: $navigation.preview) { RoutePreviewView(preview: $0) }
    }

    private func cameraHandlers<Content: View>(_ content: Content) -> some View {
        content
        .onAppear { viewport = followViewport }
        // Weggeschoben bleibt die Karte, wo sie ist – zurück zum Standort nur über den Ortungspfeil (wie in CarPlay).
        // Vorher sprang sie nach 10 s von selbst zurück; ebenso beim Zoomen (+/−), beim 2D/3D-Wechsel und beim
        // Zurückkehren in die App – auch diese setzen die Kamera jetzt nur dann auf mich, wenn sie mir ohnehin folgt.
        .onChange(of: app.mapFocus) { _, focus in
            guard !flyover, let focus, let target = focusViewport(focus) else { return }
            withViewportAnimation(.easeOut(duration: 0.8)) { viewport = target }
        }
        .onChange(of: app.navigation.isNavigating) { _, active in if active { app.mapFocus = nil } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { app.mapFocus = nil }
            if phase == .active, !flyover, viewport.followPuck != nil {
                withViewportAnimation(.easeOut(duration: 0.6)) { viewport = followViewport }
            }
        }
        .onChange(of: zoomSteps) { old, new in
            if viewport.followPuck != nil {
                withViewportAnimation(.easeOut(duration: 0.35)) { viewport = followViewport }
            } else if let cam = cameraNow {
                // Weggeschoben: an Ort und Stelle zoomen
                withViewportAnimation(.easeOut(duration: 0.35)) {
                    viewport = .camera(center: cam.center, zoom: cam.zoom + Double(new - old), bearing: cam.bearing, pitch: cam.pitch)
                }
            }
        }
        .onChange(of: northUp) { _, _ in
            if viewport.followPuck != nil, !flyover {
                withViewportAnimation(.easeOut(duration: 0.5)) { viewport = followViewport }
            }
        }
        .onChange(of: threeD) { _, three in
            if viewport.followPuck != nil {
                withViewportAnimation(.easeOut(duration: 0.6)) { viewport = followViewport }
            } else if let cam = cameraNow {
                withViewportAnimation(.easeOut(duration: 0.6)) {
                    viewport = .camera(center: cam.center, zoom: cam.zoom, bearing: three ? cam.bearing : 0, pitch: three ? 60 : 0)
                }
            }
        }
    }

    /// Zeigt den Freund (und seine restliche Route) im oberen Teil der Karte, damit das halbhohe Unterwegs-Fenster nichts verdeckt.
    private func focusViewport(_ focus: AppModel.MapFocus) -> Viewport? {
        guard let item = app.friendsOnMap.first(where: { $0.friend.friendId == focus.friendId }) else { return nil }
        let friend = item.position.coordinate
        if focus.showRoute, let route = app.routes.friendRoutes[focus.friendId], route.coordinates.count > 1 {
            return .overview(
                geometry: MultiPoint(route.coordinates + [friend]),
                bearing: 0, pitch: 0,
                geometryPadding: EdgeInsets(top: 170, leading: 50, bottom: 230, trailing: 50))
        }
        // Fenster ist geschlossen: Freund genau in die Bildmitte
        let zoom = 15.5
        let center = friend
        return .camera(center: center, zoom: zoom, bearing: 0, pitch: 0)
    }

    // MARK: Karte

    private var map: some View {
        Map(viewport: $viewport) {
            Puck2D(bearing: threeD ? .course : .heading)

            // 3D-Landschaft: Höhenmodell, leicht überhöht damit Hügel sichtbar werden
            if threeD {
                RasterDemSource(id: "mapbox-dem")
                    .url("mapbox://mapbox.mapbox-terrain-dem-v1")
                    .maxzoom(14)
                Terrain(sourceId: "mapbox-dem")
                    .exaggeration(1.3)
            }

            // Satellit in 3D: Gebäude als helle 3D-Körper wie in Navigation und CarPlay (Satellite3DBuildings) –
            // das Satellitenbild hat selbst keine Gebäude, auf dem iPhone fehlten sie bisher
            if threeD && mapStyleKey != "classic" {
                VectorSource(id: "meeterz-streets-3d")
                    .url("mapbox://mapbox.mapbox-streets-v8")
                FillExtrusionLayer(id: "meeterz-3d-buildings", source: "meeterz-streets-3d")
                    .sourceLayer("building")
                    .filter(Exp(.eq) { Exp(.get) { "extrude" }; "true" })
                    .minZoom(14.5)
                    .fillExtrusionColor(UIColor(red: 0.93, green: 0.91, blue: 0.87, alpha: 1))
                    .fillExtrusionOpacity(0.94)
                    .fillExtrusionEmissiveStrength(0.65)
                    .fillExtrusionVerticalGradient(true)
                    .fillExtrusionAmbientOcclusionIntensity(0.25)
                    .fillExtrusionHeight(Exp(.get) { "height" })
                    .fillExtrusionBase(Exp(.get) { "min_height" })
                    .slot(.middle)
            }

            // Verkehrslage wie Apple Karten (auch freie Fahrt, Klassisch und Satellit): stockend orange, Stau rot
            VectorSource(id: TrafficLayer.sourceId)
                .url(TrafficLayer.url)
            if !app.navigation.isNavigating {   // mit Route nur der Verkehr auf ihr (Routenlinie) – 24.11.
                LineLayer(id: TrafficLayer.layerId, source: TrafficLayer.sourceId)
                    .sourceLayer("traffic")
                    .filter(TrafficLayer.filter)
                    .lineColor(TrafficLayer.color)
                    .lineWidth(TrafficLayer.width)
                    .lineOpacity(0.9)
                    .lineCap(.round)
                    .lineJoin(.round)
                    .lineEmissiveStrength(1)
                    .slot(.middle)
            }

            // Routen der Freunde: dunkle Umrandung, darüber knallige Farbe (die gezeigte Route etwas breiter)
            ForEvery(Array(app.routes.friendRoutes.values)) { route in
                PolylineAnnotation(id: "routecase-\(route.friendId)", lineCoordinates: route.coordinates)
                    .lineColor(FriendPalette.routeCasing)
                    .lineWidth(app.mapFocus?.friendId == route.friendId ? 13 : 10)
            }
            ForEvery(Array(app.routes.friendRoutes.values)) { route in
                PolylineAnnotation(id: "route-\(route.friendId)", lineCoordinates: route.coordinates)
                    .lineColor(FriendPalette.routeUIColor(for: route.friendId))
                    .lineWidth(app.mapFocus?.friendId == route.friendId ? 8 : 6)
            }
            // Ziel der gezeigten Route
            if let focus = app.mapFocus, focus.showRoute, let route = app.routes.friendRoutes[focus.friendId] {
                MapViewAnnotation(coordinate: route.destination) {
                    Image(systemName: "flag.checkered.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.black, FriendPalette.routeColor(for: route.friendId))
                        .shadow(radius: 3)
                }
                .allowOverlap(true)
            }

            // Freunde live
            // Als Symbolebene statt View-Annotation: auch Freunde direkt neben mir bleiben sichtbar
            PointAnnotationGroup(app.friendsOnMap, id: \.id) { item in
                let stale = item.position.age > 5 * 60
                let photo = app.avatars.image(for: item.friend.friendId)
                let story = app.stories.hasUnseen(item.friend.friendId)
                return PointAnnotation(coordinate: item.position.coordinate)
                    .image(.init(
                        image: AvatarRenderer.image(initials: item.friend.initials,
                                                    color: FriendPalette.uiColor(for: item.friend.friendId),
                                                    faded: stale, photo: photo, story: story),
                        name: "avatar-\(item.friend.friendId)-\(stale)-\(item.friend.avatarVersion ?? 0)-\(photo != nil)-\(story)"))
                    .iconAnchor(.bottom)
                    .textField("\(item.friend.displayName) · \(Format.age(item.position.age))")
                    .textMaxWidth(30)
                    .textOffset(x: 0, y: 0.6)
                    .textSize(13)
                    .textColor(StyleColor(.white))
                    .textHaloColor(StyleColor(.black))
                    .textHaloWidth(1.5)
                    .onTapGesture { app.tapFriend(item.id) }
            }
            .iconAllowOverlap(true)
            .iconIgnorePlacement(true)
            .textAllowOverlap(true)
            .textIgnorePlacement(true)

            // Eigene Story: Ring um meinen Standort, Antippen spielt sie ab
            if let me = app.stories.myId, app.stories.hasStories(me), let here = app.location.lastLocation {
                MapViewAnnotation(coordinate: here.coordinate) {
                    Button { app.stories.open(me) } label: {
                        Circle().stroke(Theme.accent, lineWidth: 3)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .accessibilityLabel("Meine Story ansehen")
                }
                .allowOverlap(true)
                // Ohne das blendet Mapbox Markierungen über dem eigenen Standortpunkt aus – Ring und Story-Pins
                // am eigenen Ort waren deshalb nie zu sehen (18.11., Protokoll: „Stories geladen: 2“)
                .allowOverlapWithPuck(true)
            }

            // Stories an ihrem Ort
            ForEvery(app.stories.stories) { story in
                MapViewAnnotation(coordinate: story.coordinate) {
                    Button { app.stories.open(story.userId) } label: {
                        Image(systemName: "camera.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(Theme.ink, story.seen ? Theme.muted : Theme.accent)
                            .shadow(radius: 3)
                    }
                    .accessibilityLabel("Story von \(story.displayName)")
                }
                .allowOverlap(true)
                .allowOverlapWithPuck(true)
            }

            // Mögliche Treffpunkte
            ForEvery(app.meetups.visibleCandidates) { candidate in
                MapViewAnnotation(coordinate: candidate.coordinate) {
                    Button { plannedMeetup = candidate } label: {
                        Image(systemName: "figure.2.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(Theme.ink, Theme.accent)
                            .shadow(radius: 4)
                    }
                    .accessibilityLabel("Möglicher Treffpunkt")
                }
                .allowOverlap(true)
            }

            if let pin = droppedPin, !pinIsPoi {
                MapViewAnnotation(coordinate: pin.coordinate) { DroppedPinMarker() }
                    .allowOverlap(true)
            }

            // POI der Karte antippen: Apples Ortsdetails, sonst Karte mit Name und Adresse.
            // Vorher reagierten die POIs der Mapbox-Karte gar nicht – ein Tipp blendete nur die Knöpfe aus (18.11.).
            TapInteraction(.standardPoi) { poi, _ in
                guard !app.navigation.isNavigating else { return false }
                poiTapped(name: poi.name, coordinate: poi.coordinate)
                return true
            }

            // Geparktes Auto (beim Trennen von CarPlay gemerkt)
            if let spot = app.parking.spot {
                MapViewAnnotation(coordinate: spot.coordinate) {
                    ParkedCarMarker(spot: spot).environment(app)
                }
                .allowOverlap(true)
            }

            // Vereinbarte Treffen
            ForEvery(app.meetups.accepted) { meetup in
                MapViewAnnotation(coordinate: meetup.coordinate) {
                    VStack(spacing: 2) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(Theme.ink, Theme.accent)
                        Text(meetup.placeName)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.panel))
                    }
                }
                .allowOverlap(true)
            }
        }
        .onCameraChanged { cameraNow = $0.cameraState }
        .onMapTapGesture { _ in
            // Ein POI-Tipp geht auch hier durch – dann die Knöpfe nicht ausblenden
            if Date().timeIntervalSince(lastPoiTap) > 0.6 { toggleChrome() }
        }
        .onMapLongPressGesture { context in dropPin(at: context.coordinate) }
        .mapStyle(mapStyleKey == "classic"
                  ? .standard(lightPreset: colorScheme == .light ? .day : .night)
                  : .standardSatellite(lightPreset: colorScheme == .light ? .day : .night))
        // Kein Kompass: Die Ausrichtung schaltet der Ortungspfeil (Norden oben ↔ Fahrtrichtung). Der Kompass
        // nordete nur kurz ein, dann drehte die Kamera wieder mit (23.11.)
        .ornamentOptions(OrnamentOptions(compass: CompassViewOptions(visibility: .hidden)))
        .ignoresSafeArea()
    }

    /// POI angetippt: sofort Karte mit Namen, dann Apples Ortsdetails (Öffnungszeiten, Bewertungen …), falls Apple den Ort kennt
    private func poiTapped(name: String?, coordinate: CLLocationCoordinate2D) {
        lastPoiTap = Date()
        Diag.log("POI getippt: \(name ?? "ohne Namen")")
        dropPin(at: coordinate, name: name, haptic: false)
        pinIsPoi = true
        guard let name else { return }
        poiResolving = true
        let id = droppedPin?.id
        Task {
            if let item = await ApplePlaces.mapItem(for: Place(id: "poi", name: name, address: nil, coordinate: coordinate)) {
                guard droppedPin?.id == id else { return }
                poiDetail = PlaceDetailItem(mapItem: item)   // nur Apples Ortskarte, die eigene bleibt verborgen
                return
            }
            // Apple kennt den Ort nicht: eigene Karte mit Mapbox-Details (wie Android)
            guard droppedPin?.id == id else { return }
            poiResolving = false
            let info = await SearchService.details(name: name, at: coordinate)
            guard droppedPin?.id == id else { return }
            poiInfo = info
        }
    }

    /// Pin setzen und Adresse nachladen; `name`: Name des POI (sonst aus der Adresse)
    private func dropPin(at coordinate: CLLocationCoordinate2D, name poiName: String? = nil, haptic: Bool = true) {
        let id = "pin-\(coordinate.latitude),\(coordinate.longitude)"
        droppedPin = Place(id: id, name: poiName ?? String(localized: "Gesetzter Pin"), address: nil, coordinate: coordinate)
        pinIsPoi = false
        poiInfo = nil
        poiResolving = false
        setChrome(hidden: false)
        if haptic { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
        Task {
            let marks = try? await CLGeocoder().reverseGeocodeLocation(
                CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            guard let mark = marks?.first, droppedPin?.id == id else { return }
            let street = [mark.thoroughfare, mark.subThoroughfare].compactMap { $0 }.joined(separator: " ")
            let city = [mark.postalCode, mark.locality].compactMap { $0 }.joined(separator: " ")
            let name = poiName ?? mark.name ?? (street.isEmpty ? String(localized: "Gesetzter Pin") : street)
            let address = [street, city].filter { !$0.isEmpty }.joined(separator: ", ")
            droppedPin = Place(id: id, name: name, address: address.isEmpty ? nil : address, coordinate: coordinate)
        }
    }

    private func toggleChrome() { setChrome(hidden: !chromeHidden) }

    private func setChrome(hidden: Bool) {
        withAnimation(.easeInOut(duration: 0.25)) { chromeHidden = hidden }
    }

    // MARK: Bedienelemente

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { showSearch = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                    Text("Wohin?")
                    Spacer()
                }
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 16)
                .frame(height: 52)
                .background(Capsule().fill(Theme.panel))
                .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
            }
            .accessibilityLabel("Ziel suchen")

            // Profil statt „Unterwegs“-Fenster: Freunde, Treffen und Fahrten stehen dort (24.11.)
            CircleIconButton(
                systemName: "person.crop.circle.fill",
                label: "Profil",
                badge: !app.friends.incoming.isEmpty,
                activeDot: !app.routes.friendRoutes.isEmpty
            ) { showFriends = true }
        }
        .padding(.top, 8)
    }

    /// Zwei Knöpfe statt vier: Kartenansicht (Stil + 3D) und Standort. Inkognito steckt in der Status-Pille.
    private var mapControls: some View {
        VStack(spacing: 8) {
            Menu {
                Section("Karte") {
                    Button { setMapStyle("satellite") } label: {
                        Label("Satellit", systemImage: mapStyleKey == "satellite" ? "checkmark" : "globe.europe.africa")
                    }
                    Button { setMapStyle("classic") } label: {
                        Label("Klassische Karte", systemImage: mapStyleKey == "classic" ? "checkmark" : "map")
                    }
                    Button { setMapStyle("flyover") } label: {
                        Label("Flyover (experimentell)", systemImage: flyover ? "checkmark" : "building.2")
                    }
                }
                Section("Ansicht") {
                    Button { MapPreferences.setThreeD(true) } label: { Label("3D", systemImage: threeD ? "checkmark" : "cube") }
                    Button { MapPreferences.setThreeD(false) } label: { Label("2D", systemImage: threeD ? "square" : "checkmark") }
                }
                // Wie Apple Karten: Fahrtrichtung oben oder Norden oben – in 2D und 3D gleich
                Section("Ausrichtung") {
                    Button { MapPreferences.setNorthUp(false) } label: {
                        Label("Fahrtrichtung oben", systemImage: northUp ? "location.north.line" : "checkmark")
                    }
                    Button { MapPreferences.setNorthUp(true) } label: {
                        Label("Norden oben", systemImage: northUp ? "checkmark" : "n.circle")
                    }
                }
            } label: {
                Image(systemName: "square.3.layers.3d")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Theme.panel))
                    .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
            }
            .accessibilityLabel("Kartenansicht")
            .accessibilityValue("\(mapStyleKey == "classic" ? "Klassisch" : (flyover ? "Flyover" : "Satellit")), \(threeD ? "3D" : "2D")")

            CircleIconButton(systemName: "camera.fill", label: "Story aufnehmen") {
                Task { if await Permissions.ask(.camera) { showStoryComposer = true } }
            }

            CircleIconButton(systemName: viewport.followPuck == nil ? "location" : (northUp ? "location.fill" : "location.north.line.fill"),
                             label: "Auf meinen Standort zentrieren", tint: Theme.accent) {
                app.mapFocus = nil
                // Folgt die Karte schon: Ausrichtung umschalten (wie Apple Karten) – gilt auch für Fahrt und CarPlay
                if viewport.followPuck != nil, !flyover { MapPreferences.setNorthUp(!northUp) }
                recenterTick += 1
                withViewportAnimation(.easeOut(duration: 0.5)) { viewport = followViewport }
            }
        }
    }
}

// MARK: - Freunde-Marker

struct FriendMarker: View {
    let friend: FriendRow
    let position: LivePosition

    var body: some View {
        // TimelineView sorgt dafür, dass "vor X Min." mitläuft
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            let stale = position.age > 5 * 60
            VStack(spacing: 4) {
                Avatar(initials: friend.initials, color: FriendPalette.color(for: friend.friendId), size: 40, faded: stale, userId: friend.friendId)
                    .overlay(Circle().stroke(FriendPalette.color(for: friend.friendId), lineWidth: 2).padding(-2))
                Text("\(friend.displayName) · \(Format.age(position.age))")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Theme.panel))
            }
            .opacity(stale ? 0.6 : 1)
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Teilen-Status

/// Hinweis, solange der Standort nur „beim Verwenden“ freigegeben ist: Freunde sehen dich sonst nur bei offener App.
struct BackgroundHint: View {
    @Environment(AppModel.self) private var app
    @AppStorage("hint.always.dismissed") private var dismissed = false

    var body: some View {
        if app.location.authorization == .authorizedWhenInUse, !dismissed {
            HStack(spacing: 8) {
                Button { Task { _ = await Permissions.ask(.always) } } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nur bei offener App sichtbar").font(.system(size: 13, weight: .semibold, design: .rounded))
                        Text("Tippen: Standort „Immer“ erlauben").font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.muted)
                    }
                    .multilineTextAlignment(.leading)
                }
                .accessibilityLabel("Standort Immer erlauben")
                Button { dismissed = true } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                }
                .accessibilityLabel("Hinweis ausblenden")
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke, lineWidth: 1))
            .frame(maxWidth: 230, alignment: .leading)
        }
    }
}

struct SharingPill: View {
    @Environment(AppModel.self) private var app
    /// Öffnet die Auswahl der Inkognito-Dauer
    var startIncognito: () -> Void = {}

    var body: some View {
        // Minütlich neu auswerten, damit das Ende von Inkognito/Teilen von selbst sichtbar wird
        TimelineView(.periodic(from: .now, by: 20)) { _ in
            pill(app.profile)
        }
    }

    @ViewBuilder
    private func pill(_ profile: Profile?) -> some View {
        let incognito = profile?.isIncognito ?? false
        let sharing = profile?.isSharingNow ?? false
        // Tippen öffnet die Teilen-Optionen direkt auf der Karte (Dauer, Pausieren, Inkognito beenden)
        Menu {
            if incognito {
                Button("Inkognito beenden", systemImage: "eye") { Task { await app.stopIncognito() } }
            } else {
                Button("Inkognito …", systemImage: "eye.slash") { startIncognito() }
            }
            Section("Standort teilen für") {
                ForEach(SharingMode.allCases) { mode in
                    Button {
                        Task { await app.shareLocation(for: mode) }
                    } label: {
                        if sharing && SharingMode.current == mode {
                            Label(mode.title, systemImage: "checkmark")
                        } else {
                            Text(mode.title)
                        }
                    }
                }
            }
            if sharing {
                Button("Teilen pausieren", systemImage: "pause.circle", role: .destructive) {
                    Task { await app.auth.setSharing(false) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                if incognito {
                    Image(systemName: "eye.slash.fill").font(.system(size: 11, weight: .semibold))
                } else {
                    Circle().fill(sharing ? Theme.accent : Theme.muted).frame(width: 8, height: 8)
                }
                Text(label(profile))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(incognito || sharing ? Theme.accent : Theme.muted)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Capsule().fill(Theme.panel.opacity(0.92)))
        }
        .accessibilityIdentifier("status-pill")
        .accessibilityHint("Öffnet die Optionen zum Teilen und Inkognito")
    }

    private func label(_ profile: Profile?) -> String {
        if let profile, profile.isIncognito {
            if profile.isIncognitoIndefinitely { return String(localized: "Inkognito") }
            if let until = profile.incognitoUntil { return String(localized: "Inkognito bis \(ActivityFormat.time(until))") }
        }
        guard let profile, profile.isSharingNow else { return String(localized: "Teilen pausiert") }
        if let until = profile.sharingUntil { return String(localized: "Teilst live bis \(ActivityFormat.time(until))") }
        return String(localized: "Teilst live")
    }
}

struct BannerView: View {
    let banner: AppModel.Banner
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(banner.isError ? Theme.danger : Theme.accent)
            Text(banner.text).font(.footnote.weight(.medium))
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark").font(.footnote.weight(.semibold)) }
                .accessibilityLabel("Hinweis schließen")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panelRaised))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

private extension View {
    /// Blendet Bedienelemente aus: unsichtbar, nicht antippbar, für VoiceOver und Tests nicht vorhanden.
    func chromeVisibility(hidden: Bool) -> some View {
        self.opacity(hidden ? 0 : 1)
            .allowsHitTesting(!hidden)
            .accessibilityHidden(hidden)
    }
}

struct DroppedPinMarker: View {
    var body: some View {
        Image(systemName: "mappin.circle.fill")
            .font(.system(size: 38))
            .foregroundStyle(.white, Theme.danger)
            .shadow(radius: 4)
            .accessibilityLabel("Gesetzter Pin")
    }
}

/// Karte unten: Navigation zum gesetzten Pin oder Pin entfernen
struct PinCard: View {
    let pin: Place
    var details: SearchService.Details? = nil
    var isPoi = false
    let onNavigate: () -> Void
    let onRemove: () -> Void
    @State private var week = false
    @State private var fuel: FuelPrices.Price?
    @State private var saving = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(pin.name).font(.headline)
                    Spacer(minLength: 0)
                    // In Liste speichern: als kleines Symbol neben dem Namen, keine eigene Zeile
                    Button { saving = true } label: {
                        Image(systemName: "bookmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Theme.panelRaised))
                    }
                    .accessibilityLabel("In Liste speichern")
                }
                let sub = [details?.category, details?.rating.map { r in
                    "★ " + r.formatted(.number.precision(.fractionLength(1))) + (details?.reviews.map { " (\($0))" } ?? "")
                }].compactMap { $0 }
                if !sub.isEmpty { Text(sub.joined(separator: " · ")).font(.footnote).foregroundStyle(Theme.muted) }
                if let address = details?.address ?? pin.address { Text(address).font(.footnote).foregroundStyle(Theme.muted) }
                if let d = details, let open = d.openNow(), let hours = d.hours {
                    let today = hours[SearchService.Details.weekday()]
                    Button {
                        week.toggle()
                    } label: {
                        Text((open ? String(localized: "Jetzt geöffnet") : String(localized: "Geschlossen"))
                             + (today.isEmpty ? "" : " · " + Self.text(today)) + (week ? " ▴" : " ▾"))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(open ? Theme.accent : Theme.danger)
                    }
                    .buttonStyle(.plain)
                    if week {
                        let names = Calendar.current.shortWeekdaySymbols // 0 = Sonntag
                        ForEach(0..<7, id: \.self) { i in
                            Text("\(names[(i + 1) % 7])  " + (hours[i].isEmpty ? String(localized: "Geschlossen") : Self.text(hours[i])))
                                .font(.footnote).foregroundStyle(Theme.muted)
                        }
                    }
                }
            }
            if details?.hours == nil, let text = details?.hoursText {
                Text(text).font(.footnote).foregroundStyle(Theme.muted)
            }
            if details?.osm == true {
                Text("© OpenStreetMap").font(.caption2).foregroundStyle(Theme.muted)
            }
            if let fuel, !fuel.text.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(fuel.text).font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent)
                    Text(FuelPrices.attribution).font(.caption2).foregroundStyle(Theme.muted)
                }
            }
            if details?.phone != nil || details?.website != nil {
                HStack(spacing: 10) {
                    if let phone = details?.phone, let url = URL(string: "tel:" + phone.filter { !$0.isWhitespace }) {
                        Button("Anrufen") { openURL(url) }.buttonStyle(SecondaryButtonStyle())
                    }
                    if let web = details?.website {
                        Button("Website") { openURL(web) }.buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
            HStack(spacing: 10) {
                Button(isPoi ? "Schließen" : "Entfernen", action: onRemove).buttonStyle(SecondaryButtonStyle())
                Button("Hierhin navigieren", action: onNavigate).buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.stroke, lineWidth: 1))
        .sheet(isPresented: $saving) { SaveToListSheet(place: pin).presentationDetents([.medium, .large]) }
        .task(id: "\(pin.id)|\(details?.category ?? "")") {
            fuel = nil
            guard FuelPrices.isGasStation(category: details?.category, name: pin.name) else { return }
            fuel = await FuelPrices.prices(for: [pin.coordinate]).first ?? nil
        }
    }

    private static func text(_ spans: [Range<Int>]) -> String {
        spans.map { r in
            if r.lowerBound == 0 && r.upperBound >= 1440 { return String(localized: "24 Stunden") }
            return String(format: "%02d:%02d–%02d:%02d", r.lowerBound / 60, r.lowerBound % 60, r.upperBound / 60 % 24, r.upperBound % 60)
        }.joined(separator: ", ")
    }
}


// MARK: - Treffpunkt: wer ist wann da

/// Fahren Freunde zum selben Ziel (Treffen oder mein Navigationsziel), zeigt diese Karte alle Ankunftszeiten
/// nebeneinander – die Routen sind auf der Karte schon in den Farben der Freunde eingezeichnet.
/// Pausenvorschlag aus dem Konvoi auf dem iPhone (ohne CarPlay; dort kommt er als Hinweis auf der Karte)
struct ConvoyPausePrompt: View {
    var body: some View {
        let pause = ConvoyPause.shared
        Color.clear.frame(width: 0, height: 0)
            .alert(pause.prompt.map { String(localized: "\($0.fromName.split(separator: " ").first.map(String.init) ?? $0.fromName) schlägt eine Pause vor") } ?? "",
                   isPresented: Binding(get: { pause.prompt != nil }, set: { if !$0 { pause.prompt = nil } }),
                   presenting: pause.prompt) { p in
                Button("Dabei") { Task { await pause.answer(p, accept: true) } }
                Button("Nein", role: .cancel) { Task { await pause.answer(p, accept: false) } }
            } message: { p in
                Text(pause.subtitle(p))
            }
    }
}

/// Zeitleiste „Wer ist wann da“: rechts das Ziel („da“), links die späteste Ankunft (darunter Stufen 30/10 min). Jeder ist ein Punkt in seiner Farbe an
/// seiner Ankunftszeit (wer schon da ist, ganz links in Bernstein beschriftet); Namen abwechselnd über und unter der Linie.
struct ArrivalTimeline: View {
    struct Item: Identifiable {
        let id: String
        let name: String
        let color: Color
        let eta: Date?
        let here: Bool
    }
    let items: [Item]
    /// Breite für die Zeilenwahl (CarPlay: Breite der Einblendung); sonst Bildschirmbreite abzüglich Kartenrand
    var layoutWidth: CGFloat? = nil

    private static let labelWidth: CGFloat = 72
    private static let axis: CGFloat = 38
    /// Platz rechts für die Zielflagge am Linienende – damit klar ist, dass rechts das Ziel ist (20.11.)
    private static let flag: CGFloat = 16

    /// Braucht eine zweite Beschriftungszeile (Namen würden sich überdecken)?
    func twoRows(width: CGFloat) -> Bool { layout(width: width).contains { $0.row == 1 } }
    /// Gesamthöhe inkl. Abstand oben
    func height(width: CGFloat) -> CGFloat { (twoRows(width: width) ? 76 : 48) + 4 }

    private struct Placed { let item: Item; let x: CGFloat; let row: Int }

    /// Position auf der Linie; Beschriftungen wechseln die Zeile, wenn sie sich sonst überdecken würden
    private func layout(width: CGFloat) -> [Placed] {
        let now = Date()
        let latest = items.compactMap(\.eta).max() ?? now
        // Linkes Ende = längste Restfahrzeit; darunter feste Stufen 30 bzw. 10 min, damit wer bald kommt nicht ganz links
        // steht, als wäre er weit weg (20.11.)
        let longest = latest.timeIntervalSince(now)
        let span = longest > 30 * 60 ? longest : longest >= 10 * 60 ? 30 * 60 : 10 * 60
        let inset: CGFloat = 6
        let xs = items.map { item -> (Item, CGFloat) in
            // Zeitstrahl aufs Ziel zu: rechts = da, links = noch weit (ohne Zeit ganz links) – 20.11.
            let f = item.here ? 1 : item.eta.map { 1 - min(max($0.timeIntervalSince(now) / span, 0), 1) } ?? 0
            return (item, inset + (width - Self.flag - 2 * inset) * f)
        }.sorted { $0.1 < $1.1 }
        var last: [CGFloat] = [-.infinity, -.infinity]
        return xs.map { item, x in
            let row = x - last[0] >= Self.labelWidth ? 0 : x - last[1] >= Self.labelWidth ? 1 : (last[0] < last[1] ? 0 : 1)
            last[row] = x
            return Placed(item: item, x: x, row: row)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                Capsule().fill(Theme.stroke).frame(width: w - Self.flag, height: 2).position(x: (w - Self.flag) / 2, y: Self.axis)
                Image(systemName: "flag.checkered").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.muted).position(x: w - Self.flag / 2 + 1, y: Self.axis)
                ForEach(layout(width: w), id: \.item.id) { p in
                    Circle().fill(p.item.color).frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Theme.panel, lineWidth: 2))
                        .position(x: p.x, y: Self.axis)
                    VStack(spacing: 0) {
                        Text(p.item.name).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
                        Text(p.item.here ? String(localized: "da") : (p.item.eta.map { $0.formatted(date: .omitted, time: .shortened) } ?? "–"))
                            .font(.system(size: 12, design: .rounded)).monospacedDigit()
                            .foregroundStyle(p.item.color)  // Zeit bzw. „da“ in der Farbe der Person
                    }
                    .frame(width: Self.labelWidth)
                    .position(x: min(max(p.x, Self.labelWidth / 2), w - Self.labelWidth / 2),
                              y: p.row == 0 ? Self.axis - 22 : Self.axis + 22)
                }
            }
        }
        // Zweite Beschriftungszeile unter der Linie nur, wenn Namen sich überdecken würden – sonst blieb dort
        // ein leerer Streifen (Karte zu hoch, 19.11.)
        .frame(height: height(width: layoutWidth ?? UIScreen.main.bounds.width - 56) - 4)
        .padding(.top, 4)
    }
}

struct MeetingPointCard: View {
    @Environment(AppModel.self) private var app
    /// Schon am Treffpunkt: Karte sitzt unten an Stelle der Treffen-Karte (statt oben über der Karte)
    var atBottom = false

    private struct Arrival: Identifiable {
        let id: String
        let name: String
        let color: Color
        let eta: Date?
        let here: Bool
    }

    /// Ziel: laufende Navigation, sonst das nächste zugesagte Treffen
    private var target: (name: String, coordinate: CLLocationCoordinate2D)? {
        if app.navigation.isNavigating, let d = app.navigation.destination { return (d.name, d.coordinate) }
        if let m = app.meetups.accepted.first { return (m.placeName, m.coordinate) }
        return nil
    }

    private func arrivals(at place: CLLocationCoordinate2D) -> [Arrival] {
        var list: [Arrival] = []
        // Treffen dort: „schon da“ zählt nur für Eingeladene – sonst stand z. B. wer zu Hause ist mit drin (19.11.)
        let meetup = app.meetups.accepted.first { $0.coordinate.distance(to: place) < 150 }
        let invited = meetup.map { Set(app.meetups.partners(of: $0)) }
        for item in app.friendsOnMap {
            let id = item.friend.friendId
            let first = item.friend.firstName
            guard !app.routes.withdrew(id, from: place) else { continue }
            let here = item.position.coordinate.distance(to: place) < 150 && invited?.contains(id) != false
            let route = app.routes.route(of: id, to: place)
            guard here || route != nil else { continue }
            list.append(Arrival(id: id.uuidString, name: first, color: FriendPalette.routeColor(for: id), eta: route?.eta, here: here))
        }
        return list.sorted { ($0.here ? 0 : 1, $0.eta ?? .distantFuture) < ($1.here ? 0 : 1, $1.eta ?? .distantFuture) }
    }

    var body: some View {
        if let target, case let friends = arrivals(at: target.coordinate), !friends.isEmpty {
            // Ich selbst: unterwegs mit Ankunftszeit, schon dort als „da“ (z. B. Treffen bei mir zu Hause)
            let meHere = app.location.lastLocation.map { $0.coordinate.distance(to: target.coordinate) < 150 } ?? false
            let me: [Arrival] = app.navigation.isNavigating
                ? [Arrival(id: "me", name: String(localized: "Du"), color: Theme.accent, eta: app.navigation.eta, here: false)]
                : meHere ? [Arrival(id: "me", name: String(localized: "Du"), color: Theme.accent, eta: nil, here: true)] : []
            if atBottom != (meHere && !app.navigation.isNavigating) {
                EmptyView()
            } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(target.name, systemImage: "flag.checkered")
                        .font(Theme.title(14)).lineLimit(1)
                    Spacer()
                    // Unterwegs kurz Bescheid geben – an alle, die dort sind oder auch hinfahren
                    if app.navigation.isNavigating {
                        let ids = friends.compactMap { UUID(uuidString: $0.id) }
                        Menu {
                            ForEach(MessagesStore.quickReplies(eta: app.navigation.eta), id: \.self) { text in
                                Button(text) {
                                    Task {
                                        let n = await app.messages.send(text, to: ids)
                                        app.show(n > 0 ? String(localized: "Gesendet: „\(text)“") : String(localized: "Nachricht nicht gesendet"), isError: n == 0)
                                    }
                                }
                            }
                            // Konvoi: Meeterz sucht selbst einen Halt, den alle noch erreichen
                            if !ConvoyTracker.shared.members().isEmpty {
                                Divider()
                                Button {
                                    Task { await ConvoyPause.shared.propose() }
                                } label: {
                                    Label("Pause vorschlagen", systemImage: "cup.and.saucer.fill")
                                }
                            }
                        } label: {
                            Label("Bescheid geben", systemImage: "text.bubble.fill")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                        }
                        .accessibilityIdentifier("meeting-point-message")
                    }
                }
                ArrivalTimeline(items: (me + friends).map {
                    ArrivalTimeline.Item(id: $0.id, name: $0.name, color: $0.color, eta: $0.eta, here: $0.here)
                })
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel.opacity(0.95)))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Wer ist wann da")
            }
        }
    }
}
