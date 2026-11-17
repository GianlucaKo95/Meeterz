package de.koeven.meeterz.ui

import androidx.compose.material.icons.filled.Check
import de.koeven.meeterz.tr
import androidx.compose.material.icons.filled.AddLocationAlt
import androidx.compose.foundation.layout.size
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.material3.FilterChip
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
    val statusBarPx = context.resources.getIdentifier("status_bar_height", "dimen", "android")
        .takeIf { it > 0 }?.let { context.resources.getDimensionPixelSize(it) } ?: (24 * density).toInt()
    val compassTopMarginPx = statusBarPx + 184.0 * density
    val mapView = remember {
        MapView(context).apply {
            mapboxMap.loadStyle(if (UiPreferences.mapStyle.value == "satellite") Style.STANDARD_SATELLITE else Style.STANDARD)
            // MapView liegt edge-to-edge unter der Statusleiste: den nativen Kompass darunter verschieben.
            compass.updateSettings {
                marginTop = compassTopMarginPx.toFloat()
                marginRight = (20.0 * context.resources.displayMetrics.density).toFloat()
            }
            // Maßstab lag über der Statusleiste (Foto 17.11.) – iOS zeigt keinen
            scalebar.enabled = false
            mapboxMap.setCamera(CameraOptions.Builder().zoom(14.0).build())
            location.updateSettings {
                enabled = true
                locationPuck = createDefault2DPuck(withBearing = true)
            }
            viewport.transitionTo(viewport.makeFollowPuckViewportState())
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
    LaunchedEffect(map3d) {
        mapView.mapboxMap.setCamera(CameraOptions.Builder().pitch(if (map3d) 45.0 else 0.0).build())
    }
    DisposableEffect(Unit) { binder.attach(); onDispose { binder.detach() } }
    DisposableEffect(mapView) { val t = TrafficLayer.install(mapView.mapboxMap); onDispose { t.cancel() } }
    LaunchedEffect(guidance != null) {
        binder.setActive(guidance != null)
        if (guidance == null) mapView.viewport.transitionTo(mapView.viewport.makeFollowPuckViewportState())
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
            addClickListener { a -> a.getData()?.asString?.let { selectedFriend = it }; true }
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
    LaunchedEffect(query) {
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
        DisposableEffect(mapView) {
            val listener = com.mapbox.maps.plugin.gestures.OnMapLongClickListener { point ->
                if (NavigationController.guidance.value != null) return@OnMapLongClickListener false
                haptics.performHapticFeedback(androidx.compose.ui.hapticfeedback.HapticFeedbackType.LongPress)
                val pin = DroppedPin(point.latitude(), point.longitude(), tr("Gesetzter Pin"), null)
                droppedPin = pin
                query = ""; results = emptyList()
                scope.launch {
                    val a = withContext(Dispatchers.IO) {
                        runCatching { android.location.Geocoder(context).getFromLocation(pin.lat, pin.lng, 1)?.firstOrNull() }.getOrNull()
                    } ?: return@launch
                    if (droppedPin?.lat != pin.lat || droppedPin?.lng != pin.lng) return@launch
                    val street = listOfNotNull(a.thoroughfare, a.subThoroughfare).joinToString(" ")
                    val city = listOfNotNull(a.postalCode, a.locality).joinToString(" ")
                    val name = a.featureName?.takeIf { it != a.subThoroughfare } ?: street.ifEmpty { pin.name }
                    droppedPin = pin.copy(name = name, address = listOf(street, city).filter { it.isNotEmpty() }.joinToString(", ").ifEmpty { null })
                }
                true
            }
            mapView.gestures.addOnMapLongClickListener(listener)
            onDispose { mapView.gestures.removeOnMapLongClickListener(listener) }
        }
        // Stories an ihrem Ort (wie iOS): Antippen spielt die Stories der Person ab
        val storyManager = remember(mapView, mapStyleRevision) {
            mapView.annotations.createPointAnnotationManager().apply {
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
        val pinManager = remember(mapView, mapStyleRevision) { mapView.annotations.createPointAnnotationManager() }
        LaunchedEffect(droppedPin, mapStyleRevision) {
            pinManager.deleteAll()
            droppedPin?.let { p ->
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
        charging?.let { ChargingCard(it, Modifier.align(Alignment.Center)) }

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
                if (query.isEmpty() && preview == null && searchFocused && assigning == null) {
                    SearchStart(favorites, visibleFriends, live,
                        onChoose = { n, a, la, ln -> choose(n, a, la, ln) },
                        onAssign = { assigning = it },
                        onRename = { renaming = it })
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
                            MapCircleButton(Icons.Default.NearMe, tr("Auf meinen Standort zentrieren"), tint = MaterialTheme.colorScheme.primary) {
                                mapView.viewport.transitionTo(mapView.viewport.makeFollowPuckViewportState())
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
    Surface(modifier.fillMaxWidth().navigationBarsPadding().padding(12.dp), shape = RoundedCornerShape(20.dp), shadowElevation = 2.dp, border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)) {
        Row(Modifier.padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(tr("Ankunft %@", clock(g.remainingSeconds)), fontWeight = FontWeight.SemiBold)
                Text("${minutes(g.remainingSeconds)} · ${km(g.remainingDistance)}", style = MaterialTheme.typography.bodySmall)
                val forecast by ChargeMonitor.forecast.collectAsState()
                forecast?.let { Text(it.text, style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.SemiBold,
                    color = if (it.low) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary) }
            }
            IconButton(onClick = { showStop = true }) { Icon(Icons.Default.AddLocationAlt, tr("Zwischenstopp")) }
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

/** Wie ActivityFormat.distance auf iOS: unter 100 m auf 10 m, unter 1 km auf 50 m gerundet */
fun km(meters: Double): String {
    if (meters < 1000) {
        val rounded = if (meters < 100) Math.round(meters / 10) * 10 else Math.round(meters / 50) * 50
        return "${maxOf(rounded, 0)} m"
    }
    return String.format(java.util.Locale.GERMANY, "%.1f km", meters / 1000)
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
    var places by remember { mutableStateOf<List<PlaceSearch.Place>>(emptyList()) }
    LaunchedEffect(category, query) {
        val me = AppState.lastLocation ?: return@LaunchedEffect
        places = if (query.isNotBlank()) { delay(300); PlaceSearch.search(query, me.latitude, me.longitude) }
        else category?.let { PlaceSearch.places(it, me.latitude, me.longitude, 8) }.orEmpty()
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text(tr("Abbrechen")) } },
        title = { Text(tr("Zwischenstopp")) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                TextField(query, { query = it }, placeholder = { Text(tr("Suchen")) }, singleLine = true, modifier = Modifier.fillMaxWidth())
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    for (c in listOf(PlaceSearch.Category.GAS, PlaceSearch.Category.REST_AREA, PlaceSearch.Category.COFFEE, PlaceSearch.Category.RESTAURANT)) {
                        FilterChip(selected = query.isBlank() && category == c, onClick = { category = c; query = "" }, label = { Text(c.title) })
                    }
                }
                val me = AppState.lastLocation
                LazyColumn(Modifier.heightIn(max = 360.dp)) {
                    items(places) { p ->
                        Column(Modifier.fillMaxWidth().clickable {
                            onDismiss()
                            scope.launch {
                                val ok = NavigationController.addStop(context, p.name, p.lat, p.lng)
                                Toast.makeText(context, if (ok) tr("Stopp: %@", p.name) else tr("Stopp konnte nicht eingefügt werden"), Toast.LENGTH_SHORT).show()
                            }
                        }.padding(vertical = 10.dp)) {
                            Text(p.name, fontWeight = FontWeight.SemiBold)
                            Text(listOfNotNull(me?.let { km(de.koeven.meeterz.ev.ChargePlanner.distance(it.latitude, it.longitude, p.lat, p.lng)) }, p.address)
                                .joinToString(" · "), style = MaterialTheme.typography.bodySmall, maxLines = 1)
                        }
                    }
                }
            }
        },
    )
}


/** Per Gedrückthalten gesetzter Pin */
private data class DroppedPin(val lat: Double, val lng: Double, val name: String, val address: String?)

/** Karte unten wie iOS PinCard: Name, Adresse, „Entfernen“ und „Hierhin navigieren“ */
@Composable
private fun PinCard(pin: DroppedPin, onNavigate: () -> Unit, onRemove: () -> Unit) {
    Surface(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp), shape = RoundedCornerShape(20.dp),
        color = MaterialTheme.colorScheme.surface, border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Column {
                Text(pin.name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                pin.address?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedButton(onClick = onRemove, Modifier.weight(1f)) { Text(tr("Entfernen")) }
                Button(onClick = onNavigate, Modifier.weight(1f)) { Text(tr("Hierhin navigieren")) }
            }
        }
    }
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
 * Suche ohne Eingabe (wie iOS SearchView): Favoriten mit Zuhause/Arbeit (sonst „… festlegen“), eigene Orte,
 * „Favorit hinzufügen“; darunter Schnellziele (vereinbarte Treffpunkte, Freunde). Gedrückt halten: umbenennen,
 * Adresse ändern, löschen.
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
) {
    val meetups by AppState.meetups.meetups.collectAsState()
    Surface(Modifier.padding(top = 8.dp), shape = RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.surface,
        border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)) {
        LazyColumn(Modifier.heightIn(max = 460.dp).padding(vertical = 8.dp)) {
            item { SearchHeader(tr("Favoriten")) }
            for (kind in listOf("home", "work")) {
                val fav = favorites.firstOrNull { it.kind == kind }
                item(kind) {
                    if (fav != null) FavoriteRow(fav, onChoose, onAssign, onRename)
                    else SearchRow(if (kind == "home") Icons.Default.Home else Icons.Default.Work,
                        if (kind == "home") tr("Zuhause festlegen") else tr("Arbeit festlegen"), tr("Adresse suchen und speichern")) { onAssign(kind) }
                }
            }
            items(favorites.filter { it.kind == "other" }, key = { it.id }) { FavoriteRow(it, onChoose, onAssign, onRename) }
            item { SearchRow(Icons.Default.AddCircleOutline, tr("Favorit hinzufügen"), tr("Ort suchen und mit Namen speichern")) { onAssign("other") } }
            val meetupPlaces = meetups.filter { it.isAccepted }.distinctBy { it.groupId ?: it.id }
            val friendPlaces = friends.filter { it.isAccepted }.mapNotNull { f ->
                val p = live[f.friendId]; val lat = p?.lat ?: f.lat; val lng = p?.lng ?: f.lng
                if (lat != null && lng != null) Triple(f, lat, lng) else null
            }
            if (meetupPlaces.isNotEmpty() || friendPlaces.isNotEmpty()) {
                item { SearchHeader(tr("Schnellziele")) }
                items(meetupPlaces, key = { "m" + it.id }) { m ->
                    SearchRow(Icons.Default.Event, m.placeName, m.withText) { onChoose(m.placeName, null, m.lat, m.lng) }
                }
                items(friendPlaces, key = { "f" + it.first.friendId }) { (f, lat, lng) ->
                    SearchRow(Icons.Default.Person, f.displayName, tr("Aktueller Standort")) { onChoose(f.displayName, null, lat, lng) }
                }
            }
        }
    }
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

@Composable
private fun FavoriteRow(fav: de.koeven.meeterz.data.Favorite, onChoose: (String, String?, Double, Double) -> Unit,
                        onAssign: (String) -> Unit, onRename: (de.koeven.meeterz.data.Favorite) -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Box {
        SearchRow(when (fav.kind) { "home" -> Icons.Default.Home; "work" -> Icons.Default.Work; else -> Icons.Default.Star },
            fav.label, fav.address, onLongClick = { menu = true }) { onChoose(fav.label, fav.address, fav.lat, fav.lng) }
        androidx.compose.material3.DropdownMenu(menu, { menu = false }) {
            if (fav.kind == "other") androidx.compose.material3.DropdownMenuItem(text = { Text(tr("Umbenennen")) }, onClick = { menu = false; onRename(fav) })
            else androidx.compose.material3.DropdownMenuItem(text = { Text(tr("Adresse ändern")) }, onClick = { menu = false; onAssign(fav.kind) })
            androidx.compose.material3.DropdownMenuItem(text = { Text(tr("Löschen"), color = MaterialTheme.colorScheme.error) },
                onClick = { menu = false; AppState.favorites.remove(fav.id) })
        }
    }
}
