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
import com.mapbox.maps.plugin.annotation.annotations
import com.mapbox.maps.plugin.annotation.generated.PointAnnotationManager
import com.mapbox.maps.plugin.annotation.generated.PointAnnotationOptions
import com.mapbox.maps.plugin.annotation.generated.createPointAnnotationManager
import com.mapbox.maps.plugin.annotation.generated.createPolylineAnnotationManager
import com.mapbox.maps.plugin.annotation.generated.PolylineAnnotationOptions
import com.mapbox.maps.plugin.locationcomponent.createDefault2DPuck
import com.mapbox.maps.plugin.locationcomponent.location
import com.mapbox.maps.plugin.viewport.viewport
import com.mapbox.navigation.base.route.NavigationRoute
import de.koeven.meeterz.AppState
import de.koeven.meeterz.nav.NavigationController
import de.koeven.meeterz.nav.PlaceSearch
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Date

/** Hauptkarte: Freunde, Suche, Routenvorschau und Führung */
@Composable
fun MapScreen() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val friends by AppState.friends.collectAsState()
    val live by AppState.hub.positions.collectAsState()
    val guidance by NavigationController.guidance.collectAsState()

    val mapView = remember {
        MapView(context).apply {
            mapboxMap.loadStyle(Style.STANDARD)
            mapboxMap.setCamera(CameraOptions.Builder().zoom(14.0).build())
            location.updateSettings {
                enabled = true
                locationPuck = createDefault2DPuck(withBearing = true)
            }
            viewport.transitionTo(viewport.makeFollowPuckViewportState())
        }
    }
    val binder = remember { NavigationMapBinder(mapView) }
    DisposableEffect(Unit) { binder.attach(); onDispose { binder.detach() } }
    LaunchedEffect(guidance != null) {
        binder.setActive(guidance != null)
        if (guidance == null) mapView.viewport.transitionTo(mapView.viewport.makeFollowPuckViewportState())
    }

    val friendRoutes by AppState.routes.routes.collectAsState()
    val lines = remember { mapView.annotations.createPolylineAnnotationManager() }
    LaunchedEffect(friendRoutes) {
        // Routen der Freunde in Bernstein (wie iOS: „ist unterwegs“)
        lines.deleteAll()
        for (r in friendRoutes.values) {
            lines.create(
                PolylineAnnotationOptions()
                    .withPoints(r.coordinates.map { Point.fromLngLat(it.first, it.second) })
                    .withLineColor(MeeterzColors.amber.toArgb())
                    .withLineWidth(5.0)
                    .withLineOpacity(0.8)
            )
        }
    }
    val annotations: PointAnnotationManager = remember { mapView.annotations.createPointAnnotationManager() }
    val avatars by de.koeven.meeterz.data.AvatarStore.images.collectAsState()
    val passengerVersion by de.koeven.meeterz.social.Passengers.version.collectAsState()
    LaunchedEffect(friends, live, friendRoutes, avatars, passengerVersion) {
        annotations.deleteAll()
        val riding = de.koeven.meeterz.social.Passengers.riding
        for (f in friends.filter { it.isAccepted && it.friendId !in riding }) {
            val pos = live[f.friendId]
            val lat = pos?.lat ?: f.lat ?: continue
            val lng = pos?.lng ?: f.lng ?: continue
            annotations.create(
                PointAnnotationOptions()
                    .withPoint(Point.fromLngLat(lng, lat))
                    .withIconImage(avatars[f.friendId]?.let { de.koeven.meeterz.data.AvatarStore.pin(it) } ?: initialsBubble(f.initials))
                    .withTextField(friendRoutes[f.friendId]?.let { "${f.firstName} · ${clockAt(it.eta)}" } ?: f.firstName)
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
    var planCandidate by remember { mutableStateOf<de.koeven.meeterz.data.MeetupCandidate?>(null) }
    var inviteTo by remember { mutableStateOf<NavigationController.Destination?>(null) }
    /** Übernommener Ladeplan: Vorschau-Route führt schon über die Säulen */
    var adopted by remember { mutableStateOf<ChargePlanner.Plan?>(null) }
    val favorites by AppState.favorites.items.collectAsState()
    val car by AppState.vehicle.status.collectAsState()

    fun planTo(name: String, address: String?, lat: Double, lng: Double) {
        val me = AppState.lastLocation ?: return
        val dest = NavigationController.Destination(name, lat, lng, address)
        planning = true
        results = emptyList()
        scope.launch {
            val routes = NavigationController.plan(context, Point.fromLngLat(me.longitude, me.latitude), dest)
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
    LaunchedEffect(preview, selectedRoute, guidance == null) { if (guidance == null) binder.showPreview(preview?.second, selectedRoute) }
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
        // Verkehrsmeldungen voraus (vorgelesen wird in IncidentWatcher)
        LaunchedEffect(Unit) {
            de.koeven.meeterz.nav.IncidentWatcher.alerts.collect { a ->
                Toast.makeText(context, listOfNotNull(a.title, a.subtitle).joinToString(" – "), Toast.LENGTH_LONG).show()
            }
        }
        // Geparktes Auto (wie ParkedCarMarker auf iOS): Antippen → zu Fuß hin oder vergessen
        val parked by de.koeven.meeterz.suggest.Parking.spot.collectAsState()
        var parkedMenu by remember { mutableStateOf(false) }
        val parkedManager = remember { mapView.annotations.createPointAnnotationManager() }
        LaunchedEffect(parked) {
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
                SocialCard { planCandidate = it }
                MeetingPointCard()
                GuidanceBar(g, Modifier)
            }
        } else {
            Column(Modifier.statusBarsPadding().padding(12.dp)) {
                Surface(shape = RoundedCornerShape(16.dp), shadowElevation = 2.dp, border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)) {
                    TextField(
                        value = query, onValueChange = { query = it; preview = null },
                        placeholder = { Text(tr("Ziel oder Adresse suchen")) },
                        leadingIcon = { Icon(Icons.Default.Search, null) },
                        trailingIcon = { if (query.isNotEmpty()) IconButton(onClick = { query = ""; results = emptyList() }) { Icon(Icons.Default.Close, tr("Leeren")) } },
                        singleLine = true,
                        colors = TextFieldDefaults.colors(focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                if (query.isEmpty() && preview == null) {
                    Row(Modifier.padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                        for (fav in favorites.sortedBy { listOf("home", "work", "other").indexOf(it.kind) }.take(3)) {
                            AssistChip(onClick = { planTo(fav.label, fav.address, fav.lat, fav.lng) }, label = { Text(fav.label) })
                        }
                        Spacer(Modifier.weight(1f))
                        car?.takeIf { it.soc != null && it.ageSeconds < 7 * 86400 }?.let { c ->
                            Surface(shape = RoundedCornerShape(12.dp), shadowElevation = 2.dp, border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)) {
                                Text("${c.soc!!.toInt()} %" + (c.rangeKm?.let { " · ${it.toInt()} km" } ?: "") + if (c.charging == true) " · " + tr("lädt") else "",
                                    Modifier.padding(horizontal = 10.dp, vertical = 6.dp), fontWeight = FontWeight.SemiBold)
                            }
                        }
                        FilledTonalIconButton(onClick = { showSettings = true }) { Icon(Icons.Default.Settings, tr("Einstellungen")) }
                        FilledTonalIconButton(onClick = { showMeetups = true }) { Icon(Icons.Default.Event, tr("Treffen")) }
                        FilledTonalIconButton(onClick = { showFriends = true }) { Icon(Icons.Default.People, tr("Freunde")) }
                    }
                    StatusPill()
                }
                if (results.isNotEmpty() && preview == null) {
                    Surface(shape = RoundedCornerShape(16.dp), shadowElevation = 2.dp, border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant), modifier = Modifier.padding(top = 8.dp)) {
                        LazyColumn(Modifier.heightIn(max = 360.dp)) {
                            items(results) { place ->
                                Column(Modifier.fillMaxWidth().clickable { planTo(place.name, place.address, place.lat, place.lng) }
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
                SocialCard { planCandidate = it }
                MeetingPointCard()
            }
            if (showMeetups) MeetupsOverviewScreen(onClose = { showMeetups = false })
            if (showFriends) FriendsScreen(onClose = { showFriends = false })
            if (showSettings) SettingsScreen(onClose = { showSettings = false })
            preview?.let { (dest, routes) ->
                PreviewCard(dest, routes, selectedRoute, { selectedRoute = it }, Modifier.align(Alignment.BottomCenter),
                    onSave = { kind, label -> AppState.favorites.save(kind, label, dest.address, dest.lat, dest.lng) },
                    onStart = { NavigationController.start(routes, dest, selectedRoute); preview = null; query = "" },
                    onCancel = { preview = null; adopted = null },
                    onInvite = { inviteTo = dest },
                    charge = { ChargePlanSection(routes.getOrElse(selectedRoute) { routes.first() }, adopted) { plan -> adopt(dest, plan) } })
            }
        }
    }
}

@Composable
private fun PreviewCard(dest: NavigationController.Destination, routes: List<NavigationRoute>, selected: Int, onSelect: (Int) -> Unit, modifier: Modifier,
                        onSave: (String, String) -> Unit, onStart: () -> Unit, onCancel: () -> Unit, onInvite: () -> Unit,
                        charge: @Composable () -> Unit = {}) {
    var saved by remember(dest) { mutableStateOf(false) }
    val r = routes.getOrElse(selected) { routes.first() }.directionsRoute
    Surface(modifier.fillMaxWidth().navigationBarsPadding().padding(12.dp), shape = RoundedCornerShape(20.dp), shadowElevation = 2.dp, border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(dest.name, style = MaterialTheme.typography.titleMedium)
            Text(tr("%@ · %@ · Ankunft %@", minutes(r.duration()), km(r.distance()), clock(r.duration())))
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
    var muted by remember { mutableStateOf(NavigationController.muted) }
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
                    color = if (it.low) Color(0xFFD92E36) else MaterialTheme.colorScheme.primary) }
            }
            IconButton(onClick = { showStop = true }) { Icon(Icons.Default.AddLocationAlt, tr("Zwischenstopp")) }
            IconButton(onClick = { showMessage = true }) { Icon(Icons.AutoMirrored.Filled.Chat, tr("Bescheid geben")) }
            IconButton(onClick = { muted = !muted; NavigationController.muted = muted }) {
                Icon(if (muted) Icons.AutoMirrored.Filled.VolumeOff else Icons.AutoMirrored.Filled.VolumeUp, tr("Ton"))
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

private fun clockAt(at: java.time.Instant): String = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(at.toEpochMilli()))

private fun clock(secondsFromNow: Double): String =
    DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(System.currentTimeMillis() + (secondsFromNow * 1000).toLong()))

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
    Box(Modifier.padding(top = 8.dp)) {
        Surface(shape = RoundedCornerShape(50), shadowElevation = 2.dp, border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant), modifier = Modifier.clickable { open = true }) {
            Text((if (p.isIncognito) "◌ " else if (p.isSharingNow) "● " else "○ ") + sharingLabel(p).also { tick },
                Modifier.padding(horizontal = 12.dp, vertical = 6.dp), fontWeight = FontWeight.SemiBold,
                color = if (active) MeeterzColors.mint else Color.Gray, style = MaterialTheme.typography.bodySmall)
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
internal fun initialsBubble(initials: String): Bitmap {
    val size = 96
    val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = MeeterzColors.mint.toArgb() }
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
