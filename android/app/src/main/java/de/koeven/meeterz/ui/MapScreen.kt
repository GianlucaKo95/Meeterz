package de.koeven.meeterz.ui

import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.LocalGasStation
import androidx.compose.material.icons.filled.EvStation
import androidx.compose.material.icons.filled.LocalParking
import androidx.compose.material.icons.filled.Restaurant
import androidx.compose.material.icons.filled.LocalCafe
import de.koeven.meeterz.tr
import androidx.compose.material.icons.filled.AddLocationAlt
import androidx.compose.material.icons.filled.Place
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.BookmarkBorder
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.Warning
import androidx.compose.foundation.layout.size
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.material3.FilterChip
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Switch
import androidx.compose.material3.TimeInput
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.material.icons.filled.Event
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.horizontalScroll
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.TextButton
import android.widget.Toast
import de.koeven.meeterz.data.MessagesStore
import de.koeven.meeterz.ev.ChargePlanner
import de.koeven.meeterz.ev.ChargeMonitor
import de.koeven.meeterz.ev.ChargingSession
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.People
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material.icons.filled.Campaign
import androidx.compose.material3.OutlinedTextField
import androidx.compose.foundation.combinedClickable
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.AddCircleOutline
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Work
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.automirrored.filled.DirectionsWalk
import androidx.compose.material.icons.automirrored.filled.DirectionsBike
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.border
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.material.icons.filled.NearMe
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Phone
import androidx.compose.material.icons.filled.Navigation
import androidx.compose.material.icons.outlined.NearMe as NearMeOutlined
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.height
import androidx.compose.material3.AssistChip
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.produceState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.mapbox.geojson.Point
import com.mapbox.maps.CameraOptions
import com.mapbox.maps.MapView
import com.mapbox.maps.Style
import com.mapbox.maps.interactions.standard.generated.standardPoi
import com.mapbox.maps.plugin.compass.compass
import com.mapbox.maps.plugin.scalebar.scalebar
import com.mapbox.maps.plugin.annotation.annotations
import com.mapbox.maps.plugin.annotation.generated.PointAnnotationManager
import com.mapbox.maps.plugin.annotation.generated.PointAnnotationOptions
import com.mapbox.maps.plugin.annotation.generated.createPointAnnotationManager
import com.mapbox.maps.plugin.annotation.generated.createPolylineAnnotationManager
import com.mapbox.maps.plugin.annotation.generated.PolylineAnnotationOptions
import com.mapbox.maps.plugin.locationcomponent.createDefault2DPuck
import com.mapbox.maps.plugin.locationcomponent.location
import com.mapbox.maps.plugin.viewport.viewport
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import com.mapbox.maps.plugin.gestures.gestures
import com.mapbox.maps.plugin.animation.camera
import com.mapbox.maps.plugin.animation.flyTo
import com.mapbox.navigation.base.route.NavigationRoute
import de.koeven.meeterz.AppState
import de.koeven.meeterz.nav.NavigationController
import de.koeven.meeterz.nav.PlaceSearch
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Date

/** Hauptkarte: Freunde, Suche, Routenvorschau und Führung */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun MapScreen() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val friends by AppState.friends.collectAsState()
    val live by AppState.hub.positions.collectAsState()
    val guidance by NavigationController.guidance.collectAsState()
    val meetups by AppState.meetups.meetups.collectAsState()
    val mapStyle by UiPreferences.mapStyle.collectAsState()
    val map3d by UiPreferences.map3d.collectAsState()
    val staleHours by UiPreferences.staleHours.collectAsState()
    val visibleFriends = remember(friends, live, staleHours) {
        friends.filter { friend ->
            val updated = live[friend.friendId]?.ts ?: friend.locationUpdatedAt?.let { runCatching { java.time.Instant.parse(it).toEpochMilli() / 1000.0 }.getOrNull() }
            staleHours == 0 || updated == null || System.currentTimeMillis() / 1000.0 - updated <= staleHours * 3600.0
        }
    }
    val visibleFriendIds = remember(visibleFriends) { visibleFriends.map { it.friendId }.toSet() }
    var mapStyleRevision by remember { mutableStateOf(0) }

    // Kompass unter die rechte Knopfspalte (Freunde, Kartenansicht, Standort) statt dahinter – wie iOS unter der
    // Knopfleiste: Statusleiste + 8 + 52 (Suche) + 10 + 48 + 8 + 48 + 10 dp
    val density = context.resources.displayMetrics.density
    val mapView = remember {
        MapView(context).apply {
            mapboxMap.loadStyle(if (UiPreferences.mapStyle.value == "satellite") Style.STANDARD_SATELLITE else Style.STANDARD)
            // Kein Kompass: die Ausrichtung schaltet der Ortungspfeil (wie iOS, 23.11.)
            compass.updateSettings { enabled = false }
            // Maßstab lag über der Statusleiste (Foto 17.11.) – iOS zeigt keinen
            scalebar.enabled = false
            mapboxMap.setCamera(CameraOptions.Builder().zoom(14.0).build())
            location.updateSettings {
                enabled = true
                locationPuck = createDefault2DPuck(withBearing = true)
            }
            viewport.transitionTo(followMe(viewport, map3d = false))
        }
    }
    val binder = remember { NavigationMapBinder(mapView) }
    val isMeetupGuidance = guidance?.destination?.let { destination ->
        meetups.any { meetup -> meetup.isAccepted && ChargePlanner.distance(meetup.lat, meetup.lng, destination.lat, destination.lng) < 300 }
    } == true
    LaunchedEffect(isMeetupGuidance) { binder.setMeetingMode(isMeetupGuidance) }
    LaunchedEffect(mapStyle) {
        mapView.mapboxMap.loadStyle(if (mapStyle == "satellite") Style.STANDARD_SATELLITE else Style.STANDARD) {
            binder.refreshStyle()
            mapStyleRevision++
        }
    }
    // Eine Ausrichtung für 2D, 3D und Fahrt (wie iOS): Ortungspfeil folgt beim ersten Tipp, danach schaltet er um
    val northUpPref by UiPreferences.northUp.collectAsState()
    val turnsWithMe = !northUpPref
    var followingMe by remember { mutableStateOf(true) }
    DisposableEffect(mapView) {
        val observer = com.mapbox.maps.plugin.viewport.ViewportStatusObserver { _, to, _ ->
            followingMe = (to as? com.mapbox.maps.plugin.viewport.ViewportStatus.State)?.state is
                com.mapbox.maps.plugin.viewport.state.FollowPuckViewportState
        }
        mapView.viewport.addStatusObserver(observer)
        onDispose { mapView.viewport.removeStatusObserver(observer) }
    }
    LaunchedEffect(map3d, northUpPref) {
        val following = (mapView.viewport.status as? com.mapbox.maps.plugin.viewport.ViewportStatus.State)?.state is
            com.mapbox.maps.plugin.viewport.state.FollowPuckViewportState
        if (following && guidance == null) mapView.viewport.transitionTo(followMe(mapView.viewport, map3d, turnsWithMe))
        else mapView.mapboxMap.setCamera(CameraOptions.Builder().pitch(if (map3d) 45.0 else 0.0).build())
    }
    DisposableEffect(Unit) { binder.attach(); onDispose { binder.detach() } }
    DisposableEffect(mapView) { val t = TrafficLayer.install(mapView.mapboxMap); onDispose { t.cancel() } }
    LaunchedEffect(guidance != null) {
        binder.setActive(guidance != null)
        if (guidance == null) mapView.viewport.transitionTo(followMe(mapView.viewport, map3d, turnsWithMe))
    }

    val friendRoutes by AppState.routes.routes.collectAsState()
    val lines = remember(mapView, mapStyleRevision) { mapView.annotations.createPolylineAnnotationManager() }
    LaunchedEffect(friendRoutes, visibleFriendIds, mapStyleRevision) {
        // Routen der Freunde in ihrer Farbe mit dunkler Umrandung (wie iOS)
        lines.deleteAll()
        for ((id, r) in friendRoutes.filterKeys { it in visibleFriendIds }) {
            val points = r.coordinates.map { Point.fromLngLat(it.first, it.second) }
            lines.create(PolylineAnnotationOptions().withPoints(points).withLineColor(FriendPalette.routeCasing.toArgb()).withLineWidth(8.0))
            lines.create(PolylineAnnotationOptions().withPoints(points).withLineColor(FriendPalette.routeColor(id).toArgb()).withLineWidth(5.0))
        }
    }
    var selectedFriend by remember { mutableStateOf<String?>(null) }
    val annotations: PointAnnotationManager = remember(mapView, mapStyleRevision) {
        mapView.annotations.createPointAnnotationManager().apply {
            // Freund antippen → Aktionen (wie iOS FriendActionSheet)
            addClickListener { a ->
                // Ungesehene Story zuerst abspielen (Ring), sonst das Freundes-Fenster (wie iOS tapFriend)
                a.getData()?.asString?.let { if (de.koeven.meeterz.data.StoriesStore.hasUnseen(it)) de.koeven.meeterz.data.StoriesStore.open(it) else selectedFriend = it }
                true
            }
        }
    }
    val avatars by de.koeven.meeterz.data.AvatarStore.images.collectAsState()
    val passengerVersion by de.koeven.meeterz.social.Passengers.version.collectAsState()
    val stories by de.koeven.meeterz.data.StoriesStore.stories.collectAsState()
    LaunchedEffect(visibleFriends, live, friendRoutes, avatars, passengerVersion, mapStyleRevision, stories) {
        annotations.deleteAll()
        val riding = de.koeven.meeterz.social.Passengers.riding
        for (f in visibleFriends.filter { it.isAccepted && it.friendId !in riding }) {
            val pos = live[f.friendId]
            val lat = pos?.lat ?: f.lat ?: continue
            val lng = pos?.lng ?: f.lng ?: continue
            annotations.create(
                PointAnnotationOptions()
                    .withPoint(Point.fromLngLat(lng, lat))
                    .withIconImage((avatars[f.friendId]?.let { de.koeven.meeterz.data.AvatarStore.pin(it) } ?: initialsBubble(f.initials, FriendPalette.color(f.friendId)))
                        .let { if (de.koeven.meeterz.data.StoriesStore.hasUnseen(f.friendId)) storyRing(it) else it })
                    .withTextField(friendRoutes[f.friendId]?.let { "${f.firstName} · ${clockAt(it.eta)}" } ?: f.firstName)
                    .withData(com.google.gson.JsonPrimitive(f.friendId))
                    .withTextOffset(listOf(0.0, 2.2))
                    .withTextSize(12.0)
            )
        }
    }

    // Suche und Vorschau
    var query by remember { mutableStateOf("") }
    var results by remember { mutableStateOf<List<PlaceSearch.Place>>(emptyList()) }
    var preview by remember { mutableStateOf<Pair<NavigationController.Destination, List<NavigationRoute>>?>(null) }
    var planning by remember { mutableStateOf(false) }
    var selectedRoute by remember { mutableStateOf(0) }
    var showFriends by remember { mutableStateOf(false) }
    var showSettings by remember { mutableStateOf(false) }
    var showMeetups by remember { mutableStateOf(false) }
    var showUnterwegs by remember { mutableStateOf(false) }
    var showGroupMeetup by remember { mutableStateOf(false) }
    var showStoryComposer by remember { mutableStateOf(false) }
    var showTrips by remember { mutableStateOf(false) }
    // Neue Story eines Freundes: auf dem Handy kurzer Hinweis (iOS: Banner), im Auto übernimmt Android Auto
    LaunchedEffect(Unit) {
        de.koeven.meeterz.data.StoriesStore.received.collect { st ->
            if (!NavigationController.carConnected)
                android.widget.Toast.makeText(context, tr("%@ hat eine Story geteilt", st.firstName), android.widget.Toast.LENGTH_SHORT).show()
        }
    }
    var planCandidate by remember { mutableStateOf<de.koeven.meeterz.data.MeetupCandidate?>(null) }
    var inviteTo by remember { mutableStateOf<NavigationController.Destination?>(null) }
    /** Übernommener Ladeplan: Vorschau-Route führt schon über die Säulen */
    var adopted by remember { mutableStateOf<ChargePlanner.Plan?>(null) }
    val favorites by AppState.favorites.items.collectAsState()
    val car by AppState.vehicle.status.collectAsState()
    var droppedPin by remember { mutableStateOf<DroppedPin?>(null) }
    var travelMode by remember { mutableStateOf(de.koeven.meeterz.nav.TravelMode.saved) }
    /** Ladezeit des Ladeplans in der Vorschau – Ankunft rechnet sie mit ein (wie iOS) */
    var previewChargeSeconds by remember { mutableStateOf(0.0) }
    fun planTo(name: String, address: String?, lat: Double, lng: Double, mode: de.koeven.meeterz.nav.TravelMode = travelMode) {
        val me = AppState.lastLocation ?: return
        val dest = NavigationController.Destination(name, lat, lng, address)
        planning = true
        results = emptyList()
        travelMode = mode; de.koeven.meeterz.nav.TravelMode.saved = mode
        scope.launch {
            val routes = NavigationController.plan(context, Point.fromLngLat(me.longitude, me.latitude), dest, mode = mode)
            planning = false
            if (routes.isNotEmpty()) { preview = dest to routes; adopted = null; selectedRoute = 0 }
        }
    }

    /** Ladestopps als Zwischenziele in die Route nehmen */
    suspend fun adopt(dest: NavigationController.Destination, plan: ChargePlanner.Plan) {
        val me = AppState.lastLocation ?: return
        val routes = NavigationController.plan(context, Point.fromLngLat(me.longitude, me.latitude), dest,
            via = plan.stops.map { Point.fromLngLat(it.site.lng, it.site.lat) })
        if (routes.isNotEmpty()) { preview = dest to routes; adopted = plan; selectedRoute = 0; ChargingSession.plan = plan }
    }
    LaunchedEffect(preview, selectedRoute, guidance == null, mapStyleRevision) { if (guidance == null) binder.showPreview(preview?.second, selectedRoute) }
    // Von außen angefragtes Ziel (Losfahr-Erinnerung, Widget): Route zeigen
    val openPlace by AppState.openPlace.collectAsState()
    LaunchedEffect(openPlace) {
        val d = openPlace ?: return@LaunchedEffect
        AppState.openPlace.value = null
        planTo(d.name, d.address, d.lat, d.lng)
    }
    var nearbyCategory by remember { mutableStateOf<PlaceSearch.Category?>(null) }
    LaunchedEffect(query) {
        if (query.isNotEmpty()) nearbyCategory = null else if (nearbyCategory != null) return@LaunchedEffect
        delay(300)   // erst suchen, wenn kurz nicht getippt wird
        val me = AppState.lastLocation
        results = PlaceSearch.search(query, me?.latitude, me?.longitude)
    }

    Box(Modifier.fillMaxSize()) {
        AndroidView(factory = { mapView }, modifier = Modifier.fillMaxSize())

        // Neuer Ladeplan unterwegs (ChargeMonitor) und Laden (ChargingSession)
        var suggestion by remember { mutableStateOf<ChargeMonitor.Suggestion?>(null) }
        LaunchedEffect(Unit) { ChargeMonitor.suggestions.collect { suggestion = it } }
        suggestion?.let { sg ->
            AlertDialog(
                onDismissRequest = { suggestion = null },
                title = { Text(sg.title) },
                text = { Text(sg.subtitle) },
                confirmButton = {
                    sg.plan?.let { plan -> TextButton(onClick = { suggestion = null; scope.launch { ChargeMonitor.adopt(context, plan) } }) { Text(tr("Übernehmen")) } }
                },
                dismissButton = { TextButton(onClick = { suggestion = null }) { Text(if (sg.plan == null) "OK" else tr("Nein")) } },
            )
        }
        // Konvoi-Pause: Vorschlag beantworten, Rückmeldungen als Hinweis
        val pause by de.koeven.meeterz.social.ConvoyPause.prompt.collectAsState()
        pause?.let { p ->
            AlertDialog(
                onDismissRequest = {},
                title = { Text(de.koeven.meeterz.social.ConvoyPause.title(p)) },
                text = { Text(de.koeven.meeterz.social.ConvoyPause.subtitle(p)) },
                confirmButton = { TextButton(onClick = { de.koeven.meeterz.social.ConvoyPause.answer(p, true) }) { Text(tr("Dabei")) } },
                dismissButton = { TextButton(onClick = { de.koeven.meeterz.social.ConvoyPause.answer(p, false) }) { Text(tr("Nein")) } },
            )
        }
        LaunchedEffect(Unit) {
            de.koeven.meeterz.social.ConvoyPause.notices.collect { Toast.makeText(context, it, Toast.LENGTH_LONG).show() }
        }
        LaunchedEffect(Unit) { AppState.routes.ended.collect { Toast.makeText(context, it, Toast.LENGTH_LONG).show() } }
        // Verkehrsmeldungen voraus (vorgelesen wird in IncidentWatcher)
        LaunchedEffect(Unit) {
            de.koeven.meeterz.nav.IncidentWatcher.alerts.collect { a ->
                Toast.makeText(context, listOfNotNull(a.title, a.subtitle).joinToString(" – "), Toast.LENGTH_LONG).show()
            }
        }
        // Gedrückt halten setzt einen Pin (wie iOS dropPin): Adresse nachladen, unten „Hierhin navigieren“ / „Entfernen“
        val haptics = androidx.compose.ui.platform.LocalHapticFeedback.current
        /** Pin bzw. POI zeigen; `name` = Name des POI (sonst aus der Adresse) */
        fun showPin(lat: Double, lng: Double, name: String?) {
            val pin = DroppedPin(lat, lng, name ?: tr("Gesetzter Pin"), null, isPoi = name != null)
            droppedPin = pin
            query = ""; results = emptyList()
            scope.launch {
                val a = withContext(Dispatchers.IO) {
                    runCatching { android.location.Geocoder(context).getFromLocation(pin.lat, pin.lng, 1)?.firstOrNull() }.getOrNull()
                } ?: return@launch
                if (droppedPin?.lat != pin.lat || droppedPin?.lng != pin.lng) return@launch
                val street = listOfNotNull(a.thoroughfare, a.subThoroughfare).joinToString(" ")
                val city = listOfNotNull(a.postalCode, a.locality).joinToString(" ")
                val title = name ?: a.featureName?.takeIf { it != a.subThoroughfare } ?: street.ifEmpty { pin.name }
                droppedPin = droppedPin?.copy(name = title, address = droppedPin?.address ?: listOf(street, city).filter { it.isNotEmpty() }.joinToString(", ").ifEmpty { null })
            }
            // POI: Kategorie, Öffnungszeiten, Telefon, Website, Bewertung von Mapbox nachladen (wie Apples Ortskarte)
            if (name != null) scope.launch {
                val d = PlaceSearch.details(name, lat, lng) ?: return@launch
                if (droppedPin?.lat != pin.lat || droppedPin?.lng != pin.lng) return@launch
                droppedPin = droppedPin?.copy(details = d, address = d.address ?: droppedPin?.address)
            }
        }
        DisposableEffect(mapView) {
            val listener = com.mapbox.maps.plugin.gestures.OnMapLongClickListener { point ->
                if (NavigationController.guidance.value != null) return@OnMapLongClickListener false
                haptics.performHapticFeedback(androidx.compose.ui.hapticfeedback.HapticFeedbackType.LongPress)
                showPin(point.latitude(), point.longitude(), null)
                true
            }
            mapView.gestures.addOnMapLongClickListener(listener)
            onDispose { mapView.gestures.removeOnMapLongClickListener(listener) }
        }
        // POI der Karte antippen (Geschäft, Tankstelle …): Karte mit Name, Adresse und „Hierhin navigieren“ (wie iOS).
        // Vorher reagierten die POIs auf der Mapbox-Karte gar nicht (18.11.).
        DisposableEffect(mapView, mapStyleRevision) {
            val token = mapView.mapboxMap.addInteraction(
                com.mapbox.maps.ClickInteraction.standardPoi { poi, _ ->
                    if (NavigationController.guidance.value != null) return@standardPoi false
                    de.koeven.meeterz.Diag.log("POI getippt: ${poi.name ?: "ohne Namen"}")
                    showPin(poi.geometry.latitude(), poi.geometry.longitude(), poi.name)
                    true
                }
            )
            onDispose { token.cancel() }
        }
        // Stories an ihrem Ort (wie iOS): Antippen spielt die Stories der Person ab
        val storyManager = remember(mapView, mapStyleRevision) {
            mapView.annotations.createPointAnnotationManager().apply {
                // Nie ausblenden, auch wenn sie andere Symbole überdecken (wie iOS: Pins am eigenen Ort fehlten)
                iconAllowOverlap = true
                iconIgnorePlacement = true
                addClickListener { a -> a.getData()?.asString?.let { de.koeven.meeterz.data.StoriesStore.open(it) }; true }
            }
        }
        LaunchedEffect(stories, mapStyleRevision) {
            storyManager.deleteAll()
            for (s in stories) {
                storyManager.create(PointAnnotationOptions().withPoint(Point.fromLngLat(s.lng, s.lat))
                    .withIconImage(storyBubble(s.seen)).withIconSize(0.6)
                    .withData(com.google.gson.JsonPrimitive(s.userId)))
            }
        }
        // Eigene Story: Ring um meinen Standortpfeil (wie iOS), Antippen spielt sie ab
        val myStory = stories.any { it.userId == AppState.myId }
        val meManager = remember(mapView, mapStyleRevision) {
            mapView.annotations.createPointAnnotationManager().apply {
                addClickListener { AppState.myId?.let { de.koeven.meeterz.data.StoriesStore.open(it) }; true }
            }
        }
        DisposableEffect(myStory, meManager) {
            meManager.deleteAll()
            if (!myStory) return@DisposableEffect onDispose {}
            var ring: com.mapbox.maps.plugin.annotation.generated.PointAnnotation? = null
            val listener = com.mapbox.maps.plugin.locationcomponent.OnIndicatorPositionChangedListener { p ->
                val r = ring
                if (r == null) ring = meManager.create(PointAnnotationOptions().withPoint(p).withIconImage(ownStoryRing()))
                // ponytail: nur bei spürbarer Bewegung (~2 m) neu setzen statt in jedem Bild
                else if (kotlin.math.abs(r.point.latitude() - p.latitude()) + kotlin.math.abs(r.point.longitude() - p.longitude()) > 0.00002) {
                    r.point = p; meManager.update(r)
                }
            }
            mapView.location.addOnIndicatorPositionChangedListener(listener)
            onDispose { mapView.location.removeOnIndicatorPositionChangedListener(listener); meManager.deleteAll() }
        }
        val pinManager = remember(mapView, mapStyleRevision) { mapView.annotations.createPointAnnotationManager() }
        LaunchedEffect(droppedPin, mapStyleRevision) {
            pinManager.deleteAll()
            // Angetippter POI: kein roter Pin auf seinem Symbol (wie iOS, 22.11.)
            droppedPin?.takeIf { !it.isPoi }?.let { p ->
                pinManager.create(PointAnnotationOptions().withPoint(Point.fromLngLat(p.lng, p.lat)).withIconImage(pinBitmap()))
            }
        }

        // Geparktes Auto (wie ParkedCarMarker auf iOS): Antippen → zu Fuß hin oder vergessen
        val parked by de.koeven.meeterz.suggest.Parking.spot.collectAsState()
        var parkedMenu by remember { mutableStateOf(false) }
        val parkedManager = remember(mapView, mapStyleRevision) { mapView.annotations.createPointAnnotationManager() }
        LaunchedEffect(parked, mapStyleRevision) {
            parkedManager.deleteAll()
            parked?.let { p ->
                parkedManager.create(PointAnnotationOptions().withPoint(Point.fromLngLat(p.lng, p.lat))
                    .withIconImage(initialsBubble("P"))
                    .withTextField(tr("Dein Auto · %@", clockAt(java.time.Instant.ofEpochMilli(p.at))))
                    .withTextOffset(listOf(0.0, 2.2)).withTextSize(12.0))
            }
            parkedManager.addClickListener { parkedMenu = true; true }
        }
        if (parkedMenu) parked?.let { p ->
            AlertDialog(
                onDismissRequest = { parkedMenu = false },
                title = { Text(tr("Dein Auto")) },
                text = { Text(tr("Geparkt um %@", clockAt(java.time.Instant.ofEpochMilli(p.at)))) },
                confirmButton = { TextButton(onClick = {
                    parkedMenu = false
                    // Zu Fuß: Meeterz führt nur mit dem Auto – darum die Karten-App mit Fußweg
                    val uri = android.net.Uri.parse("google.navigation:q=${p.lat},${p.lng}&mode=w")
                    runCatching { context.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW, uri)) }.onFailure {
                        context.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse("geo:${p.lat},${p.lng}?q=${p.lat},${p.lng}(Dein Auto)")))
                    }
                }) { Text(tr("Zu Fuß hinführen")) } },
                dismissButton = { TextButton(onClick = { parkedMenu = false; de.koeven.meeterz.suggest.Parking.clear() }) { Text(tr("Parkplatz vergessen")) } },
            )
        }
        val charging by ChargingSession.view.collectAsState()
        charging?.let { ChargingCard(it, Modifier.align(Alignment.BottomCenter).padding(bottom = 24.dp)) }   // unten wie iOS (23.11.)

        val g = guidance
        planCandidate?.let { CandidatePlanDialog(it, onClose = { planCandidate = null }) }
        inviteTo?.let { d -> InviteFriendsDialog(d.name, d.address, d.lat, d.lng, onClose = { inviteTo = null }) }
        if (g != null) {
            GuidanceBanner(g)
            Column(Modifier.align(Alignment.BottomCenter)) {
                SocialCard(hideAccepted = isMeetupGuidance) { planCandidate = it }
                MeetingPointCard()
                GuidanceBar(g, Modifier)
            }
        } else {
            // Aufbau wie iOS (MainView): oben „Wohin?“ und Freunde, darunter links die Status-Pille, rechts
            // Kartenansicht und Standort. Einstellungen und Treffen liegen wie auf iOS im Freunde-Bildschirm.
            var searchFocused by remember { mutableStateOf(false) }
            val focusManager = androidx.compose.ui.platform.LocalFocusManager.current
            // Wie iOS SearchView: Auswahl als Zuhause/Arbeit/Favorit speichern statt zur Route
            var assigning by remember { mutableStateOf<String?>(null) }
            var naming by remember { mutableStateOf<PlaceSearch.Place?>(null) }
            var renaming by remember { mutableStateOf<de.koeven.meeterz.data.Favorite?>(null) }
            fun choose(name: String, address: String?, lat: Double, lng: Double) {
                when (assigning) {
                    "home" -> { AppState.favorites.save("home", tr("Zuhause"), address ?: name, lat, lng); assigning = null; query = ""; results = emptyList() }
                    "work" -> { AppState.favorites.save("work", tr("Arbeit"), address ?: name, lat, lng); assigning = null; query = ""; results = emptyList() }
                    "other" -> naming = PlaceSearch.Place(name, address, lat, lng)
                    else -> { focusManager.clearFocus(); planTo(name, address, lat, lng) }
                }
            }
            naming?.let { place ->
                var label by remember(place) { mutableStateOf(place.name) }
                AlertDialog(onDismissRequest = { naming = null; assigning = null },
                    title = { Text(tr("Favorit speichern")) },
                    text = { Column { Text(place.address ?: place.name, style = MaterialTheme.typography.bodySmall)
                        OutlinedTextField(label, { label = it }, placeholder = { Text(tr("Name, z. B. Oma")) }, singleLine = true) } },
                    confirmButton = { TextButton(enabled = label.isNotBlank(), onClick = {
                        AppState.favorites.save("other", label.trim(), place.address, place.lat, place.lng)
                        naming = null; assigning = null; query = ""; results = emptyList()
                    }) { Text(tr("Speichern")) } },
                    dismissButton = { TextButton(onClick = { naming = null; assigning = null }) { Text(tr("Abbrechen")) } })
            }
            renaming?.let { fav ->
                var label by remember(fav) { mutableStateOf(fav.label) }
                AlertDialog(onDismissRequest = { renaming = null }, title = { Text(tr("Favorit umbenennen")) },
                    text = { OutlinedTextField(label, { label = it }, placeholder = { Text(tr("Name")) }, singleLine = true) },
                    confirmButton = { TextButton(enabled = label.isNotBlank(), onClick = { AppState.favorites.rename(fav.id, label.trim()); renaming = null }) { Text(tr("Speichern")) } },
                    dismissButton = { TextButton(onClick = { renaming = null }) { Text(tr("Abbrechen")) } })
            }
            Column(Modifier.statusBarsPadding().padding(horizontal = 16.dp).padding(top = 8.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                    SearchCapsule(query, { query = it; preview = null }, { query = ""; results = emptyList() },
                        Modifier.weight(1f).onFocusChanged { searchFocused = it.isFocused },
                        placeholder = when (assigning) {
                            "home" -> tr("Adresse für „Zuhause“ suchen"); "work" -> tr("Adresse für „Arbeit“ suchen")
                            "other" -> tr("Ort für neuen Favoriten suchen"); else -> tr("Wohin?")
                        })
                    MapCircleButton(Icons.Default.People, tr("Freunde"),
                        badge = friends.any { !it.isAccepted && it.incoming }, activeDot = friendRoutes.isNotEmpty()) { showUnterwegs = true }
                }
                // „In der Nähe finden“: gewählte Kategorie als Chip, Treffer in der Ergebnisliste darunter (wie iOS)
                nearbyCategory?.let { c ->
                    androidx.compose.material3.InputChip(selected = true, onClick = { nearbyCategory = null; results = emptyList() },
                        label = { Text(c.title) }, trailingIcon = { Icon(Icons.Default.Close, null, Modifier.size(16.dp)) },
                        modifier = Modifier.padding(top = 8.dp))
                }
                if (query.isEmpty() && preview == null && searchFocused && assigning == null && nearbyCategory == null) {
                    SearchStart(favorites, visibleFriends, live,
                        onChoose = { n, a, la, ln -> choose(n, a, la, ln) },
                        onAssign = { assigning = it },
                        onRename = { renaming = it },
                        onCategory = { c ->
                            nearbyCategory = c
                            val me = AppState.lastLocation ?: return@SearchStart
                            scope.launch { results = PlaceSearch.stopovers(c, me.latitude, me.longitude).map { it.place } }
                        })
                }
                if (query.isEmpty() && preview == null && !searchFocused) {
                    Row(Modifier.padding(top = 10.dp), verticalAlignment = Alignment.Top) {
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            StatusPill()
                            car?.takeIf { it.soc != null && it.ageSeconds < 7 * 86400 }?.let { c ->
                                Surface(shape = RoundedCornerShape(50), color = MaterialTheme.colorScheme.surface.copy(alpha = 0.92f)) {
                                    Text("${c.soc!!.toInt()} %" + (c.rangeKm?.let { " · ${it.toInt()} km" } ?: "") + if (c.charging == true) " · " + tr("lädt") else "",
                                        Modifier.padding(horizontal = 12.dp, vertical = 8.dp), fontWeight = FontWeight.SemiBold,
                                        style = MaterialTheme.typography.bodySmall)
                                }
                            }
                        }
                        Spacer(Modifier.weight(1f))
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            MapStyleMenu(mapStyle, map3d)
                            MapCircleButton(Icons.Default.PhotoCamera, tr("Story aufnehmen")) { showStoryComposer = true }
                            MapCircleButton(if (!followingMe) Icons.Outlined.NearMeOutlined else if (turnsWithMe) Icons.Default.Navigation else Icons.Default.NearMe,
                                tr("Auf meinen Standort zentrieren"), tint = MaterialTheme.colorScheme.primary) {
                                if (followingMe) UiPreferences.setNorthUp(!northUpPref)   // LaunchedEffect richtet neu aus
                                else mapView.viewport.transitionTo(followMe(mapView.viewport, map3d, turnsWithMe))
                            }
                        }
                    }
                }
                if (results.isNotEmpty() && preview == null) {
                    Surface(shape = RoundedCornerShape(16.dp), shadowElevation = 2.dp, border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant), modifier = Modifier.padding(top = 8.dp)) {
                        LazyColumn(Modifier.heightIn(max = 360.dp)) {
                            items(results) { place ->
                                Column(Modifier.fillMaxWidth().combinedClickable(
                                    onClick = { choose(place.name, place.address, place.lat, place.lng) },
                                    onLongClick = { naming = place })   // iOS: Kontextmenü „Als Favorit speichern“
                                    .padding(horizontal = 16.dp, vertical = 12.dp)) {
                                    Text(place.name, fontWeight = FontWeight.SemiBold)
                                    place.address?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                                }
                                HorizontalDivider()
                            }
                        }
                    }
                }
            }
            if (planning) CircularProgressIndicator(Modifier.align(Alignment.Center))
            if (preview == null && query.isEmpty()) Column(Modifier.align(Alignment.BottomCenter).navigationBarsPadding()) {
                droppedPin?.let { pin ->
                    PinCard(pin, onNavigate = { droppedPin = null; planTo(pin.name, pin.address, pin.lat, pin.lng) },
                        onRemove = { droppedPin = null })
                }
                SocialCard { planCandidate = it }
                MeetingPointCard()
            }
            if (showMeetups) MeetupsOverviewScreen(onClose = { showMeetups = false })
            if (showUnterwegs) UnterwegsSheet(visibleFriends, onDismiss = { showUnterwegs = false },
                onFocus = { f ->
                    showUnterwegs = false
                    val p = live[f.friendId]
                    val lat = p?.lat ?: f.lat; val lng = p?.lng ?: f.lng
                    if (lat != null && lng != null) {
                        mapView.viewport.idle()
                        mapView.camera.flyTo(CameraOptions.Builder().center(Point.fromLngLat(lng, lat)).zoom(15.0).build())
                    }
                },
                onMeetups = { showUnterwegs = false; showMeetups = true },
                onTrips = { showUnterwegs = false; showTrips = true },
                onGroupMeetup = { showUnterwegs = false; showGroupMeetup = true },
                onManage = { showUnterwegs = false; showFriends = true })
            if (showGroupMeetup) GroupMeetupScreen(onClose = { showGroupMeetup = false })
            if (showTrips) TripsSheet(onDismiss = { showTrips = false })
            if (showStoryComposer) StoryComposer(onDismiss = { showStoryComposer = false })
            val viewing by de.koeven.meeterz.data.StoriesStore.viewing.collectAsState()
            viewing?.let { list ->
                StoryViewer(list, onDismiss = { de.koeven.meeterz.data.StoriesStore.viewing.value = null },
                    onNavigate = { name, lat, lng -> showTrips = false; planTo(name, null, lat, lng) })
            }
            selectedFriend?.let { id ->
                FriendActionSheet(id, onDismiss = { selectedFriend = null },
                    onShow = { lat, lng, route ->
                        selectedFriend = null
                        mapView.viewport.idle()
                        val points = route?.coordinates?.map { Point.fromLngLat(it.first, it.second) }.orEmpty() + Point.fromLngLat(lng, lat)
                        if (points.size > 1) {
                            val d = context.resources.displayMetrics.density.toDouble()
                            mapView.camera.flyTo(mapView.mapboxMap.cameraForCoordinates(points,
                                com.mapbox.maps.EdgeInsets(160 * d, 40 * d, 200 * d, 40 * d), null, null))
                        } else mapView.camera.flyTo(CameraOptions.Builder().center(points.first()).zoom(15.0).build())
                    },
                    onNavigate = { name, lat, lng -> selectedFriend = null; planTo(name, null, lat, lng) })
            }
            // Wie iOS: Einstellungen liegen über „Freunde & Profil“ – Zurück führt dorthin
            if (showFriends) FriendsScreen(onClose = { showFriends = false }, onSettings = { showSettings = true })
            if (showSettings) SettingsScreen(onClose = { showSettings = false })
            preview?.let { (dest, routes) ->
                PreviewCard(dest, routes, selectedRoute, { selectedRoute = it }, Modifier.align(Alignment.BottomCenter),
                    mode = travelMode, switching = planning,
                    onMode = { m -> if (m != travelMode && !planning) planTo(dest.name, dest.address, dest.lat, dest.lng, m) },
                    onSave = { kind, label -> AppState.favorites.save(kind, label, dest.address, dest.lat, dest.lng) },
                    onStart = { NavigationController.start(routes, dest, selectedRoute); preview = null; query = "" },
                    onCancel = { preview = null; adopted = null },
                    onInvite = { inviteTo = dest },
                    chargeSeconds = if (travelMode == de.koeven.meeterz.nav.TravelMode.CAR && de.koeven.meeterz.ev.EvSettings.enabled) previewChargeSeconds else 0.0,
                    charge = { if (travelMode == de.koeven.meeterz.nav.TravelMode.CAR)
                        ChargePlanSection(routes.getOrElse(selectedRoute) { routes.first() }, adopted,
                            onPlan = { p -> previewChargeSeconds = p?.takeIf { !it.direct }?.totalChargeTime ?: 0.0 }) { plan -> adopt(dest, plan) } })
            }
        }
    }
}

@Composable
private fun PreviewCard(dest: NavigationController.Destination, routes: List<NavigationRoute>, selected: Int, onSelect: (Int) -> Unit, modifier: Modifier,
                        mode: de.koeven.meeterz.nav.TravelMode, switching: Boolean, onMode: (de.koeven.meeterz.nav.TravelMode) -> Unit,
                        chargeSeconds: Double = 0.0,
                        onSave: (String, String) -> Unit, onStart: () -> Unit, onCancel: () -> Unit, onInvite: () -> Unit,
                        charge: @Composable () -> Unit = {}) {
    var saved by remember(dest) { mutableStateOf(false) }
    var arriveBy by remember { mutableStateOf(false) }
    var saveToList by remember { mutableStateOf(false) }
    if (arriveBy) ArriveByDialog(dest.name, dest.address, dest.lat, dest.lng, onDismiss = { arriveBy = false })
    if (saveToList) SaveToListDialog(dest.name, dest.address, dest.lat, dest.lng, onDismiss = { saveToList = false })
    val r = routes.getOrElse(selected) { routes.first() }.directionsRoute
    Surface(modifier.fillMaxWidth().navigationBarsPadding().padding(12.dp), shape = RoundedCornerShape(20.dp), shadowElevation = 2.dp, border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            // Auto / Fahrrad / Zu Fuß (wie iOS; in Android Auto immer Auto)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (m in de.koeven.meeterz.nav.TravelMode.entries) {
                    val on = m == mode
                    Surface(onClick = { onMode(m) }, enabled = !switching, shape = RoundedCornerShape(50),
                        color = if (on) MaterialTheme.colorScheme.onSurface else Color.Transparent,
                        contentColor = if (on) MaterialTheme.colorScheme.surface else MaterialTheme.colorScheme.onSurface,
                        border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
                        modifier = Modifier.weight(1f).height(38.dp)) {
                        Row(horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                            Icon(when (m) {
                                de.koeven.meeterz.nav.TravelMode.CAR -> Icons.Default.DirectionsCar
                                de.koeven.meeterz.nav.TravelMode.BIKE -> Icons.AutoMirrored.Filled.DirectionsBike
                                de.koeven.meeterz.nav.TravelMode.WALK -> Icons.AutoMirrored.Filled.DirectionsWalk
                            }, tr("Fortbewegungsart %@", m.title), Modifier.size(16.dp))
                            Spacer(Modifier.width(6.dp))
                            Text(m.title, style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold)
                        }
                    }
                }
            }
            Text(dest.name, style = MaterialTheme.typography.titleMedium)
            // Öffnungszeiten und Anrufen direkt in der Routenvorschau (wie iOS RoutePreviewView)
            val info by produceState<de.koeven.meeterz.nav.PlaceSearch.Details?>(null, dest) {
                value = de.koeven.meeterz.nav.PlaceSearch.detailsForDestination(dest.name, dest.lat, dest.lng)
            }
            info?.let { d ->
                val context = androidx.compose.ui.platform.LocalContext.current
                val status = d.hours?.let { de.koeven.meeterz.nav.OsmPlaces.status(it) } ?: d.hoursText
                val arrival = java.util.Calendar.getInstance().apply { add(java.util.Calendar.SECOND, (r.duration() + chargeSeconds).toInt()) }
                val closedOnArrival = d.openNow(arrival) == false
                if (status != null || d.phone != null) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    status?.let {
                        Icon(Icons.Default.Schedule, null, Modifier.size(16.dp),
                            tint = if (d.openNow() == false) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary)
                        Text(it, style = MaterialTheme.typography.bodySmall, maxLines = 1, modifier = Modifier.weight(1f, fill = false))
                    }
                    d.phone?.let { phone ->
                        AssistChip(onClick = {
                            context.startActivity(android.content.Intent(android.content.Intent.ACTION_DIAL, android.net.Uri.parse("tel:" + phone.filter { c -> c.isDigit() || c == '+' })))
                        }, label = { Text(tr("Anrufen")) }, leadingIcon = { Icon(Icons.Default.Phone, null, Modifier.size(16.dp)) })
                    }
                }
                if (closedOnArrival) Text(tr("Bei Ankunft um %@ geschlossen", clock(r.duration() + chargeSeconds)),
                    style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.error)
            }
            Text(if (chargeSeconds > 0) tr("%@ · %@ · Ankunft inkl. Laden %@", minutes(r.duration() + chargeSeconds), km(r.distance()), clock(r.duration() + chargeSeconds))
                 else tr("%@ · %@ · Ankunft %@", minutes(r.duration()), km(r.distance()), clock(r.duration())))
            // Bis zu drei Routen zur Wahl (Schnellste, Kürzeste, Ohne Autobahn) – wie die Routenwahl auf iOS
            if (routes.size > 1) Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                routes.forEachIndexed { i, route ->
                    FilterChip(selected = i == selected, onClick = { onSelect(i) }, label = {
                        Text("${de.koeven.meeterz.nav.RouteVariety.label(i, routes)} · ${minutes(route.directionsRoute.duration())}")
                    })
                }
            }
            de.koeven.meeterz.nav.RoutePreferences.summary?.let { Text(tr("Route %@", it), style = MaterialTheme.typography.bodySmall) }
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                AssistChip(onClick = onInvite, label = { Text(tr("Freunde einladen")) })
                if (mode == de.koeven.meeterz.nav.TravelMode.CAR) AssistChip(onClick = { arriveBy = true }, label = { Text(tr("Ankunft / Abfahrt")) })
                AssistChip(onClick = { saveToList = true }, label = { Text(tr("In Liste")) })
                if (!saved) {
                    AssistChip(onClick = { onSave("home", tr("Zuhause")); saved = true }, label = { Text(tr("Als Zuhause")) })
                    AssistChip(onClick = { onSave("work", tr("Arbeit")); saved = true }, label = { Text(tr("Als Arbeit")) })
                    AssistChip(onClick = { onSave("other", dest.name); saved = true }, label = { Text(tr("Merken")) })
                }
            }
            charge()
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedButton(onClick = onCancel) { Text(tr("Abbrechen")) }
                Button(onClick = onStart, modifier = Modifier.weight(1f)) { Text(tr("Los")) }
            }
        }
    }
}

@Composable
private fun GuidanceBanner(g: NavigationController.Guidance) {
    val sign by de.koeven.meeterz.nav.RightOfWaySigns.sign.collectAsState()
    Column(Modifier.statusBarsPadding().padding(12.dp)) {
        Surface(Modifier.fillMaxWidth(), shape = RoundedCornerShape(20.dp),
            color = MeeterzColors.petrol, contentColor = Color.White, shadowElevation = 2.dp, border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)) {
            Column(Modifier.padding(16.dp)) {
                Text(km(g.distanceToTurn), style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.SemiBold, color = MeeterzColors.mint)
                Text(g.instruction.ifEmpty { g.destination.name }, style = MaterialTheme.typography.titleMedium)
            }
        }
        // Vorfahrt achten / Stopp kurz vor dem Schild (wie RightOfWaySigns auf iOS), am Rand unter der Anzeige
        sign?.let { s ->
            androidx.compose.foundation.Image(de.koeven.meeterz.ui.RoadSigns.bitmap(s.stop).asImageBitmap(),
                if (s.stop) tr("Stopp") else tr("Vorfahrt achten"), Modifier.padding(top = 8.dp).size(56.dp))
        }
    }
}

@Composable
private fun GuidanceBar(g: NavigationController.Guidance, modifier: Modifier) {
    var voice by remember { mutableStateOf(NavigationController.voiceMode) }
    val context = LocalContext.current
    var showMessage by remember { mutableStateOf(false) }
    var showStop by remember { mutableStateOf(false) }
    if (showMessage) MessageDialog(g, onDismiss = { showMessage = false })
    if (showStop) AddStopDialog(onDismiss = { showStop = false })
    var showHazard by remember { mutableStateOf(false) }
    if (showHazard) HazardDialog(onDismiss = { showHazard = false })
    val northUp by UiPreferences.northUp.collectAsState()
    // Stopp entlang der Route und Gefahr melden: runde Knöpfe rechts über der Leiste (wie die Knöpfe am Rand auf iOS).
    // In der Leiste selbst war dafür kein Platz – auf 360-dp-Geräten blieb für die Ankunftszeit fast nichts.
    Column(modifier.fillMaxWidth().padding(end = 12.dp), horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        for ((icon, label, action) in listOf(
            Triple(Icons.Default.Search, tr("Stopp entlang der Route")) { showStop = true },
            Triple(Icons.Default.Warning, tr("Gefahr melden")) { showHazard = true },
            // Ausrichtung direkt umschalten wie in Apple Karten / iOS: Fahrtrichtung oben ↔ Norden oben
            Triple(if (northUp) Icons.Default.NearMe else Icons.Default.Navigation,
                tr(if (northUp) "Norden oben" else "Fahrtrichtung oben")) { UiPreferences.setNorthUp(!northUp) },
        )) {
            Surface(onClick = action, shape = androidx.compose.foundation.shape.CircleShape, color = MaterialTheme.colorScheme.surface,
                shadowElevation = 2.dp, border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
                modifier = Modifier.size(48.dp)) {
                Box(contentAlignment = Alignment.Center) { Icon(icon, label) }
            }
        }
    }
    Surface(modifier.fillMaxWidth().navigationBarsPadding().padding(12.dp), shape = RoundedCornerShape(20.dp), shadowElevation = 2.dp, border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)) {
        Row(Modifier.padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(tr("Ankunft %@", clock(g.remainingSeconds)), fontWeight = FontWeight.SemiBold)
                Text("${minutes(g.remainingSeconds)} · ${km(g.remainingDistance)}", style = MaterialTheme.typography.bodySmall)
                val forecast by ChargeMonitor.forecast.collectAsState()
                forecast?.let { Text(it.text, style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.SemiBold,
                    color = if (it.low) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary) }
            }
            IconButton(onClick = { showMessage = true }) { Icon(Icons.AutoMirrored.Filled.Chat, tr("Bescheid geben")) }
            // Wie iOS/CarPlay: Alle Ansagen → Nur Warnungen → Aus, kurz anzeigen, was jetzt gilt
            IconButton(onClick = {
                voice = when (voice) { de.koeven.meeterz.nav.Speaker.Mode.ALL -> de.koeven.meeterz.nav.Speaker.Mode.ALERTS_ONLY
                    de.koeven.meeterz.nav.Speaker.Mode.ALERTS_ONLY -> de.koeven.meeterz.nav.Speaker.Mode.OFF
                    de.koeven.meeterz.nav.Speaker.Mode.OFF -> de.koeven.meeterz.nav.Speaker.Mode.ALL }
                NavigationController.voiceMode = voice
                Toast.makeText(context, with(NavigationController) { voice.title }, Toast.LENGTH_SHORT).show()
            }) {
                Icon(when (voice) {
                    de.koeven.meeterz.nav.Speaker.Mode.ALL -> Icons.AutoMirrored.Filled.VolumeUp
                    de.koeven.meeterz.nav.Speaker.Mode.ALERTS_ONLY -> Icons.Default.Campaign
                    de.koeven.meeterz.nav.Speaker.Mode.OFF -> Icons.AutoMirrored.Filled.VolumeOff
                }, with(NavigationController) { voice.title })
            }
            Spacer(Modifier.padding(4.dp))
            Button(onClick = { NavigationController.stop() }) { Text(tr("Beenden")) }
        }
    }
}

/** Laden verfolgen (iOS: Ladekarte/CarPlay-Ring): Fortschritt, Leistung, Restzeit, Ziel wählbar */
@Composable
private fun ChargingCard(v: ChargingSession.View, modifier: Modifier) {
    Surface(modifier.padding(24.dp), shape = RoundedCornerShape(20.dp), shadowElevation = 2.dp, border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(if (v.done) tr("Genug geladen") else tr("Lädt"), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Text("${Math.round(v.percent)} % → ${Math.round(v.target)} %", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.SemiBold)
            LinearProgressIndicator(progress = { v.progress.toFloat() }, modifier = Modifier.fillMaxWidth())
            Text(listOfNotNull(
                v.powerKW.takeIf { it > 0 }?.let { "${it.toInt()} kW" },
                v.remainingSeconds?.takeIf { !v.done }?.let { tr("noch %@ Min.", maxOf(1, Math.round(it / 60))) },
            ).joinToString(" · "), style = MaterialTheme.typography.bodySmall)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (t in listOf(80.0, 90.0, 100.0)) AssistChip(onClick = { ChargingSession.setTarget(t) }, label = { Text(tr("Bis %@ %", t.toInt())) })
            }
        }
    }
}

/**
 * Unterwegs kurz Bescheid geben (iOS: Treffpunkt-Karte / CarPlay „Kurz Bescheid geben“): an Freunde, die am Ziel
 * sind oder auch hinfahren – sonst zuerst den Freund wählen.
 */
@Composable
private fun MessageDialog(g: NavigationController.Guidance, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val partners = remember { MessagesStore.recipientsAtDestination() }
    var to by remember { mutableStateOf(partners) }
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text(tr("Abbrechen")) } },
        title = { Text(if (to.isEmpty()) tr("Bescheid geben") else tr("An %@", to.joinToString(", ") { it.firstName })) },
        text = {
            LazyColumn(Modifier.heightIn(max = 420.dp)) {
                if (to.isEmpty()) {
                    items(MessagesStore.friendsByDistance()) { f ->
                        Text(f.displayName, Modifier.fillMaxWidth().clickable { to = listOf(f) }.padding(vertical = 12.dp))
                    }
                } else {
                    val eta = System.currentTimeMillis() + (g.remainingSeconds * 1000).toLong()
                    items(MessagesStore.quickReplies(eta)) { text ->
                        Text(text, Modifier.fillMaxWidth().clickable {
                            onDismiss()
                            scope.launch {
                                val sent = AppState.messages.send(text, to.map { it.friendId })
                                Toast.makeText(context, if (sent > 0) tr("Gesendet: „%@“", text) else tr("Nachricht nicht gesendet"), Toast.LENGTH_SHORT).show()
                            }
                        }.padding(vertical = 12.dp))
                    }
                }
            }
        },
    )
}

private fun minutes(seconds: Double): String {
    val m = maxOf(1, Math.round(seconds / 60).toInt())
    return if (m < 60) tr("%lld Min", m) else tr("%lld Std %lld Min", m / 60, m % 60)
}

/** Wie ActivityFormat.distance auf iOS: unter 100 m auf 10 m, unter 1 km auf 50 m, bis 10 km auf 0,1 km, darüber ganze km */
fun km(meters: Double): String {
    if (meters < 1000) {
        val rounded = if (meters < 100) Math.round(meters / 10) * 10 else Math.round(meters / 50) * 50
        return "${maxOf(rounded, 0)} m"
    }
    if (meters >= 10_000) return "${Math.round(meters / 1000)} km"
    return String.format(java.util.Locale.getDefault(), "%.1f km", meters / 1000)
}

internal fun clockAt(at: java.time.Instant): String = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(at.toEpochMilli()))

private fun clock(secondsFromNow: Double): String =
    DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(System.currentTimeMillis() + (secondsFromNow * 1000).toLong()))

/** Suchfeld als Kapsel wie iOS („Wohin?“, 52 dp) */
@Composable
private fun SearchCapsule(query: String, onChange: (String) -> Unit, onClear: () -> Unit, modifier: Modifier, placeholder: String) {
    Surface(modifier.height(52.dp), shape = RoundedCornerShape(50), color = MaterialTheme.colorScheme.surface,
        border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)) {
        Row(Modifier.padding(start = 16.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Default.Search, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.width(10.dp))
            Box(Modifier.weight(1f)) {
                if (query.isEmpty()) Text(placeholder, color = MaterialTheme.colorScheme.onSurfaceVariant, fontWeight = FontWeight.Medium)
                androidx.compose.foundation.text.BasicTextField(query, onChange, singleLine = true,
                    textStyle = MaterialTheme.typography.bodyLarge.copy(color = MaterialTheme.colorScheme.onSurface),
                    cursorBrush = androidx.compose.ui.graphics.SolidColor(MaterialTheme.colorScheme.primary),
                    modifier = Modifier.fillMaxWidth())
            }
            if (query.isNotEmpty()) IconButton(onClick = onClear) { Icon(Icons.Default.Close, tr("Leeren")) }
        }
    }
}

/** Runder Kartenknopf wie iOS CircleIconButton: 48 dp, Fläche mit Rand; roter Punkt = Anfrage, Bernstein = unterwegs */
@Composable
internal fun MapCircleButton(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String,
                             tint: Color = MaterialTheme.colorScheme.onSurface, badge: Boolean = false, activeDot: Boolean = false,
                             onClick: () -> Unit) {
    Box {
        Surface(onClick = onClick, shape = CircleShape, color = MaterialTheme.colorScheme.surface,
            border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant), modifier = Modifier.size(48.dp)) {
            Box(contentAlignment = Alignment.Center) { Icon(icon, label, tint = tint, modifier = Modifier.size(22.dp)) }
        }
        val ring = MaterialTheme.colorScheme.surface
        if (activeDot) Box(Modifier.align(if (badge) Alignment.BottomEnd else Alignment.TopEnd).padding(1.dp).size(11.dp)
            .background(MaterialTheme.colorScheme.tertiary, CircleShape).border(2.dp, ring, CircleShape))
        if (badge) Box(Modifier.align(Alignment.TopEnd).padding(1.dp).size(11.dp)
            .background(MaterialTheme.colorScheme.error, CircleShape).border(2.dp, ring, CircleShape))
    }
}

/** Kartenansicht wie iOS: ein Knopf, Menü mit Kartenstil und 2D/3D */
@Composable
private fun MapStyleMenu(mapStyle: String, map3d: Boolean) {
    var open by remember { mutableStateOf(false) }
    Box {
        MapCircleButton(Icons.Default.Layers, tr("Kartenansicht")) { open = true }
        androidx.compose.material3.DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            Text(tr("Karte"), Modifier.padding(horizontal = 16.dp, vertical = 6.dp), style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            for ((key, label) in listOf("satellite" to tr("Satellit"), "standard" to tr("Klassische Karte"))) {
                androidx.compose.material3.DropdownMenuItem(text = { Text(label) },
                    trailingIcon = { if (mapStyle == key) Icon(Icons.Default.Check, null) },
                    onClick = { open = false; UiPreferences.setMapStyle(key) })
            }
            HorizontalDivider()
            Text(tr("Ansicht"), Modifier.padding(horizontal = 16.dp, vertical = 6.dp), style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            for ((on, label) in listOf(true to tr("3D"), false to tr("2D"))) {
                androidx.compose.material3.DropdownMenuItem(text = { Text(label) },
                    trailingIcon = { if (map3d == on) Icon(Icons.Default.Check, null) },
                    onClick = { open = false; UiPreferences.setMap3d(on) })
            }
            // Wie Apple Karten / iOS: während der Fahrt Fahrtrichtung oben oder Norden oben
            HorizontalDivider()
            Text(tr("Ausrichtung"), Modifier.padding(horizontal = 16.dp, vertical = 6.dp), style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            val northUp by UiPreferences.northUp.collectAsState()
            for ((on, label) in listOf(false to tr("Fahrtrichtung oben"), true to tr("Norden oben"))) {
                androidx.compose.material3.DropdownMenuItem(text = { Text(label) },
                    trailingIcon = { if (northUp == on) Icon(Icons.Default.Check, null) },
                    onClick = { open = false; UiPreferences.setNorthUp(on) })
            }
        }
    }
}

/** Status-Pille (wie iOS): teile ich gerade, bis wann, inkognito? Antippen öffnet Dauer, Pausieren, Inkognito. */
@Composable
private fun StatusPill() {
    val auth by AppState.auth.state.collectAsState()
    val p = (auth as? de.koeven.meeterz.auth.AuthRepository.State.Ready)?.profile ?: return
    val scope = rememberCoroutineScope()
    var open by remember { mutableStateOf(false) }
    // alle 20 s neu auswerten, damit das Ende von Inkognito/Teilen von selbst sichtbar wird
    var tick by remember { mutableStateOf(0) }
    LaunchedEffect(Unit) { while (true) { kotlinx.coroutines.delay(20_000); tick++ } }
    val active = p.isIncognito || p.isSharingNow
    Box {
        val tint = if (active) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
        Surface(shape = RoundedCornerShape(50), color = MaterialTheme.colorScheme.surface.copy(alpha = 0.92f), modifier = Modifier.clickable { open = true }) {
            Row(Modifier.padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                if (p.isIncognito) Icon(Icons.Default.VisibilityOff, null, tint = tint, modifier = Modifier.size(13.dp))
                else Box(Modifier.size(8.dp).background(tint, CircleShape))
                Spacer(Modifier.width(8.dp))
                Text(sharingLabel(p).also { tick }, fontWeight = FontWeight.SemiBold, color = tint, style = MaterialTheme.typography.bodySmall)
            }
        }
        androidx.compose.material3.DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            if (p.isIncognito) {
                androidx.compose.material3.DropdownMenuItem(text = { Text(tr("Inkognito beenden")) }, onClick = { open = false; scope.launch { AppState.stopIncognito() } })
            } else {
                for ((label, seconds) in listOf(tr("Inkognito 15 Min.") to 15 * 60L, tr("Inkognito 1 Std.") to 3600L, tr("Inkognito 3 Std.") to 3 * 3600L, tr("Inkognito bis ich es ausschalte") to null)) {
                    androidx.compose.material3.DropdownMenuItem(text = { Text(label) }, onClick = { open = false; scope.launch { AppState.startIncognito(seconds) } })
                }
            }
            HorizontalDivider()
            for (mode in AppState.SharingMode.entries) {
                androidx.compose.material3.DropdownMenuItem(
                    text = { Text(tr("Teilen: %@", mode.title)) },
                    trailingIcon = { if (p.isSharingNow && AppState.sharingMode == mode) Icon(Icons.Default.Check, null) },
                    onClick = { open = false; scope.launch { AppState.shareLocation(mode) } })
            }
            if (p.isSharingNow) androidx.compose.material3.DropdownMenuItem(text = { Text(tr("Teilen pausieren")) },
                onClick = { open = false; scope.launch { AppState.setSharing(false) } })
        }
    }
}

/** Runder Mint-Kreis mit Initialen (Freundes-Pin ohne Profilbild) */
/** Leerer Mint-Ring um den eigenen Standortpfeil, solange ich eine Story habe */
internal fun ownStoryRing(): Bitmap {
    val size = 120
    val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
    Canvas(bitmap).drawCircle(size / 2f, size / 2f, size / 2f - 6, Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = MeeterzColors.mint.toArgb(); style = Paint.Style.STROKE; strokeWidth = 8f
    })
    return bitmap
}

/** Kamera-Pin einer Story: Akzentfarbe, grau wenn gesehen */
internal fun storyBubble(seen: Boolean): Bitmap {
    val size = 96
    val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    canvas.drawCircle(size / 2f, size / 2f, size / 2f - 4, Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = if (seen) android.graphics.Color.GRAY else MeeterzColors.mint.toArgb()
    })
    val body = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = MeeterzColors.petrol.toArgb() }
    canvas.drawRoundRect(24f, 34f, 72f, 68f, 6f, 6f, body)
    canvas.drawRect(38f, 28f, 56f, 36f, body)
    canvas.drawCircle(48f, 51f, 10f, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = if (seen) android.graphics.Color.GRAY else MeeterzColors.mint.toArgb() })
    return bitmap
}

internal fun initialsBubble(initials: String, fillColor: Color = MeeterzColors.mint): Bitmap {
    val size = 96
    val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = fillColor.toArgb() }
    val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = android.graphics.Color.WHITE; style = Paint.Style.STROKE; strokeWidth = 6f }
    canvas.drawCircle(size / 2f, size / 2f, size / 2f - 4, fill)
    canvas.drawCircle(size / 2f, size / 2f, size / 2f - 4, ring)
    val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = MeeterzColors.petrol.toArgb()
        textSize = 36f
        textAlign = Paint.Align.CENTER
        isFakeBoldText = true
    }
    canvas.drawText(initials, size / 2f, size / 2f - (text.descent() + text.ascent()) / 2, text)
    return bitmap
}

/** Zwischenstopp während der Führung (iOS: „Stopp hinzufügen“): Kategorie oder Suche, Antippen fügt den Stopp ein */
@Composable
private fun AddStopDialog(onDismiss: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var category by remember { mutableStateOf<PlaceSearch.Category?>(PlaceSearch.Category.GAS) }
    var query by remember { mutableStateOf("") }
    var places by remember { mutableStateOf<List<PlaceSearch.Stopover>?>(null) }
    LaunchedEffect(category, query) {
        val me = AppState.lastLocation ?: return@LaunchedEffect
        places = null
        // Kategorien entlang der Route (Strecke bis dorthin, bei Tankstellen Spritpreise), Freitext in der Nähe
        places = if (query.isNotBlank()) { delay(300); PlaceSearch.search(query, me.latitude, me.longitude).map { PlaceSearch.Stopover(it, null) } }
        else category?.let { PlaceSearch.stopovers(it, me.latitude, me.longitude) }.orEmpty()
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text(tr("Abbrechen")) } },
        title = { Text(tr("Entlang der Route")) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                TextField(query, { query = it }, placeholder = { Text(tr("Suchen")) }, singleLine = true, modifier = Modifier.fillMaxWidth())
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    for (c in PlaceSearch.Category.stopovers) {
                        FilterChip(selected = query.isBlank() && category == c, onClick = { category = c; query = "" }, label = { Text(c.title) })
                    }
                }
                val me = AppState.lastLocation
                if (places == null) CircularProgressIndicator(Modifier.align(Alignment.CenterHorizontally))
                else if (places!!.isEmpty()) Text(tr("Nichts gefunden"), color = MaterialTheme.colorScheme.onSurfaceVariant)
                LazyColumn(Modifier.heightIn(max = 360.dp)) {
                    items(places.orEmpty()) { s ->
                        val p = s.place
                        Column(Modifier.fillMaxWidth().clickable {
                            onDismiss()
                            scope.launch {
                                val ok = NavigationController.addStop(context, p.name, p.lat, p.lng)
                                Toast.makeText(context, if (ok) tr("Stopp: %@", p.name) else tr("Stopp konnte nicht eingefügt werden"), Toast.LENGTH_SHORT).show()
                            }
                        }.padding(vertical = 10.dp)) {
                            Text(p.name, fontWeight = FontWeight.SemiBold)
                            val away = s.aheadText ?: me?.let { km(de.koeven.meeterz.ev.ChargePlanner.distance(it.latitude, it.longitude, p.lat, p.lng)) }
                            Text(listOfNotNull(away, p.address).joinToString(" · "), style = MaterialTheme.typography.bodySmall, maxLines = 1)
                            s.price?.text?.takeIf { it.isNotEmpty() }?.let {
                                Text(it, style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.primary)
                            }
                        }
                    }
                    if (places.orEmpty().any { it.price != null }) item {
                        Text(de.koeven.meeterz.data.FuelPrices.ATTRIBUTION, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        },
    )
}


/**
 * „Ankunft um …“ / „Abfahrt ab …“ (wie iOS ArriveBySheet): Uhrzeit wählen, Abfahrt bzw. Ankunft mit der für diese
 * Uhrzeit üblichen Verkehrslage anzeigen, 10 Min. vor der Abfahrt erinnern
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ArriveByDialog(name: String, address: String?, lat: Double, lng: Double, onDismiss: () -> Unit) {
    val context = LocalContext.current
    var leave by remember { mutableStateOf(false) }
    val inOneHour = java.util.Calendar.getInstance().apply { add(java.util.Calendar.HOUR_OF_DAY, 1) }
    val state = rememberTimePickerState(inOneHour.get(java.util.Calendar.HOUR_OF_DAY), 0, android.text.format.DateFormat.is24HourFormat(context))
    // Gewählte Uhrzeit heute – liegt sie (fast) vorbei, morgen
    val at = remember(state.hour, state.minute, leave) {
        java.util.Calendar.getInstance().apply {
            set(java.util.Calendar.HOUR_OF_DAY, state.hour); set(java.util.Calendar.MINUTE, state.minute); set(java.util.Calendar.SECOND, 0)
            if (timeInMillis < System.currentTimeMillis() + (if (leave) 5 else 15) * 60_000) add(java.util.Calendar.DAY_OF_MONTH, 1)
        }.timeInMillis
    }
    /** Berechnete Abfahrt bzw. (bei `leave`) Ankunft */
    var result by remember { mutableStateOf<Long?>(null) }
    var calculating by remember { mutableStateOf(true) }
    LaunchedEffect(at, leave) {
        calculating = true
        delay(400)
        result = if (leave) de.koeven.meeterz.suggest.DepartureReminder.arrival(lat, lng, at)
                 else de.koeven.meeterz.suggest.DepartureReminder.departure(lat, lng, at)
        calculating = false
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(name, maxLines = 1) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(selected = !leave, onClick = { leave = false }, label = { Text(tr("Ankunft um …")) })
                    FilterChip(selected = leave, onClick = { leave = true }, label = { Text(tr("Abfahrt ab …")) })
                }
                TimeInput(state)
                when {
                    calculating -> CircularProgressIndicator()
                    result != null -> Text(tr(if (leave) "Ankunft: %@" else "Losfahren: %@", de.koeven.meeterz.ui.meetupTime(result!! / 1000)),
                        fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.primary)
                    else -> Text(tr("Fahrzeit konnte nicht berechnet werden."), style = MaterialTheme.typography.bodySmall)
                }
                Text(tr("Mit dem zu dieser Uhrzeit üblichen Verkehr. Du bekommst 10 Minuten vor der Abfahrt eine Erinnerung."),
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        },
        confirmButton = {
            Button(enabled = result != null, onClick = {
                onDismiss()
                AppState.scope.launch {
                    de.koeven.meeterz.suggest.DepartureReminder.plan(context, name, address, lat, lng, at, leave)
                    Toast.makeText(context, tr("Erinnerung für %@ geplant.", name), Toast.LENGTH_SHORT).show()
                }
            }) { Text(tr("Erinnern")) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(tr("Abbrechen")) } },
    )
}

/** Ort in eine eigene Liste speichern oder neue Liste anlegen (wie iOS SaveToListSheet) */
@Composable
private fun SaveToListDialog(name: String, address: String?, lat: Double, lng: Double, onDismiss: () -> Unit) {
    val lists by de.koeven.meeterz.data.PlaceLists.lists.collectAsState()
    var newName by remember { mutableStateOf("") }
    var shared by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { if (!de.koeven.meeterz.data.PlaceLists.loaded) de.koeven.meeterz.data.PlaceLists.refresh() }
    val own = lists.filter { it.owner == AppState.myId }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(tr("In Liste speichern")) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(name, color = MaterialTheme.colorScheme.onSurfaceVariant)
                LazyColumn(Modifier.heightIn(max = 240.dp)) {
                    items(own) { list ->
                        Row(Modifier.fillMaxWidth().clickable {
                            onDismiss()
                            AppState.scope.launch { de.koeven.meeterz.data.PlaceLists.add(name, address, lat, lng, list) }
                        }.padding(vertical = 12.dp)) {
                            Text(list.name, Modifier.weight(1f), fontWeight = FontWeight.SemiBold)
                            Text("${list.items.size}", color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
                TextField(newName, { newName = it }, placeholder = { Text(tr("Neue Liste, z. B. Lieblingscafés")) }, singleLine = true, modifier = Modifier.fillMaxWidth())
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(tr("Mit Freunden teilen"), Modifier.weight(1f))
                    Switch(shared, { shared = it })
                }
            }
        },
        confirmButton = {
            Button(enabled = newName.isNotBlank(), onClick = {
                onDismiss()
                AppState.scope.launch {
                    de.koeven.meeterz.data.PlaceLists.create(newName.trim(), shared)?.let { de.koeven.meeterz.data.PlaceLists.add(name, address, lat, lng, it) }
                }
            }) { Text(tr("Anlegen und speichern")) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(tr("Abbrechen")) } },
    )
}

/** Gefahr melden (wie iOS HazardReportSheet) */
@Composable
private fun HazardDialog(onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text(tr("Abbrechen")) } },
        title = { Text(tr("Gefahr melden")) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(tr("Andere Meeterz-Fahrer hinter dir werden eine Stunde lang gewarnt."), style = MaterialTheme.typography.bodySmall)
                for (k in de.koeven.meeterz.data.HazardStore.Kind.entries) {
                    OutlinedButton(onClick = {
                        onDismiss()
                        AppState.scope.launch { de.koeven.meeterz.data.HazardStore.report(k) }
                    }, Modifier.fillMaxWidth()) { Text(k.title) }
                }
            }
        },
    )
}

/** Per Gedrückthalten gesetzter Pin */
private data class DroppedPin(val lat: Double, val lng: Double, val name: String, val address: String?,
    val details: PlaceSearch.Details? = null, val isPoi: Boolean = false)

/** Karte unten wie iOS PinCard bzw. Apples Ortskarte: Name, Kategorie, Adresse, Öffnungszeiten, Bewertung,
 *  Anrufen/Website, „Entfernen“ und „Hierhin navigieren“ */
@Composable
private fun PinCard(pin: DroppedPin, onNavigate: () -> Unit, onRemove: () -> Unit) {
    val context = LocalContext.current
    val d = pin.details
    var week by remember(pin.lat, pin.lng) { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    if (saving) SaveToListDialog(pin.name, pin.address, pin.lat, pin.lng, onDismiss = { saving = false })
    var fuel by remember(pin.lat, pin.lng) { mutableStateOf<de.koeven.meeterz.data.FuelPrices.Price?>(null) }
    LaunchedEffect(pin.lat, pin.lng, d?.category) {
        if (de.koeven.meeterz.data.FuelPrices.isGasStation(d?.category, pin.name))
            fuel = de.koeven.meeterz.data.FuelPrices.prices(listOf(pin.lat to pin.lng)).firstOrNull()
    }
    Surface(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp), shape = RoundedCornerShape(20.dp),
        color = MaterialTheme.colorScheme.surface, border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(pin.name, Modifier.weight(1f), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    // In Liste speichern: kleines Symbol neben dem Namen (wie iOS), keine eigene Zeile
                    IconButton(onClick = { saving = true }, Modifier.size(32.dp)) {
                        Icon(Icons.Default.BookmarkBorder, tr("In Liste speichern"), Modifier.size(20.dp))
                    }
                }
                val sub = listOfNotNull(d?.category, d?.rating?.let { r -> "★ " + String.format(java.util.Locale.getDefault(), "%.1f", r) + (d.reviews?.let { " ($it)" } ?: "") })
                if (sub.isNotEmpty()) Text(sub.joinToString(" · "), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                pin.address?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                d?.openNow()?.let { open ->
                    val today = d.hours!![(java.util.Calendar.getInstance().get(java.util.Calendar.DAY_OF_WEEK) + 5) % 7]
                    Text((if (open) tr("Jetzt geöffnet") else tr("Geschlossen")) + (if (today.isEmpty()) "" else " · " + hoursText(today)) + if (week) " ▴" else " ▾",
                        style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.SemiBold,
                        color = if (open) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error,
                        modifier = Modifier.clickable { week = !week })
                    if (week) {
                        val names = java.text.DateFormatSymbols.getInstance().shortWeekdays // 1 = Sonntag
                        d.hours.forEachIndexed { i, spans ->
                            Text("${names[(i + 1) % 7 + 1]}  " + if (spans.isEmpty()) tr("Geschlossen") else hoursText(spans),
                                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
            }
            if (d?.hours == null) d?.hoursText?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (d?.osm == true) Text("© OpenStreetMap", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            fuel?.text?.takeIf { it.isNotEmpty() }?.let {
                Column {
                    Text(it, style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.primary)
                    Text(de.koeven.meeterz.data.FuelPrices.ATTRIBUTION, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            if (d?.phone != null || d?.website != null) Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                d.phone?.let { phone ->
                    OutlinedButton(onClick = { runCatching { context.startActivity(android.content.Intent(android.content.Intent.ACTION_DIAL, android.net.Uri.parse("tel:$phone"))) } },
                        Modifier.weight(1f)) { Text(tr("Anrufen")) }
                }
                d.website?.let { web ->
                    OutlinedButton(onClick = { runCatching { context.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW,
                        android.net.Uri.parse(if (web.startsWith("http")) web else "https://$web"))) } }, Modifier.weight(1f)) { Text(tr("Website")) }
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedButton(onClick = onRemove, Modifier.weight(1f)) { Text(tr(if (pin.isPoi) "Schließen" else "Entfernen")) }
                Button(onClick = onNavigate, Modifier.weight(1f)) { Text(tr("Hierhin navigieren")) }
            }
        }
    }
}

private fun hoursText(spans: List<IntRange>) = spans.joinToString(", ") { r ->
    if (r.first == 0 && r.last >= 1439) tr("24 Stunden")
    else "%02d:%02d–%02d:%02d".format(r.first / 60, r.first % 60, (r.last + 1) / 60 % 24, (r.last + 1) % 60)
}

/** Roter Pin wie iOS DroppedPinMarker (mappin.circle.fill in Theme.danger) */
private fun pinBitmap(): android.graphics.Bitmap {
    val d = android.content.res.Resources.getSystem().displayMetrics.density
    val size = (38 * d).toInt()
    val bmp = android.graphics.Bitmap.createBitmap(size, size, android.graphics.Bitmap.Config.ARGB_8888)
    val c = android.graphics.Canvas(bmp)
    val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG)
    val r = size / 2f
    paint.setShadowLayer(4 * d, 0f, 1 * d, 0x55000000)
    paint.color = 0xFFE5484D.toInt(); c.drawCircle(r, r, r - 4 * d, paint)
    paint.clearShadowLayer()
    paint.color = android.graphics.Color.WHITE; c.drawCircle(r, r - 3 * d, 5 * d, paint)
    paint.strokeWidth = 2.5f * d; c.drawLine(r, r, r, r + 9 * d, paint)
    return bmp
}


/**
 * Suche ohne Eingabe, aufgebaut wie Apple Karten (wie iOS SearchView): Vorschläge (Termin/übliches Ziel, Treffen,
 * geparktes Auto), Orte und Freunde als runde Kacheln, Zuletzt, Listen, In der Nähe finden. Kacheln gedrückt halten:
 * umbenennen, Adresse ändern, löschen.
 */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun SearchStart(
    favorites: List<de.koeven.meeterz.data.Favorite>,
    friends: List<de.koeven.meeterz.data.FriendRow>,
    live: Map<String, de.koeven.meeterz.data.LivePosition>,
    onChoose: (String, String?, Double, Double) -> Unit,
    onAssign: (String) -> Unit,
    onRename: (de.koeven.meeterz.data.Favorite) -> Unit,
    onCategory: (PlaceSearch.Category) -> Unit,
) {
    val meetups by AppState.meetups.meetups.collectAsState()
    val lists by de.koeven.meeterz.data.PlaceLists.lists.collectAsState()
    val suggestion by de.koeven.meeterz.suggest.RouteSuggestions.current.collectAsState()
    val parked by de.koeven.meeterz.suggest.Parking.spot.collectAsState()
    val recents by de.koeven.meeterz.suggest.Recents.items.collectAsState()
    var openList by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        if (!de.koeven.meeterz.data.PlaceLists.loaded) de.koeven.meeterz.data.PlaceLists.refresh()
        de.koeven.meeterz.suggest.RouteSuggestions.refresh()
    }
    openList?.let { id -> PlaceListDialog(id, onChoose, onDismiss = { openList = null }) }
    val me = AppState.lastLocation
    // Fahrzeiten unter den Kacheln (eine Mapbox-Matrix-Anfrage, wie iOS)
    val times by produceState(emptyMap<String, Double>()) {
        val here = me ?: return@produceState
        val targets = favorites.map { it.lat to it.lng } + friends.filter { it.isAccepted }.mapNotNull { f ->
            val p = live[f.friendId]; val la = p?.lat ?: f.lat; val ln = p?.lng ?: f.lng
            if (la != null && ln != null) la to ln else null
        }
        value = de.koeven.meeterz.suggest.TileTravelTimes.get(here.latitude, here.longitude, targets)
    }
    fun near(lat: Double, lng: Double) = me?.let { ChargePlanner.distance(it.latitude, it.longitude, lat, lng) }?.let { d ->
        when {
            d < 200 -> tr("In der Nähe")
            else -> times[de.koeven.meeterz.suggest.TileTravelTimes.key(lat, lng)]?.let { tr("%@ Min.", maxOf(1, Math.round(it / 60).toInt())) }
                ?: distanceText(d)
        }
    }

    Surface(Modifier.padding(top = 8.dp), shape = RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.surface,
        border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)) {
        LazyColumn(Modifier.heightIn(max = 560.dp).padding(vertical = 8.dp)) {
            // Vorschläge
            val accepted = meetups.filter { it.isAccepted }.distinctBy { it.groupId ?: it.id }
            if (suggestion != null || accepted.isNotEmpty() || parked != null) {
                item { SearchHeader(tr("Vorschläge")) }
                suggestion?.let { sg -> item("sg") {
                    SuggestionRow(if (sg.calendarTitle != null) Icons.Default.Event else Icons.Default.History,
                        androidx.compose.ui.graphics.Color(0xFFE0457B), sg.title, sg.subtitle) { onChoose(sg.name, sg.address, sg.lat, sg.lng) }
                } }
                items(accepted, key = { "m" + it.id }) { m ->
                    SuggestionRow(Icons.Default.Groups, MaterialTheme.colorScheme.primary, m.placeName,
                        tr("Treffen mit %@", if (m.incoming) m.withText else m.otherName)) { onChoose(m.placeName, null, m.lat, m.lng) }
                }
                parked?.let { p -> item("park") {
                    SuggestionRow(Icons.Default.DirectionsCar, androidx.compose.ui.graphics.Color(0xFF3478F6), tr("Geparktes Auto"),
                        near(p.lat, p.lng)) { onChoose(tr("Dein Auto"), null, p.lat, p.lng) }
                } }
            }
            // Orte als runde Kacheln
            item { SearchHeader(tr("Orte")) }
            item("orte") {
                androidx.compose.foundation.lazy.LazyRow(contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 12.dp),
                    horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    for (kind in listOf("home", "work")) {
                        val fav = favorites.firstOrNull { it.kind == kind }
                        item(kind) {
                            if (fav != null) FavoriteTile(fav, near(fav.lat, fav.lng), onChoose, onAssign, onRename)
                            else Tile(if (kind == "home") Icons.Default.Home else Icons.Default.Work, null, tileColor(kind),
                                if (kind == "home") tr("Zuhause") else tr("Arbeit"), tr("Festlegen")) { onAssign(kind) }
                        }
                    }
                    items(favorites.filter { it.kind == "other" }, key = { it.id }) { FavoriteTile(it, near(it.lat, it.lng), onChoose, onAssign, onRename) }
                    item("add") { Tile(Icons.Default.Add, null, MaterialTheme.colorScheme.surfaceVariant, tr("Hinzufügen"), null,
                        tint = MaterialTheme.colorScheme.primary) { onAssign("other") } }
                }
            }
            // Freunde: Ziel ist ihr aktueller Standort
            val friendPlaces = friends.filter { it.isAccepted }.mapNotNull { f ->
                val p = live[f.friendId]; val lat = p?.lat ?: f.lat; val lng = p?.lng ?: f.lng
                if (lat != null && lng != null) Triple(f, lat, lng) else null
            }
            if (friendPlaces.isNotEmpty()) {
                item { SearchHeader(tr("Freunde")) }
                item("freunde") {
                    androidx.compose.foundation.lazy.LazyRow(contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 12.dp),
                        horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        items(friendPlaces, key = { it.first.friendId }) { (f, lat, lng) ->
                            Tile(null, f.displayName.take(1).uppercase(), FriendPalette.routeColor(f.friendId), f.firstName, near(lat, lng)) {
                                onChoose(f.displayName, null, lat, lng)
                            }
                        }
                    }
                }
            }
            if (recents.isNotEmpty()) {
                item { SearchHeader(tr("Zuletzt")) }
                items(recents.take(5), key = { "r" + it.lat + it.lng }) { r ->
                    SearchRow(Icons.Default.History, r.name, r.address) { onChoose(r.name, r.address, r.lat, r.lng) }
                }
            }
            // Eigene und von Freunden geteilte Ortslisten (wie iOS)
            if (lists.isNotEmpty()) {
                item { SearchHeader(tr("Listen")) }
                items(lists, key = { "l" + it.id }) { l ->
                    val owner = if (l.owner == AppState.myId) null else friends.firstOrNull { it.friendId == l.owner }?.displayName
                    SearchRow(if (l.shared) Icons.Default.Groups else Icons.AutoMirrored.Filled.List, l.name,
                        listOfNotNull(owner, tr("%lld Orte", l.items.size)).joinToString(" · ")) { openList = l.id }
                }
            }
            item { SearchHeader(tr("In der Nähe finden")) }
            items(PlaceSearch.Category.stopovers, key = { "c" + it.name }) { c ->
                SearchRow(categoryIcon(c), c.title, null) { onCategory(c) }
            }
        }
    }
}

private fun tileColor(kind: String) = when (kind) {
    "home" -> androidx.compose.ui.graphics.Color(0xFF4FC3F7)
    "work" -> androidx.compose.ui.graphics.Color(0xFF8D6E63)
    else -> androidx.compose.ui.graphics.Color(0xFFE0457B)
}

private fun categoryIcon(c: PlaceSearch.Category) = when (c) {
    PlaceSearch.Category.GAS -> Icons.Default.LocalGasStation
    PlaceSearch.Category.CHARGING -> Icons.Default.EvStation
    PlaceSearch.Category.PARKING -> Icons.Default.LocalParking
    PlaceSearch.Category.RESTAURANT -> Icons.Default.Restaurant
    PlaceSearch.Category.COFFEE -> Icons.Default.LocalCafe
    else -> Icons.Default.Place
}

@Composable
private fun SuggestionRow(icon: androidx.compose.ui.graphics.vector.ImageVector, color: androidx.compose.ui.graphics.Color,
                          title: String, subtitle: String?, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(40.dp).background(color, androidx.compose.foundation.shape.CircleShape), contentAlignment = Alignment.Center) {
            Icon(icon, null, tint = androidx.compose.ui.graphics.Color.White, modifier = Modifier.size(20.dp))
        }
        Column(Modifier.padding(start = 12.dp)) {
            Text(title, fontWeight = FontWeight.SemiBold, maxLines = 1)
            subtitle?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1) }
        }
    }
}

/** Runde Kachel (Ort oder Freund) mit Name und Entfernung darunter */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun Tile(icon: androidx.compose.ui.graphics.vector.ImageVector?, initials: String?, color: androidx.compose.ui.graphics.Color,
                 title: String, subtitle: String?, tint: androidx.compose.ui.graphics.Color = androidx.compose.ui.graphics.Color.White,
                 onLongClick: (() -> Unit)? = null, onClick: () -> Unit) {
    Column(Modifier.width(84.dp).combinedClickable(onClick = onClick, onLongClick = onLongClick).padding(vertical = 4.dp),
        horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.size(60.dp).background(color, androidx.compose.foundation.shape.CircleShape), contentAlignment = Alignment.Center) {
            icon?.let { Icon(it, null, tint = tint, modifier = Modifier.size(28.dp)) }
            initials?.let { Text(it, color = tint, fontWeight = FontWeight.Bold, style = MaterialTheme.typography.titleLarge) }
        }
        Text(title, Modifier.padding(top = 6.dp), fontWeight = FontWeight.SemiBold, style = MaterialTheme.typography.labelLarge, maxLines = 1)
        Text(subtitle ?: " ", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
    }
}

@Composable
private fun FavoriteTile(fav: de.koeven.meeterz.data.Favorite, distance: String?, onChoose: (String, String?, Double, Double) -> Unit,
                         onAssign: (String) -> Unit, onRename: (de.koeven.meeterz.data.Favorite) -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Box {
        Tile(when (fav.kind) { "home" -> Icons.Default.Home; "work" -> Icons.Default.Work; else -> Icons.Default.Star }, null,
            tileColor(fav.kind), fav.label, distance, onLongClick = { menu = true }) { onChoose(fav.label, fav.address, fav.lat, fav.lng) }
        androidx.compose.material3.DropdownMenu(menu, { menu = false }) {
            if (fav.kind == "other") androidx.compose.material3.DropdownMenuItem(text = { Text(tr("Umbenennen")) }, onClick = { menu = false; onRename(fav) })
            else androidx.compose.material3.DropdownMenuItem(text = { Text(tr("Adresse ändern")) }, onClick = { menu = false; onAssign(fav.kind) })
            androidx.compose.material3.DropdownMenuItem(text = { Text(tr("Löschen"), color = MaterialTheme.colorScheme.error) },
                onClick = { menu = false; AppState.favorites.remove(fav.id) })
        }
    }
}

/** Eine Liste (wie iOS PlaceListView): Ort antippen = auswählen; eigene: gedrückt halten entfernt, Teilen umschalten, löschen */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun PlaceListDialog(id: String, onChoose: (String, String?, Double, Double) -> Unit, onDismiss: () -> Unit) {
    val lists by de.koeven.meeterz.data.PlaceLists.lists.collectAsState()
    val list = lists.firstOrNull { it.id == id } ?: return onDismiss()
    val mine = list.owner == AppState.myId
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(list.name) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                if (mine) Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(tr("Mit Freunden teilen"), Modifier.weight(1f))
                    Switch(list.shared, { v -> AppState.scope.launch { de.koeven.meeterz.data.PlaceLists.setShared(list, v) } })
                }
                if (list.items.isEmpty()) Text(tr("Noch keine Orte. Tippe auf einen Ort und dann auf „In Liste speichern“."), style = MaterialTheme.typography.bodySmall)
                LazyColumn(Modifier.heightIn(max = 360.dp)) {
                    items(list.items, key = { it.id }) { item ->
                        SearchRow(Icons.Default.Place, item.name, item.address,
                            onLongClick = if (mine) ({ AppState.scope.launch { de.koeven.meeterz.data.PlaceLists.remove(item) } }) else null) {
                            onDismiss(); onChoose(item.name, item.address, item.lat, item.lng)
                        }
                    }
                }
                if (mine) Text(tr("Gedrückt halten entfernt einen Ort."), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text(tr("Fertig")) } },
        dismissButton = {
            if (mine) TextButton(onClick = { onDismiss(); AppState.scope.launch { de.koeven.meeterz.data.PlaceLists.delete(list) } }) {
                Text(tr("Liste löschen"), color = MaterialTheme.colorScheme.error)
            }
        },
    )
}

@Composable
private fun SearchHeader(text: String) = Text(text, Modifier.padding(start = 16.dp, top = 10.dp, bottom = 4.dp),
    style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun SearchRow(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, subtitle: String?,
                      onLongClick: (() -> Unit)? = null, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().combinedClickable(onClick = onClick, onLongClick = onLongClick).padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(22.dp))
        Column(Modifier.padding(start = 12.dp)) {
            Text(title, fontWeight = FontWeight.SemiBold)
            subtitle?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
    }
}

/**
 * Karte folgt mir: in 2D genordet, in 3D in Fahrtrichtung (wie iOS). Vorher drehte die Karte auch in 2D mit der
 * Kompassrichtung des Handys – der Kompass-Knopf nordete nur kurz, dann drehte sie zurück (21.11.).
 */
internal fun followMe(viewport: com.mapbox.maps.plugin.viewport.ViewportPlugin, map3d: Boolean, turns: Boolean = !UiPreferences.northUp.value) =
    viewport.makeFollowPuckViewportState(
        com.mapbox.maps.plugin.viewport.data.FollowPuckViewportStateOptions.Builder()
            .bearing(if (turns) com.mapbox.maps.plugin.viewport.data.FollowPuckViewportStateBearing.SyncWithLocationPuck
                     else com.mapbox.maps.plugin.viewport.data.FollowPuckViewportStateBearing.Constant(0.0))
            .pitch(if (map3d) 45.0 else 0.0)
            .build())
