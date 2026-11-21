package de.koeven.meeterz.car

import de.koeven.meeterz.tr
import android.location.Location
import androidx.car.app.CarContext
import de.koeven.meeterz.ui.NavigationMapBinder
import com.mapbox.navigation.ui.maps.camera.data.MapboxNavigationViewportDataSource
import com.mapbox.navigation.core.trip.session.RouteProgressObserver
import com.mapbox.navigation.core.lifecycle.MapboxNavigationApp
import androidx.car.app.CarToast
import androidx.car.app.Screen
import androidx.car.app.model.Action
import androidx.car.app.model.ActionStrip
import androidx.car.app.model.CarColor
import androidx.car.app.model.ItemList
import androidx.car.app.model.ListTemplate
import androidx.car.app.model.Row
import androidx.car.app.model.SearchTemplate
import androidx.car.app.model.Template
import androidx.car.app.navigation.model.NavigationTemplate
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.lifecycleScope
import com.mapbox.geojson.Point
import com.mapbox.maps.extension.androidauto.MapboxCarMap
import com.mapbox.navigation.ui.androidauto.action.MapboxMapActionStrip
import com.mapbox.navigation.ui.androidauto.location.CarLocationProvider
import com.mapbox.navigation.ui.androidauto.location.CarLocationRenderer
import com.mapbox.navigation.ui.androidauto.navigation.CarActiveGuidanceMarkers
import com.mapbox.navigation.ui.androidauto.navigation.CarCameraMode
import com.mapbox.navigation.ui.androidauto.navigation.CarNavigationCamera
import com.mapbox.navigation.ui.androidauto.navigation.CarNavigationInfoProvider
import com.mapbox.navigation.ui.androidauto.preview.CarRouteLineRenderer
import de.koeven.meeterz.AppState
import de.koeven.meeterz.data.FriendRow
import de.koeven.meeterz.data.MessagesStore
import de.koeven.meeterz.ev.ChargePlanner
import de.koeven.meeterz.ev.EvSettings
import de.koeven.meeterz.ev.ChargeMonitor
import de.koeven.meeterz.ev.ChargingSession
import de.koeven.meeterz.nav.NavigationController
import de.koeven.meeterz.nav.PlaceSearch
import de.koeven.meeterz.ui.km
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Eigener Standort fürs Planen: vom Handy (Teilen-Dienst) oder vom Auto-Bildschirm */
private suspend fun origin(): Point? {
    val loc: Location? = AppState.lastLocation
    if (loc != null) return Point.fromLngLat(loc.longitude, loc.latitude)
    return CarLocationProvider.getRegisteredInstance().lastLocation()?.let { Point.fromLngLat(it.longitude, it.latitude) }
}

/**
 * Route planen und gleich losfahren (Android Auto erlaubt während der Fahrt keine lange Auswahl).
 * E-Auto: reicht der Akku nicht, kommen die Ladestopps gleich als Zwischenziele in die Route.
 */
private fun Screen.navigateTo(name: String, lat: Double, lng: Double) = carNavigateTo(carContext, name, lat, lng)

internal fun carNavigateTo(carContext: CarContext, name: String, lat: Double, lng: Double) {
    // E-Auto ohne Live-Daten: zuerst den Akkustand abfragen, dann mit diesem Wert planen (wie CarPlay)
    if (EvSettings.needsBatteryInput) {
        carContext.getCarService(androidx.car.app.ScreenManager::class.java).push(CarBatteryScreen(carContext) {
            carNavigateTo(carContext, name, lat, lng)
        })
        return
    }
    // Nicht im Bildschirm-Lebenszyklus: der Bildschirm wird gleich nach dem Antippen geschlossen
    AppState.scope.launch {
        val from = origin() ?: return@launch
        val dest = NavigationController.Destination(name, lat, lng)
        var routes = NavigationController.plan(carContext, from, dest)
        when (val o = routes.firstOrNull()?.let { EvSettings.plan(it) }) {
            is ChargePlanner.Outcome.Planned -> {
                if (!o.plan.direct) {
                    val withStops = NavigationController.plan(carContext, from, dest, via = o.plan.stops.map { Point.fromLngLat(it.site.lng, it.site.lat) })
                    if (withStops.isNotEmpty()) routes = withStops
                }
                ChargingSession.plan = o.plan
                CarToast.makeText(carContext, o.plan.summary, CarToast.LENGTH_LONG).show()
            }
            is ChargePlanner.Outcome.Unreachable ->
                CarToast.makeText(carContext, tr("Akku reicht nicht – kein Ladeplan (Reichweite ca. %@ km)", o.reachKm.toInt()), CarToast.LENGTH_LONG).show()
            null -> Unit
        }
        if (routes.isNotEmpty()) NavigationController.start(routes, dest)
    }
}

/** Freie Fahrt: Karte mit Freunden, oben „Suchen“ und „Freunde“ */
class FreeDriveScreen(carContext: CarContext, private val carMap: MapboxCarMap) : Screen(carContext) {
    init { lifecycleScope.launch { ChargingSession.view.collect { invalidate() } } }
    private val location = CarLocationRenderer()
    // Start ohne Folgekamera: erst mich und Freunde einrahmen, beim Losfahren folgen (wie CarPlay)
    private val camera = CarNavigationCamera(CarCameraMode.IDLE, CarCameraMode.FOLLOWING)
    private val startFrame = CarStartFrame(camera)
    private val friendRoutes = CarFriendRoutes()
    private val friends = CarFriendMarkers()
    private val mapActions = MapboxMapActionStrip(this, camera)

    init {
        lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onResume(owner: LifecycleOwner) {
                carMap.registerObserver(location); carMap.registerObserver(camera); carMap.registerObserver(friendRoutes); carMap.registerObserver(friends)
                carMap.registerObserver(startFrame)
                carMap.setGestureHandler(camera.gestureHandler)
            }
            override fun onPause(owner: LifecycleOwner) {
                carMap.unregisterObserver(location); carMap.unregisterObserver(camera); carMap.unregisterObserver(friendRoutes); carMap.unregisterObserver(friends)
                carMap.unregisterObserver(startFrame)
                carMap.setGestureHandler(null)
            }
        })
    }

    override fun onGetTemplate(): Template = NavigationTemplate.Builder()
        .setBackgroundColor(CarColor.PRIMARY)
        .setActionStrip(
            ActionStrip.Builder()
                .apply { batteryAction(carContext)?.let { addAction(it) } }
                .addAction(Action.Builder().setTitle(tr("Suchen")).setOnClickListener { screenManager.push(CarSearchScreen(carContext)) }.build())
                .addAction(Action.Builder().setTitle(tr("Ziele")).setOnClickListener { screenManager.push(CarPlacesScreen(carContext)) }.build())
                .addAction(Action.Builder().setTitle(tr("Freunde")).setOnClickListener { screenManager.push(CarFriendsScreen(carContext)) }.build())
                .build(),
        )
        .setMapActionStrip(mapActions.build())
        .build()
}

/** Führung: Abbiegeanzeige, Routenlinie, Kamera; „Beenden“ oben */
class GuidanceScreen(carContext: CarContext, private val carMap: MapboxCarMap) : Screen(carContext) {
    init {
        lifecycleScope.launch { ChargingSession.view.collect { invalidate() } }
        lifecycleScope.launch { ChargeMonitor.forecast.collect { invalidate() } }
    }
    private val routeLine = CarRouteLineRenderer()
    private val location = CarLocationRenderer()
    private val camera = CarNavigationCamera(CarCameraMode.FOLLOWING, CarCameraMode.OVERVIEW)
    private val markers = CarActiveGuidanceMarkers()
    private val friendRoutes = CarFriendRoutes()
    private val friends = CarFriendMarkers()
    private val sign = CarSignMarker()
    private val info = CarNavigationInfoProvider().invalidateOnChange(this)
    private val mapActions = MapboxMapActionStrip(this, camera)

    /**
     * Vor Abbiegungen flacher statt 2D (wie Handy und iOS, NavigationMapBinder.maneuverPitch). Mapbox' Auto-Kamera
     * gibt ihre Kameradaten nicht heraus (`internal`) – darum per Reflection; fehlt das Feld in einer
     * künftigen Version, bleibt einfach Mapbox' Verhalten.
     */
    private val pitchObserver = RouteProgressObserver { progress ->
        val viewport = carViewport(camera) ?: return@RouteProgressObserver
        viewport.followingPitchPropertyOverride(
            NavigationMapBinder.maneuverPitch(progress, viewport.options.followingFrameOptions.defaultPitch))
        carMap.carMapSurface?.mapSurface?.mapboxMap?.cameraState?.zoom?.let { zoom ->
            viewport.followingZoomPropertyOverride(
                NavigationMapBinder.maneuverZoom(progress, (AppState.lastLocation?.speed ?: 0f).toDouble(), zoom))
        }
        viewport.evaluate()
    }

    init {
        lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onResume(owner: LifecycleOwner) {
                listOf(routeLine, location, camera, markers, friendRoutes, friends, sign, info).forEach(carMap::registerObserver)
                carMap.setGestureHandler(camera.gestureHandler)
                MapboxNavigationApp.current()?.registerRouteProgressObserver(pitchObserver)
            }
            override fun onPause(owner: LifecycleOwner) {
                MapboxNavigationApp.current()?.unregisterRouteProgressObserver(pitchObserver)
                listOf(routeLine, location, camera, markers, friendRoutes, friends, sign, info).forEach(carMap::unregisterObserver)
                carMap.setGestureHandler(null)
            }
        })
    }

    override fun onGetTemplate(): Template = NavigationTemplate.Builder()
        .setBackgroundColor(CarColor.PRIMARY)
        .setActionStrip(
            ActionStrip.Builder()
                .apply { batteryAction(carContext)?.let { addAction(it) } }
                // Ansagen wie CarPlay: Alle → Nur Warnungen → Aus; „Bescheid“ und „Stopp“ unter „Mehr“ (Leiste hat nur 4 Plätze)
                .addAction(voiceAction())
                .addAction(Action.Builder().setTitle(tr("Mehr")).setOnClickListener { screenManager.push(CarMoreScreen(carContext)) }.build())
                .addAction(Action.Builder().setTitle(tr("Beenden")).setOnClickListener { NavigationController.stop() }.build())
                .build(),
        )
        .setMapActionStrip(mapActions.build())
        .apply { info.setNavigationInfo(this) }
        .build()

    private fun voiceAction(): Action {
        val mode = NavigationController.voiceMode
        val icon = when (mode) {
            de.koeven.meeterz.nav.Speaker.Mode.ALL -> de.koeven.meeterz.R.drawable.ic_car_volume_up
            de.koeven.meeterz.nav.Speaker.Mode.ALERTS_ONLY -> de.koeven.meeterz.R.drawable.ic_car_volume_alerts
            de.koeven.meeterz.nav.Speaker.Mode.OFF -> de.koeven.meeterz.R.drawable.ic_car_volume_off
        }
        return Action.Builder()
            .setIcon(androidx.car.app.model.CarIcon.Builder(androidx.core.graphics.drawable.IconCompat.createWithResource(carContext, icon)).build())
            .setOnClickListener {
                NavigationController.voiceMode = when (mode) {
                    de.koeven.meeterz.nav.Speaker.Mode.ALL -> de.koeven.meeterz.nav.Speaker.Mode.ALERTS_ONLY
                    de.koeven.meeterz.nav.Speaker.Mode.ALERTS_ONLY -> de.koeven.meeterz.nav.Speaker.Mode.OFF
                    de.koeven.meeterz.nav.Speaker.Mode.OFF -> de.koeven.meeterz.nav.Speaker.Mode.ALL
                }
                // Kurz anzeigen, was jetzt gilt (das Symbol allein ist im Auto schwer zu lesen)
                CarToast.makeText(carContext, with(NavigationController) { NavigationController.voiceMode.title }, CarToast.LENGTH_SHORT).show()
                invalidate()
            }.build()
    }
}

/** „Mehr“ während der Führung: Kurz Bescheid geben, Stopp hinzufügen */
class CarMoreScreen(carContext: CarContext) : Screen(carContext) {
    override fun onGetTemplate(): Template = ListTemplate.Builder()
        .setTitle(tr("Mehr"))
        .setHeaderAction(Action.BACK)
        .setSingleList(ItemList.Builder()
            .addItem(Row.Builder().setTitle(tr("Kurz Bescheid geben")).setBrowsable(true)
                .setOnClickListener { screenManager.push(messageScreen(carContext)) }.build())
            .addItem(Row.Builder().setTitle(tr("Stopp hinzufügen")).setBrowsable(true)
                .setOnClickListener { screenManager.push(CarStopScreen(carContext)) }.build())
            .addItem(Row.Builder().setTitle(tr("Gefahr melden")).addText(tr("Warnt andere Meeterz-Fahrer")).setBrowsable(true)
                .setOnClickListener { screenManager.push(CarHazardScreen(carContext)) }.build())
            .addItem(passengerRow(carContext, screenManager))
            .build())
        .build()
}

/** Eintrag „Wer fährt mit?“ (in „Mehr“ und in der Freundesliste, wie CarPlay) */
fun passengerRow(carContext: CarContext, screenManager: androidx.car.app.ScreenManager): Row {
    val riders = de.koeven.meeterz.social.Passengers.ridingNowIds.mapNotNull { id -> AppState.friends.value.firstOrNull { it.friendId == id }?.firstName }
    return Row.Builder().setTitle(tr("Wer fährt mit?"))
        .addText(if (riders.isEmpty()) tr("Beifahrer zum Konvoi zählen") else riders.joinToString(", ")).setBrowsable(true)
        .setOnClickListener { screenManager.push(CarPassengersScreen(carContext)) }.build()
}

/**
 * „Wer fährt mit?“ (wie CarPlay): Freunde von Hand als Mitfahrer markieren (Beifahrer, Rückbank) – sie zählen dann
 * zum Konvoi. Nahe Freunde zuerst; die automatische Erkennung braucht ein paar Minuten gemeinsamer Fahrt.
 */
class CarPassengersScreen(carContext: CarContext) : Screen(carContext) {
    override fun onGetTemplate(): Template {
        val me = AppState.lastLocation
        val live = AppState.hub.positions.value
        fun distance(f: de.koeven.meeterz.data.FriendRow): Double {
            val p = live[f.friendId] ?: return Double.MAX_VALUE
            return me?.let { ChargePlanner.distance(it.latitude, it.longitude, p.lat, p.lng) } ?: Double.MAX_VALUE
        }
        val riding = de.koeven.meeterz.social.Passengers.ridingNowIds
        val list = ItemList.Builder().setNoItemsMessage(tr("Noch keine Freunde."))
        AppState.friends.value.filter { it.isAccepted }.sortedBy { distance(it) }.take(6).forEach { f ->
            val on = f.friendId in riding
            list.addItem(Row.Builder().setTitle(f.firstName)
                .apply {
                    when {
                        on -> addText(tr("fährt mit"))
                        distance(f) < 300 -> addText(tr("in der Nähe"))
                    }
                }
                .setOnClickListener {
                    de.koeven.meeterz.social.Passengers.setRiding(f.friendId, !on)
                    invalidate()
                }.build())
        }
        return ListTemplate.Builder().setTitle(tr("Wer fährt mit?")).setHeaderAction(Action.BACK).setSingleList(list.build()).build()
    }
}

/**
 * Akku oben in der Leiste (CarPlay: Akku-Kästchen bzw. Lade-Ring): beim Laden Fortschritt und Restzeit,
 * sonst während der Führung die Prognose am nächsten Stopp bzw. Ziel. Antippen zeigt den Ladeplan.
 */
private fun batteryAction(carContext: CarContext): Action? {
    val text = ChargingSession.view.value?.short ?: ChargeMonitor.forecast.value?.text ?: return null
    return Action.Builder().setTitle(text).setOnClickListener {
        val plan = ChargingSession.plan
        CarToast.makeText(carContext, plan?.summary ?: text, CarToast.LENGTH_LONG).show()
    }.build()
}

/**
 * Kurz Bescheid geben (CarPlay: „Kurz Bescheid geben“): sind am Ziel Freunde oder fahren welche hin,
 * gleich die Schnellantworten an sie – sonst erst den Freund wählen.
 */
fun messageScreen(carContext: CarContext): Screen {
    val partners = MessagesStore.recipientsAtDestination()
    // Mit Konvoi: erst die Liste (wer wo ist), sonst gleich die Schnellantworten an alle am Ziel
    return if (partners.isNotEmpty() && de.koeven.meeterz.social.Convoy.members().isEmpty() && carArrivals() == null) CarQuickRepliesScreen(carContext, partners)
    else CarMessageRecipientsScreen(carContext)
}

class CarMessageRecipientsScreen(carContext: CarContext) : Screen(carContext) {
    override fun onGetTemplate(): Template {
        val list = ItemList.Builder().setNoItemsMessage(tr("Noch keine Freunde."))
        // Konvoi zuerst: wer zum selben Ziel fährt, mit Abstand entlang meiner Route
        // Zeitleiste „Wer ist wann da“ (auf der Karte gibt es in Android Auto keinen Platz für eigene Einblendungen)
        val arrivals = carArrivals()
        if (arrivals != null) list.addItem(Row.Builder().setTitle(tr("Wer ist wann da")).addText(arrivals.first).setBrowsable(true)
            .setOnClickListener { screenManager.push(CarArrivalsScreen(carContext)) }.build())
        val convoy = de.koeven.meeterz.social.Convoy.members().take(if (arrivals != null) 3 else 4)
        if (convoy.isNotEmpty()) list.addItem(Row.Builder().setTitle(tr("Pause vorschlagen")).addText(tr("Rastplatz, den alle noch erreichen"))
            .setOnClickListener {
                AppState.scope.launch { de.koeven.meeterz.social.ConvoyPause.propose() }
                screenManager.pop()
            }.build())
        val atDestination = MessagesStore.recipientsAtDestination()
        if (atDestination.size > 1) list.addItem(Row.Builder().setTitle(tr("Alle am Ziel")).addText(atDestination.joinToString(", ") { it.firstName })
            .setOnClickListener { screenManager.push(CarQuickRepliesScreen(carContext, atDestination)) }.build())
        convoy.forEach { m ->
            list.addItem(Row.Builder().setTitle(m.friend.displayName).addText(m.summary)
                .setOnClickListener { screenManager.push(CarQuickRepliesScreen(carContext, listOf(m.friend))) }.build())
        }
        MessagesStore.friendsByDistance().filter { f -> convoy.none { it.friend.friendId == f.friendId } }.take(maxOf(0, 4 - convoy.size)).forEach { f ->
            list.addItem(Row.Builder().setTitle(f.displayName)
                .setOnClickListener { screenManager.push(CarQuickRepliesScreen(carContext, listOf(f))) }.build())
        }
        return ListTemplate.Builder().setTitle(tr("Bescheid geben")).setHeaderAction(Action.BACK).setSingleList(list.build()).build()
    }
}

class CarQuickRepliesScreen(carContext: CarContext, private val to: List<FriendRow>) : Screen(carContext) {
    override fun onGetTemplate(): Template {
        val eta = NavigationController.guidance.value?.let { System.currentTimeMillis() + (it.remainingSeconds * 1000).toLong() }
        val list = ItemList.Builder()
        MessagesStore.quickReplies(eta).take(6).forEach { text ->
            list.addItem(Row.Builder().setTitle(text).setOnClickListener {
                lifecycleScope.launch {
                    val sent = AppState.messages.send(text, to.map { it.friendId })
                    CarToast.makeText(carContext, if (sent > 0) tr("Gesendet: „%@“", text) else tr("Nachricht nicht gesendet"), CarToast.LENGTH_LONG).show()
                    screenManager.popToRoot()
                }
            }.build())
        }
        return ListTemplate.Builder().setTitle(tr("An %@", to.joinToString(", ") { it.firstName }))
            .setHeaderAction(Action.BACK).setSingleList(list.build()).build()
    }
}

/** Freunde mit Standort; Antippen fährt zu ihnen (CarPlay: FriendsMenu) */
class CarFriendsScreen(carContext: CarContext) : Screen(carContext) {
    init {
        lifecycleScope.launch { AppState.hub.positions.collect { invalidate() } }
    }

    override fun onGetTemplate(): Template {
        val live = AppState.hub.positions.value
        val me = AppState.lastLocation
        val list = ItemList.Builder().setNoItemsMessage(tr("Gerade teilt kein Freund seinen Standort."))
        // Vor der Fahrt schon festlegen, wer mitfährt (auch in „Mehr“ während der Fahrt)
        if (AppState.friends.value.any { it.isAccepted }) list.addItem(passengerRow(carContext, screenManager))
        AppState.friends.value.filter { it.isAccepted }.take(5).forEach { f ->
            val p = live[f.friendId]
            val lat = p?.lat ?: f.lat ?: return@forEach
            val lng = p?.lng ?: f.lng ?: return@forEach
            val detail = me?.let { km(FloatArray(1).also { r -> Location.distanceBetween(it.latitude, it.longitude, lat, lng, r) }[0].toDouble()) }
            list.addItem(
                Row.Builder().setTitle(f.firstName)
                    .apply { detail?.let { addText(it) } }
                    .setOnClickListener { navigateTo(f.firstName, lat, lng); screenManager.pop() }
                    .build(),
            )
        }
        return ListTemplate.Builder().setTitle(tr("Freunde")).setHeaderAction(Action.BACK).setSingleList(list.build()).build()
    }
}

/** Ziel suchen (Tastatur nur im Stand – das regelt Android Auto selbst) */
class CarSearchScreen(carContext: CarContext) : Screen(carContext) {
    private var results: List<PlaceSearch.Place> = emptyList()
    private var job: Job? = null

    override fun onGetTemplate(): Template {
        val list = ItemList.Builder()
        results.forEach { place ->
            list.addItem(
                Row.Builder().setTitle(place.name)
                    .apply { place.address?.let { addText(it) } }
                    .apply { place.hours?.let { addText(de.koeven.meeterz.nav.OsmPlaces.status(it)) } }
                    .setOnClickListener { screenManager.push(CarPlaceScreen(carContext, place)) }
                    .build(),
            )
        }
        return SearchTemplate.Builder(object : SearchTemplate.SearchCallback {
            override fun onSearchTextChanged(searchText: String) = search(searchText)
            override fun onSearchSubmitted(searchTerm: String) = search(searchTerm)
        })
            .setHeaderAction(Action.BACK)
            .setSearchHint(tr("Ziel oder Adresse"))
            .setShowKeyboardByDefault(true)
            .setItemList(list.build())
            .build()
    }

    private fun search(text: String) {
        job?.cancel()
        job = lifecycleScope.launch {
            delay(300)
            val me = AppState.lastLocation
            results = PlaceSearch.search(text, me?.latitude, me?.longitude)
            invalidate()
            // Öffnungszeiten nachreichen (eine Abfrage für alle Treffer)
            results = PlaceSearch.withHours(results.take(6)) + results.drop(6)
            invalidate()
        }
    }
}

/**
 * Ortskarte vor der Fahrt (wie die CarPlay-Ortskarte, ohne Bilder): Adresse, Öffnungsstatus, Telefon;
 * „Losfahren“ und „Anrufen“. Angaben aus Mapbox und OpenStreetMap.
 */
class CarPlaceScreen(carContext: CarContext, private val place: PlaceSearch.Place) : Screen(carContext) {
    private var details: PlaceSearch.Details? = null

    init {
        lifecycleScope.launch { details = PlaceSearch.details(place.name, place.lat, place.lng); invalidate() }
    }

    override fun onGetTemplate(): Template {
        val d = details
        val pane = androidx.car.app.model.Pane.Builder()
        fun row(title: String, text: String) = pane.addRow(Row.Builder().setTitle(title).addText(text).build())
        row(d?.category ?: tr("Adresse"), d?.address ?: place.address ?: "–")
        (d?.hours ?: place.hours)?.let { row(tr("Öffnungszeiten"), de.koeven.meeterz.nav.OsmPlaces.status(it)) }
            ?: d?.hoursText?.let { row(tr("Öffnungszeiten"), it) }
        d?.phone?.let { row(tr("Telefon"), it) }
        pane.addAction(Action.Builder().setTitle(tr("Losfahren")).setOnClickListener {
            navigateTo(place.name, place.lat, place.lng); screenManager.popToRoot()
        }.build())
        d?.phone?.let { phone ->
            pane.addAction(Action.Builder().setTitle(tr("Anrufen")).setOnClickListener {
                runCatching { carContext.startCarApp(android.content.Intent(android.content.Intent.ACTION_DIAL,
                    android.net.Uri.parse("tel:" + phone.filterNot { it.isWhitespace() }))) }
            }.build())
        }
        return androidx.car.app.model.PaneTemplate.Builder(pane.build()).setTitle(place.name).setHeaderAction(Action.BACK).build()
    }
}

/** Zwischenstopp unterwegs (CarPlay: Suche mit Kategorien während der Fahrt): Kategorie wählen, Ort antippen.
 *  Während der Fahrt entlang der Route (Strecke bis dorthin), bei Tankstellen mit Spritpreisen. */
class CarStopScreen(carContext: CarContext, private val category: PlaceSearch.Category? = null) : Screen(carContext) {
    private var places: List<PlaceSearch.Stopover>? = null

    init {
        if (category != null) lifecycleScope.launch {
            val me = AppState.lastLocation
            places = if (me == null) emptyList() else PlaceSearch.stopovers(category, me.latitude, me.longitude)
            invalidate()
            // Öffnungszeiten nachreichen (eine Abfrage für die gezeigten Orte)
            val shown = places.orEmpty().take(6)
            if (shown.isNotEmpty()) {
                val withHours = PlaceSearch.withHours(shown.map { it.place })
                places = shown.zip(withHours) { s, p -> s.copy(place = p) } + places.orEmpty().drop(6)
                invalidate()
            }
        }
    }

    override fun onGetTemplate(): Template {
        val list = ItemList.Builder()
        if (category == null) {
            for (c in PlaceSearch.Category.stopovers) {
                list.addItem(Row.Builder().setTitle(c.title)
                    .apply { if (NavigationController.guidance.value != null) addText(tr("Entlang der Route")) }
                    .setBrowsable(true)
                    .setOnClickListener { screenManager.push(CarStopScreen(carContext, c)) }.build())
            }
            list.addItem(Row.Builder().setTitle(tr("Suchen")).setBrowsable(true).setOnClickListener { screenManager.push(CarSearchScreen(carContext)) }.build())
        } else {
            val me = AppState.lastLocation
            list.setNoItemsMessage(tr("Nichts gefunden"))
            places?.take(6)?.forEach { s ->
                val p = s.place
                val away = s.aheadText ?: me?.let { km(ChargePlanner.distance(it.latitude, it.longitude, p.lat, p.lng)) }
                list.addItem(Row.Builder().setTitle(p.name)
                    .apply { listOfNotNull(away, s.price?.text?.takeIf { it.isNotEmpty() }).joinToString(" · ").takeIf { it.isNotEmpty() }?.let { addText(it) } }
                    .apply { p.hours?.let { addText(de.koeven.meeterz.nav.OsmPlaces.status(it)) } }
                    .setOnClickListener {
                        AppState.scope.launch { NavigationController.addStop(carContext, p.name, p.lat, p.lng) }
                        screenManager.popToRoot()
                    }.build())
            }
        }
        return ListTemplate.Builder().setTitle(category?.title ?: tr("Zwischenstopp")).setHeaderAction(Action.BACK)
            .apply { if (category != null && places == null) setLoading(true) else setSingleList(list.build()) }.build()
    }
}

/** Gefahr melden (CarPlay: „Gefahr melden“ in „Mehr“): Art wählen, dann zurück zur Karte */
class CarHazardScreen(carContext: CarContext) : Screen(carContext) {
    override fun onGetTemplate(): Template {
        val list = ItemList.Builder()
        for (k in de.koeven.meeterz.data.HazardStore.Kind.entries) {
            list.addItem(Row.Builder().setTitle(k.title).setOnClickListener {
                AppState.scope.launch { de.koeven.meeterz.data.HazardStore.report(k) }
                screenManager.popToRoot()
            }.build())
        }
        return ListTemplate.Builder().setTitle(tr("Gefahr melden")).setHeaderAction(Action.BACK).setSingleList(list.build()).build()
    }
}

/** Gespeicherte Orte (Zuhause, Arbeit, Favoriten) – Antippen fährt los */
class CarPlacesScreen(carContext: CarContext) : Screen(carContext) {
    override fun onGetTemplate(): Template {
        val list = ItemList.Builder().setNoItemsMessage(tr("Noch keine Orte gespeichert – in der App bei der Routenvorschau „Als Zuhause“ o. Ä. wählen."))
        // Vorschlag für jetzt (Termin oder häufiges Ziel)
        de.koeven.meeterz.suggest.RouteSuggestions.current.value?.let { s ->
            list.addItem(Row.Builder().setTitle(s.title).addText(s.subtitle)
                .setOnClickListener { navigateTo(s.name.ifEmpty { s.title }, s.lat, s.lng); screenManager.pop() }.build())
        }
        // Treffen zuerst (wie CarPlay: Treffen in der Zielliste); Einladungen öffnen Annehmen/Ablehnen
        AppState.meetups.meetups.value.filter { it.isAccepted || (it.incoming && it.isPending) }.take(4).forEach { m ->
            list.addItem(
                Row.Builder().setTitle(m.placeName)
                    .addText((if (m.isPending) tr("Einladung von %@", m.otherName) else tr("Treffen mit %@", m.withText)) +
                        (m.meetAtSeconds?.let { " · " + de.koeven.meeterz.ui.meetupTime(it) } ?: ""))
                    .setOnClickListener {
                        if (m.isPending) screenManager.push(CarMeetupInviteScreen(carContext, m))
                        else { navigateTo(m.placeName, m.lat, m.lng); screenManager.pop() }
                    }
                    .build(),
            )
        }
        AppState.favorites.items.value.sortedBy { listOf("home", "work", "other").indexOf(it.kind) }.forEach { fav ->
            list.addItem(
                Row.Builder().setTitle(fav.label)
                    .apply { fav.address?.let { addText(it) } }
                    .setOnClickListener { navigateTo(fav.label, fav.lat, fav.lng); screenManager.pop() }
                    .build(),
            )
        }
        // Zuletzt angefahren (ohne Orte, die schon als Favorit da sind); Android Auto zeigt höchstens ~6 Zeilen
        val favs = AppState.favorites.items.value
        de.koeven.meeterz.suggest.Recents.items.value.filter { r -> favs.none { ChargePlanner.distance(it.lat, it.lng, r.lat, r.lng) < 50 } }.take(4).forEach { r ->
            list.addItem(Row.Builder().setTitle(r.name).apply { r.address?.let { addText(it) } }
                .setOnClickListener { navigateTo(r.name, r.lat, r.lng); screenManager.pop() }.build())
        }
        return ListTemplate.Builder().setTitle(tr("Ziele")).setHeaderAction(Action.BACK).setSingleList(list.build()).build()
    }
}

/** Einladung im Auto beantworten; Annehmen fährt gleich hin */
class CarMeetupInviteScreen(carContext: CarContext, private val m: de.koeven.meeterz.data.Meetup) : Screen(carContext) {
    override fun onGetTemplate(): Template =
        androidx.car.app.model.MessageTemplate.Builder(m.placeName + (m.meetAtSeconds?.let { "\n" + de.koeven.meeterz.ui.meetupTime(it) } ?: ""))
            .setTitle(tr("%@ möchte sich treffen", m.otherName))
            .setHeaderAction(Action.BACK)
            .addAction(Action.Builder().setTitle(tr("Ablehnen")).setOnClickListener {
                AppState.scope.launch { AppState.meetups.respond(m, false) }; screenManager.pop()
            }.build())
            .addAction(Action.Builder().setTitle(tr("Annehmen & los")).setOnClickListener {
                AppState.scope.launch { AppState.meetups.respond(m, true) }
                navigateTo(m.placeName, m.lat, m.lng); screenManager.popToRoot()
            }.build())
            .build()
}

/** Kameradaten von Mapbox' Auto-Kamera (intern) – null, solange sie noch nicht an der Karte hängt */
private fun carViewport(camera: CarNavigationCamera): MapboxNavigationViewportDataSource? = runCatching {
    CarNavigationCamera::class.java.getDeclaredField("viewportDataSource").apply { isAccessible = true }
        .get(camera) as? MapboxNavigationViewportDataSource
}.getOrNull()


/** „Akkustand jetzt?“ – 100 % bis 10 %, der zuletzt eingestellte Wert ist markiert (CarPlay: showChargePicker) */
class CarBatteryScreen(carContext: CarContext, private val then: () -> Unit) : Screen(carContext) {
    override fun onGetTemplate(): Template {
        val current = Math.round(EvSettings.manualPercent / 10.0) * 10
        val vehicle = EvSettings.vehicle
        val list = ItemList.Builder()
        for (value in 100 downTo 10 step 10) {
            list.addItem(Row.Builder().setTitle("$value %")
                .addText(if (value.toLong() == current) tr("aktuell") else vehicle?.let { tr("ca. %lld km", (it.battery / it.consumption * value).toInt()) } ?: "")
                .setOnClickListener {
                    EvSettings.manualPercent = value.toDouble()
                    if (NavigationController.guidance.value != null) de.koeven.meeterz.ev.ChargeMonitor.manualSoc(value.toDouble())
                    screenManager.pop()
                    then()
                }.build())
        }
        return ListTemplate.Builder().setTitle(tr("Akkustand jetzt?")).setHeaderAction(Action.BACK).setSingleList(list.build()).build()
    }
}

/**
 * Freie Fahrt beim Start (wie CarPlay frameStart): mich und Freunde bis 200 km einrahmen, solange man steht.
 * Sobald es losgeht (> 10 km/h), übernimmt die Folgekamera. Einmal je Bildschirm.
 */
private class CarStartFrame(private val camera: CarNavigationCamera) : com.mapbox.maps.extension.androidauto.MapboxCarMapObserver {
    private var framed = false
    private var following = false
    private var job: kotlinx.coroutines.Job? = null

    override fun onAttached(mapboxCarMapSurface: com.mapbox.maps.extension.androidauto.MapboxCarMapSurface) {
        if (following) return
        job = kotlinx.coroutines.MainScope().launch {
            var me = AppState.lastLocation
            var tries = 0
            while (me == null && tries++ < 40) { delay(500); me = AppState.lastLocation }
            val start = me ?: run { camera.updateCameraMode(CarCameraMode.FOLLOWING); following = true; return@launch }
            val map = mapboxCarMapSurface.mapSurface.mapboxMap
            // Erst nach dem Laden des Kartenstils – sonst setzt Mapbox die Kamera danach auf den Stil-Standard
            // (ganze Welt) zurück (wie CarPlay, Diagnose 20.11.)
            var wait = 0
            while (!map.isStyleLoaded() && wait++ < 100) delay(100)
            val here = Point.fromLngLat(start.longitude, start.latitude)
            fun nearbyFriends(): List<Point> {
                val live = AppState.hub.positions.value
                return AppState.friends.value.filter { it.isAccepted }.mapNotNull { f ->
                    val p = live[f.friendId]
                    val lat = p?.lat ?: f.lat ?: return@mapNotNull null
                    val lng = p?.lng ?: f.lng ?: return@mapNotNull null
                    if (de.koeven.meeterz.ev.ChargePlanner.distance(start.latitude, start.longitude, lat, lng) > 200_000) null
                    else Point.fromLngLat(lng, lat)
                }
            }
            fun frame(friends: List<Point>) {
                val cam = if (friends.isEmpty()) com.mapbox.maps.CameraOptions.Builder().center(here).zoom(15.5).bearing(0.0).pitch(0.0).build()
                else map.cameraForCoordinates(listOf(here) + friends, com.mapbox.maps.CameraOptions.Builder().bearing(0.0).pitch(0.0).build(),
                    com.mapbox.maps.EdgeInsets(80.0, 80.0, 80.0, 80.0), 16.0, null)
                map.setCamera(cam)
                de.koeven.meeterz.Diag.log("Android Auto Start: Karte zeigt mich" + if (friends.isEmpty()) "" else " und ${friends.size} Freunde")
            }
            val framedAt = System.currentTimeMillis()
            var withFriends = true
            if (!framed) {
                framed = true
                val friends = nearbyFriends()
                withFriends = friends.isNotEmpty()
                frame(friends)
            }
            while (true) {
                delay(1000)
                // Freunde kommen oft erst Sekunden nach dem Start – einmal mit ihnen nachrahmen (wie CarPlay, 21.11.)
                if (!withFriends && System.currentTimeMillis() - framedAt < 30_000) {
                    val friends = nearbyFriends()
                    if (friends.isNotEmpty()) { withFriends = true; frame(friends) }
                }
                if ((AppState.lastLocation?.speed ?: 0f) > 3f) { camera.updateCameraMode(CarCameraMode.FOLLOWING); following = true; break }
            }
        }
    }

    override fun onDetached(mapboxCarMapSurface: com.mapbox.maps.extension.androidauto.MapboxCarMapSurface) { job?.cancel() }
}
