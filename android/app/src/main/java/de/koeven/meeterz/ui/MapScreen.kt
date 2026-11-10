package de.koeven.meeterz.ui

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
import androidx.compose.material.icons.filled.ElectricCar
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
    LaunchedEffect(friends, live, friendRoutes) {
        annotations.deleteAll()
        for (f in friends.filter { it.isAccepted }) {
            val pos = live[f.friendId]
            val lat = pos?.lat ?: f.lat ?: continue
            val lng = pos?.lng ?: f.lng ?: continue
            annotations.create(
                PointAnnotationOptions()
                    .withPoint(Point.fromLngLat(lng, lat))
                    .withIconImage(initialsBubble(f.initials))
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
    var showFriends by remember { mutableStateOf(false) }
    var showEv by remember { mutableStateOf(false) }
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
            if (routes.isNotEmpty()) { preview = dest to routes; adopted = null }
        }
    }

    /** Ladestopps als Zwischenziele in die Route nehmen */
    suspend fun adopt(dest: NavigationController.Destination, plan: ChargePlanner.Plan) {
        val me = AppState.lastLocation ?: return
        val routes = NavigationController.plan(context, Point.fromLngLat(me.longitude, me.latitude), dest,
            via = plan.stops.map { Point.fromLngLat(it.site.lng, it.site.lat) })
        if (routes.isNotEmpty()) { preview = dest to routes; adopted = plan; ChargingSession.plan = plan }
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
                    sg.plan?.let { plan -> TextButton(onClick = { suggestion = null; scope.launch { ChargeMonitor.adopt(context, plan) } }) { Text("Übernehmen") } }
                },
                dismissButton = { TextButton(onClick = { suggestion = null }) { Text(if (sg.plan == null) "OK" else "Nein") } },
            )
        }
        val charging by ChargingSession.view.collectAsState()
        charging?.let { ChargingCard(it, Modifier.align(Alignment.Center)) }

        val g = guidance
        if (g != null) {
            GuidanceBanner(g)
            GuidanceBar(g, Modifier.align(Alignment.BottomCenter))
        } else {
            Column(Modifier.statusBarsPadding().padding(12.dp)) {
                Surface(shape = RoundedCornerShape(16.dp), shadowElevation = 4.dp) {
                    TextField(
                        value = query, onValueChange = { query = it; preview = null },
                        placeholder = { Text("Ziel oder Adresse suchen") },
                        leadingIcon = { Icon(Icons.Default.Search, null) },
                        trailingIcon = { if (query.isNotEmpty()) IconButton(onClick = { query = ""; results = emptyList() }) { Icon(Icons.Default.Close, "Leeren") } },
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
                            Surface(shape = RoundedCornerShape(12.dp), shadowElevation = 2.dp) {
                                Text("${c.soc!!.toInt()} %" + (c.rangeKm?.let { " · ${it.toInt()} km" } ?: "") + if (c.charging == true) " ⚡" else "",
                                    Modifier.padding(horizontal = 10.dp, vertical = 6.dp), fontWeight = FontWeight.SemiBold)
                            }
                        }
                        FilledTonalIconButton(onClick = { showEv = true }) { Icon(Icons.Default.ElectricCar, "E-Auto") }
                        FilledTonalIconButton(onClick = { showFriends = true }) { Icon(Icons.Default.People, "Freunde") }
                    }
                }
                if (results.isNotEmpty() && preview == null) {
                    Surface(shape = RoundedCornerShape(16.dp), shadowElevation = 4.dp, modifier = Modifier.padding(top = 8.dp)) {
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
            if (showFriends) FriendsScreen(onClose = { showFriends = false })
            if (showEv) EvSettingsDialog(onClose = { showEv = false })
            preview?.let { (dest, routes) ->
                PreviewCard(dest, routes, Modifier.align(Alignment.BottomCenter),
                    onSave = { kind, label -> AppState.favorites.save(kind, label, dest.address, dest.lat, dest.lng) },
                    onStart = { NavigationController.start(routes, dest); preview = null; query = "" },
                    onCancel = { preview = null; adopted = null },
                    charge = { ChargePlanSection(routes.first(), adopted) { plan -> adopt(dest, plan) } })
            }
        }
    }
}

@Composable
private fun PreviewCard(dest: NavigationController.Destination, routes: List<NavigationRoute>, modifier: Modifier,
                        onSave: (String, String) -> Unit, onStart: () -> Unit, onCancel: () -> Unit,
                        charge: @Composable () -> Unit = {}) {
    var saved by remember(dest) { mutableStateOf(false) }
    val r = routes.first().directionsRoute
    Surface(modifier.fillMaxWidth().navigationBarsPadding().padding(12.dp), shape = RoundedCornerShape(20.dp), shadowElevation = 6.dp) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(dest.name, style = MaterialTheme.typography.titleMedium)
            Text("${minutes(r.duration())} · ${km(r.distance())} · Ankunft ${clock(r.duration())}")
            if (!saved) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                AssistChip(onClick = { onSave("home", "Zuhause"); saved = true }, label = { Text("Als Zuhause") })
                AssistChip(onClick = { onSave("work", "Arbeit"); saved = true }, label = { Text("Als Arbeit") })
                AssistChip(onClick = { onSave("other", dest.name); saved = true }, label = { Text("Merken") })
            }
            charge()
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedButton(onClick = onCancel) { Text("Abbrechen") }
                Button(onClick = onStart, modifier = Modifier.weight(1f)) { Text("Los") }
            }
        }
    }
}

@Composable
private fun GuidanceBanner(g: NavigationController.Guidance) {
    Surface(Modifier.fillMaxWidth().statusBarsPadding().padding(12.dp), shape = RoundedCornerShape(20.dp),
        color = MeeterzColors.petrol, contentColor = Color.White, shadowElevation = 6.dp) {
        Column(Modifier.padding(16.dp)) {
            Text(km(g.distanceToTurn), style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold, color = MeeterzColors.mint)
            Text(g.instruction.ifEmpty { g.destination.name }, style = MaterialTheme.typography.titleMedium)
        }
    }
}

@Composable
private fun GuidanceBar(g: NavigationController.Guidance, modifier: Modifier) {
    var muted by remember { mutableStateOf(NavigationController.muted) }
    var showMessage by remember { mutableStateOf(false) }
    if (showMessage) MessageDialog(g, onDismiss = { showMessage = false })
    Surface(modifier.fillMaxWidth().navigationBarsPadding().padding(12.dp), shape = RoundedCornerShape(20.dp), shadowElevation = 6.dp) {
        Row(Modifier.padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("Ankunft ${clock(g.remainingSeconds)}", fontWeight = FontWeight.Bold)
                Text("${minutes(g.remainingSeconds)} · ${km(g.remainingDistance)}", style = MaterialTheme.typography.bodySmall)
                val forecast by ChargeMonitor.forecast.collectAsState()
                forecast?.let { Text(it.text, style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.Bold,
                    color = if (it.low) Color(0xFFD92E36) else MeeterzColors.mintLight) }
            }
            IconButton(onClick = { showMessage = true }) { Icon(Icons.AutoMirrored.Filled.Chat, "Bescheid geben") }
            IconButton(onClick = { muted = !muted; NavigationController.muted = muted }) {
                Icon(if (muted) Icons.AutoMirrored.Filled.VolumeOff else Icons.AutoMirrored.Filled.VolumeUp, "Ton")
            }
            Spacer(Modifier.padding(4.dp))
            Button(onClick = { NavigationController.stop() }) { Text("Beenden") }
        }
    }
}

/** Laden verfolgen (iOS: Ladekarte/CarPlay-Ring): Fortschritt, Leistung, Restzeit, Ziel wählbar */
@Composable
private fun ChargingCard(v: ChargingSession.View, modifier: Modifier) {
    Surface(modifier.padding(24.dp), shape = RoundedCornerShape(20.dp), shadowElevation = 8.dp) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(if (v.done) "Genug geladen" else "Lädt", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
            Text("${Math.round(v.percent)} % → ${Math.round(v.target)} %", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
            LinearProgressIndicator(progress = { v.progress.toFloat() }, modifier = Modifier.fillMaxWidth())
            Text(listOfNotNull(
                v.powerKW.takeIf { it > 0 }?.let { "${it.toInt()} kW" },
                v.remainingSeconds?.takeIf { !v.done }?.let { "noch ${maxOf(1, Math.round(it / 60))} Min." },
            ).joinToString(" · "), style = MaterialTheme.typography.bodySmall)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (t in listOf(80.0, 90.0, 100.0)) AssistChip(onClick = { ChargingSession.setTarget(t) }, label = { Text("Bis ${t.toInt()} %") })
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
        dismissButton = { TextButton(onClick = onDismiss) { Text("Abbrechen") } },
        title = { Text(if (to.isEmpty()) "Bescheid geben" else "An " + to.joinToString(", ") { it.firstName }) },
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
                                Toast.makeText(context, if (sent > 0) "Gesendet: „$text“" else "Nachricht nicht gesendet", Toast.LENGTH_SHORT).show()
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
    return if (m < 60) "$m Min" else "${m / 60} Std ${m % 60} Min"
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

/** Runder Mint-Kreis mit Initialen (wie die Freundes-Pins auf iOS, ohne Profilbild) */
private fun initialsBubble(initials: String): Bitmap {
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
