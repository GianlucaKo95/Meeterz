package de.koeven.meeterz.ui

import de.koeven.meeterz.tr
import androidx.compose.foundation.layout.Box
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Contrast
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.ElectricCar
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.PanTool
import androidx.compose.material.icons.filled.Tune
import de.koeven.meeterz.ev.EvSettings
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import android.speech.tts.TextToSpeech
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.koeven.meeterz.AppState
import de.koeven.meeterz.BuildConfig
import de.koeven.meeterz.Diag
import de.koeven.meeterz.auth.AuthRepository
import de.koeven.meeterz.data.MessagesStore
import de.koeven.meeterz.live.LocationSharingService
import de.koeven.meeterz.nav.NavigationController
import de.koeven.meeterz.nav.RoutePreferences
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Date

private enum class SettingsPage { HOME, SHARING, SOUND, MAP, VOICE, EV, VEHICLE, CUSTOM_VEHICLE, LIVE, NETWORKS, SUGGESTIONS, PRIVACY, DEVELOPER, FAVORITES }

/**
 * Einstellungen wie iOS (FriendsView → Zahnrad): oben Standort teilen und Sound-Pack, dann „App“ mit Unterseiten,
 * „Konto“. Unterseiten als gruppierte Listen mit Fußtexten wie auf iOS (Grouped.kt).
 */
@Composable
fun SettingsScreen(onClose: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val auth by AppState.auth.state.collectAsState()
    val authError by AppState.auth.error.collectAsState()
    val profile = (auth as? AuthRepository.State.Ready)?.profile
    val favorites by AppState.favorites.items.collectAsState()
    val sharingMode by AppState.sharingModeState.collectAsState()
    val appearance by UiPreferences.appearance.collectAsState()
    val mapStyle by UiPreferences.mapStyle.collectAsState()
    val map3d by UiPreferences.map3d.collectAsState()
    val staleHours by UiPreferences.staleHours.collectAsState()
    val car by AppState.vehicle.status.collectAsState()
    val token by AppState.vehicle.token.collectAsState()
    var stack by remember { mutableStateOf(listOf(SettingsPage.HOME)) }
    val page = stack.last()
    fun open(p: SettingsPage) { stack = stack + p }
    fun back() { if (stack.size == 1) onClose() else stack = stack.dropLast(1) }
    var confirmDelete by remember { mutableStateOf(false) }
    var confirmDisconnect by remember { mutableStateOf(false) }
    var showLog by remember { mutableStateOf(false) }
    var autoDelay by remember { mutableStateOf(MessagesStore.autoDelay) }
    var parking by remember { mutableStateOf(de.koeven.meeterz.suggest.Parking.enabled) }
    var voiceOn by remember { mutableStateOf(!NavigationController.muted) }
    var evEnabled by remember { mutableStateOf(EvSettings.enabled) }
    var evVehicle by remember { mutableStateOf(EvSettings.vehicle) }
    var evArrival by remember { mutableStateOf(EvSettings.arrivalPercent) }
    var evMinCharger by remember { mutableStateOf(EvSettings.minAtChargerPercent) }
    var evManual by remember { mutableStateOf(EvSettings.manualPercent) }
    var learned by remember { mutableStateOf(de.koeven.meeterz.suggest.FrequentPlaces.count()) }
    var frequent by remember { mutableStateOf(de.koeven.meeterz.suggest.RouteSuggestions.frequentEnabled) }
    var calendar by remember { mutableStateOf(de.koeven.meeterz.suggest.RouteSuggestions.calendarEnabled &&
        de.koeven.meeterz.suggest.RouteSuggestions.calendarAllowed(context)) }
    val calendarPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        calendar = granted
        de.koeven.meeterz.suggest.RouteSuggestions.calendarEnabled = granted
    }
    LaunchedEffect(page) { if (page == SettingsPage.LIVE || page == SettingsPage.EV) AppState.myId?.let { AppState.vehicle.loadToken(it) } }

    BackHandler { back() }
    if (page == SettingsPage.SOUND) { SoundPackScreen(onClose = { back() }); return }
    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text(tr("Konto wirklich löschen?")) },
            text = { Text(tr("Profil, Freundschaften, Standorte, Routen und Treffen werden endgültig gelöscht.")) },
            confirmButton = {
                TextButton(onClick = {
                    confirmDelete = false
                    scope.launch {
                        LocationSharingService.stop(context)
                        de.koeven.meeterz.data.AvatarStore.removeMine()
                        for (moment in de.koeven.meeterz.sound.SoundMoment.entries) de.koeven.meeterz.sound.SoundStore.removeMine(moment)
                        AppState.endSession()
                        AppState.auth.deleteAccount()
                    }
                }) { Text(tr("Konto und alle Daten löschen"), color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text(tr("Abbrechen")) } }
        )
    }
    if (confirmDisconnect) {
        AlertDialog(
            onDismissRequest = { confirmDisconnect = false },
            title = { Text(tr("Live-Daten trennen?")) },
            text = { Text(tr("Die Geräte-ID wird ungültig, gespeicherte Werte werden gelöscht.")) },
            confirmButton = { TextButton(onClick = { confirmDisconnect = false; scope.launch { AppState.vehicle.disconnect() } }) {
                Text(tr("Trennen"), color = MaterialTheme.colorScheme.error) } },
            dismissButton = { TextButton(onClick = { confirmDisconnect = false }) { Text(tr("Abbrechen")) } }
        )
    }

    val title = when (page) {
        SettingsPage.HOME -> tr("Einstellungen"); SettingsPage.SHARING -> tr("Standort teilen"); SettingsPage.SOUND -> tr("Sound-Pack")
        SettingsPage.MAP -> tr("Karte & Navigation"); SettingsPage.VOICE -> tr("Sprachansagen"); SettingsPage.EV -> tr("E-Auto")
        SettingsPage.VEHICLE -> tr("Fahrzeug"); SettingsPage.CUSTOM_VEHICLE -> tr("Andere"); SettingsPage.LIVE -> tr("Live-Daten"); SettingsPage.NETWORKS -> tr("Ladenetze")
        SettingsPage.SUGGESTIONS -> tr("Routenvorschläge"); SettingsPage.PRIVACY -> tr("Datenschutz")
        SettingsPage.DEVELOPER -> tr("Für Entwickler"); SettingsPage.FAVORITES -> tr("Gespeicherte Orte")
    }

    GroupedPage(title, onBack = { back() }) {
        when (page) {
            SettingsPage.SOUND -> Unit
            SettingsPage.HOME -> {
                Group {
                    NavRow(tr("Standort teilen"), if (profile?.isSharingNow == true) sharingMode.title else tr("Aus"), Icons.Default.LocationOn) { open(SettingsPage.SHARING) }
                    GroupDivider()
                    NavRow(tr("Sound-Pack"), if (de.koeven.meeterz.sound.SoundStore.enabled) tr("An") else tr("Aus"), Icons.Default.GraphicEq) { open(SettingsPage.SOUND) }
                }
                Group(tr("App")) {
                    val appearances = listOf("system", "light", "dark")
                    MenuRow(tr("Darstellung"), listOf(tr("Wie System"), tr("Hell"), tr("Dunkel")), appearances.indexOf(appearance).coerceAtLeast(0),
                        Icons.Default.Contrast) { UiPreferences.setAppearance(appearances[it]) }
                    GroupDivider()
                    NavRow(tr("Karte & Navigation"), icon = Icons.Default.Map) { open(SettingsPage.MAP) }
                    GroupDivider()
                    NavRow(tr("Sprachansagen"), icon = Icons.AutoMirrored.Filled.VolumeUp) { open(SettingsPage.VOICE) }
                    GroupDivider()
                    NavRow(tr("E-Auto"), if (evEnabled) (evVehicle?.fullName ?: tr("An")) else tr("Aus"), Icons.Default.ElectricCar) { open(SettingsPage.EV) }
                    GroupDivider()
                    NavRow(tr("Routenvorschläge"), icon = Icons.Default.History) { open(SettingsPage.SUGGESTIONS) }
                    GroupDivider()
                    NavRow(tr("Datenschutz"), icon = Icons.Default.PanTool) { open(SettingsPage.PRIVACY) }
                    GroupDivider()
                    NavRow(tr("Für Entwickler"), icon = Icons.Default.Build) { open(SettingsPage.DEVELOPER) }
                    GroupDivider()
                    ValueRow(tr("Version"), "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})")
                }
                Group(tr("Konto")) {
                    ActionRow(tr("Abmelden")) {
                        scope.launch { LocationSharingService.stop(context); AppState.endSession(); AppState.auth.signOut() }
                    }
                    GroupDivider()
                    ActionRow(tr("Konto löschen"), destructive = true) { confirmDelete = true }
                }
                authError?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
            }
            SettingsPage.SHARING -> profile?.let { p ->
                val modes = AppState.SharingMode.entries
                Group(tr("Teilen"), footer = sharingMode.explanation + tr(" Mit „Routen verbergen“ sehen Freunde nie, wohin du fährst.")) {
                    ToggleRow(tr("Standort teilen"), p.isSharingNow) { on ->
                        scope.launch { if (on) AppState.shareLocation(sharingMode) else AppState.setSharing(false) }
                    }
                    GroupDivider()
                    ToggleRow(tr("Bei Verspätung automatisch Bescheid geben"), autoDelay) { autoDelay = it; MessagesStore.autoDelay = it }
                    GroupDivider()
                    ToggleRow(tr("Meine Routen für Freunde verbergen"), p.routesHidden) { scope.launch { AppState.setHideRoutes(it) } }
                    GroupDivider()
                    Text(tr("Teilen für"), Modifier.padding(start = 16.dp, top = 10.dp), style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                    SegmentedRow(modes.map { it.title }, modes.indexOf(sharingMode)) { scope.launch { AppState.shareLocation(modes[it]) } }
                }
            }
            SettingsPage.MAP -> {
                val styles = listOf("satellite", "standard")
                Group(footer = tr("Gilt für Handy und Android Auto gleichermaßen und sofort, auch während der Fahrt. Satellit: Luftbild mit 3D-Gebäuden.")) {
                    MenuRow(tr("Karte"), listOf(tr("Satellit"), tr("Klassisch")), styles.indexOf(mapStyle).coerceAtLeast(0)) { UiPreferences.setMapStyle(styles[it]) }
                    GroupDivider()
                    ToggleRow(tr("3D-Ansicht"), map3d) { UiPreferences.setMap3d(it) }
                }
                val hours = listOf(1, 3, 6, 12, 24, 0)
                Group(footer = tr("Freunde, von denen so lange kein neuer Standort kam, verschwinden von der Karte – statt an einem alten Ort zu stehen. Sobald sie wieder teilen, sind sie zurück.")) {
                    MenuRow(tr("Freunde ausblenden nach"), hours.map { if (it == 0) tr("Nie") else tr("%lld Std.", it) },
                        hours.indexOf(staleHours).coerceAtLeast(0)) { UiPreferences.setStaleHours(hours[it]) }
                }
                Group(tr("Routenoptionen (Auto)"), tr("Gilt für alle Routen, auch in Android Auto und für den Ladeplan. Geht ein Ziel nur mit Maut oder Fähre, nimmt Meeterz die normale Route und sagt Bescheid.")) {
                    RoutePreferences.Option.entries.forEachIndexed { i, option ->
                        if (i > 0) GroupDivider()
                        var checked by remember(option) { mutableStateOf(RoutePreferences.isOn(option)) }
                        ToggleRow(option.title, checked) { checked = it; RoutePreferences.set(option, it) }
                    }
                }
                Group {
                    ToggleRow(tr("Geparktes Auto merken"), parking) { parking = it; de.koeven.meeterz.suggest.Parking.enabled = it }
                }
            }
            SettingsPage.VOICE -> Group(footer = tr("Die Stimmen kommen von der Sprachausgabe deines Android-Geräts. Eine natürlichere Stimme lädst du dort unter „Sprachdaten installieren“.")) {
                ToggleRow(tr("Sprachansagen"), voiceOn) { voiceOn = it; NavigationController.muted = !it }
                GroupDivider()
                NavRow(tr("Navigationsstimme")) { runCatching { context.startActivity(Intent("com.android.settings.TTS_SETTINGS")) } }
            }
            SettingsPage.EV -> {
                Group(footer = if (evEnabled) tr("Reicht der Akku nicht bis zum Ziel, schlägt Meeterz Ladesäulen entlang der Route vor (mit 10 % Reserve).") else null) {
                    ToggleRow(tr("E-Auto"), evEnabled) { evEnabled = it; EvSettings.enabled = it }
                    if (evEnabled) {
                        GroupDivider()
                        NavRow(tr("Fahrzeug"), evVehicle?.fullName ?: tr("Auswählen")) { open(SettingsPage.VEHICLE) }
                        GroupDivider()
                        NavRow(tr("Live-Daten"), car?.soc?.takeIf { (car?.ageSeconds ?: Long.MAX_VALUE) < 7 * 86_400 }?.let { "${Math.round(it)} %" }
                            ?: if (token == null) tr("Aus") else tr("Verbunden")) { open(SettingsPage.LIVE) }
                    }
                }
                if (evEnabled) Group(tr("Ladeplanung")) {
                    evVehicle?.let { v -> ValueRow(tr("Reichweite bei 100 %"), tr("ca. %lld km", (v.battery / v.consumption * 100).toInt())); GroupDivider() }
                    StepperRow(tr("Ankunft mit mindestens"), "${evArrival.toInt()} %", evArrival > 5, evArrival < 60,
                        { evArrival -= 5; EvSettings.arrivalPercent = evArrival }, { evArrival += 5; EvSettings.arrivalPercent = evArrival })
                    GroupDivider()
                    StepperRow(tr("An der Ladesäule mindestens"), "${evMinCharger.toInt()} %", evMinCharger > 5, evMinCharger < 30,
                        { evMinCharger -= 5; EvSettings.minAtChargerPercent = evMinCharger }, { evMinCharger += 5; EvSettings.minAtChargerPercent = evMinCharger })
                    if (EvSettings.liveSoc == null) {
                        GroupDivider()
                        StepperRow(tr("Akkustand jetzt (ohne Live-Daten)"), "${evManual.toInt()} %", evManual > 5, evManual < 100,
                            { evManual -= 5; EvSettings.manualPercent = evManual }, { evManual += 5; EvSettings.manualPercent = evManual })
                    }
                    GroupDivider()
                    NavRow(tr("Ladenetze"), de.koeven.meeterz.ev.ChargeNetworks.summary) { open(SettingsPage.NETWORKS) }
                }
            }
            SettingsPage.VEHICLE -> {
                var search by remember { mutableStateOf("") }
                val all = remember { EvSettings.vehicles() }
                OutlinedTextField(search, { search = it }, placeholder = { Text(tr("Marke oder Modell")) }, singleLine = true, modifier = Modifier.fillMaxWidth())
                if (search.isBlank()) Group(footer = tr("Dein Auto fehlt? Batterie, Verbrauch und Ladeleistung selbst eintragen.")) {
                    NavRow(tr("Andere"), null, Icons.Default.Tune, checked = evVehicle?.isCustom == true) { open(SettingsPage.CUSTOM_VEHICLE) }
                }
                val matches = all.filter { v -> search.split(" ").filter { it.isNotBlank() }.all { v.fullName.contains(it, ignoreCase = true) } }.take(80)
                Group(footer = de.koeven.meeterz.ev.EvData.ATTRIBUTION + tr(" · Fahrzeugdaten: Open EV Data (github.com/KilowattApp/open-ev-data). Werte sind Durchschnittswerte; Meeterz lernt mit der Zeit aus deinen Fahrten.")) {
                    matches.forEachIndexed { i, v ->
                        if (i > 0) GroupDivider()
                        Row(Modifier.fillMaxWidth().clickable { evVehicle = v; EvSettings.vehicle = v; back() }.padding(horizontal = 16.dp, vertical = 10.dp),
                            verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text(v.fullName)
                                Text("${v.battery} kWh · ${v.consumption} kWh/100 km" + (v.dcMax?.let { " · ${it.toInt()} kW DC" } ?: ""),
                                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            if (v.id == evVehicle?.id) Icon(Icons.Default.Check, null, tint = MaterialTheme.colorScheme.primary)
                        }
                    }
                }
            }
            SettingsPage.CUSTOM_VEHICLE -> {
                val current = evVehicle
                var battery by remember { mutableStateOf(current?.battery ?: 60.0) }
                var consumption by remember { mutableStateOf(current?.consumption ?: 18.0) }
                var dcMax by remember { mutableStateOf(current?.dcMax ?: 100.0) }
                Group(footer = tr("Reichweite bei 100 %%: ca. %lld km", (battery / consumption * 100).toInt())) {
                    StepperRow(tr("Nutzbare Batterie"), "${battery.toInt()} kWh", battery > 10, battery < 200, { battery -= 1 }, { battery += 1 })
                    GroupDivider()
                    StepperRow(tr("Verbrauch"), String.format(java.util.Locale.getDefault(), "%.1f kWh/100 km", consumption),
                        consumption > 10, consumption < 40, { consumption -= 0.5 }, { consumption += 0.5 })
                    GroupDivider()
                    StepperRow(tr("Max. Schnellladen (DC)"), "${dcMax.toInt()} kW", dcMax > 20, dcMax < 350, { dcMax -= 5 }, { dcMax += 5 })
                }
                Group {
                    ActionRow(tr("Übernehmen")) {
                        val v = de.koeven.meeterz.ev.EvVehicle.custom(battery, consumption, dcMax)
                        evVehicle = v; EvSettings.vehicle = v
                        stack = stack.dropLast(2)   // zurück zu „E-Auto“ (wie iOS)
                    }
                }
            }
            SettingsPage.LIVE -> {
                car?.let { c ->
                    Group(tr("Aktuell")) {
                        c.soc?.let { ValueRow(tr("Akkustand"), "${Math.round(it)} %"); GroupDivider() }
                        c.rangeKm?.let { ValueRow(tr("Reichweite laut Auto"), "${it.toInt()} km"); GroupDivider() }
                        if (c.charging == true) { ValueRow(tr("Lädt"), c.powerKw?.let { "${Math.abs(Math.round(it))} kW" } ?: tr("ja")); GroupDivider() }
                        c.extTemp?.let { ValueRow(tr("Außentemperatur"), "${Math.round(it)} °C"); GroupDivider() }
                        ValueRow(tr("Stand"), android.text.format.DateUtils.getRelativeTimeSpanString(c.measuredAt * 1000).toString())
                    }
                }
                evVehicle?.let { v ->
                    val buckets = de.koeven.meeterz.ev.ConsumptionLearner.buckets(v)
                    Group(tr("Dein Verbrauch"), tr("Gelernt aus deinen Fahrten mit Live-Daten. Ab %lld km je Bereich rechnet die Ladeplanung damit statt mit dem Durchschnittswert (%@ kWh/100 km).",
                        de.koeven.meeterz.ev.ConsumptionLearner.MIN_KM.toInt(), String.format("%.1f", v.consumption))) {
                        buckets.forEachIndexed { i, b ->
                            if (i > 0) GroupDivider()
                            ValueRow(de.koeven.meeterz.ev.ConsumptionLearner.bandNames[i],
                                b.per100?.let { String.format("%.1f kWh/100 km · %.0f km", it, b.km) } ?: tr("noch keine Daten"))
                        }
                    }
                }
                val clipboard = androidx.compose.ui.platform.LocalClipboardManager.current
                val t = token
                if (t != null) {
                    Group(tr("Im Add-on eintragen"), tr("Home Assistant → Add-ons → „MG to ABRP Bridge“ → Konfiguration: „meeterz_url“ und „meeterz_device_id“ einfügen und das Add-on neu starten. Beim Fahren kommt etwa alle 30 Sekunden ein neuer Wert, geparkt seltener.")) {
                        for ((label, value) in listOf(tr("Server-Adresse") to de.koeven.meeterz.data.VehicleStore.telemetryUrl, tr("Geräte-ID") to t)) {
                            if (label != tr("Server-Adresse")) GroupDivider()
                            Column(Modifier.fillMaxWidth().clickable {
                                clipboard.setText(androidx.compose.ui.text.AnnotatedString(value))
                                android.widget.Toast.makeText(context, tr("%@ kopiert", label), android.widget.Toast.LENGTH_SHORT).show()
                            }.padding(horizontal = 16.dp, vertical = 10.dp)) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text(label, Modifier.weight(1f))
                                    Icon(Icons.Default.ContentCopy, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(start = 8.dp))
                                }
                                Text(value, fontFamily = FontFamily.Monospace, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                    Group(footer = tr("Eine neue Geräte-ID macht die alte ungültig.")) {
                        ActionRow(tr("Neue Geräte-ID erzeugen")) { scope.launch { AppState.vehicle.connect() } }
                        GroupDivider()
                        ActionRow(tr("Live-Daten trennen"), destructive = true) { confirmDisconnect = true }
                    }
                } else {
                    Group(footer = tr("Meeterz übernimmt Akkustand, Reichweite und Ladezustand live aus deinem Auto – über das Home-Assistant-Add-on „MG to ABRP Bridge“ (iSMART). Damit entfällt die Akku-Eingabe, und die Ladeplanung rechnet mit echten Werten.")) {
                        ActionRow(tr("Live-Daten verbinden")) { scope.launch { AppState.vehicle.connect() } }
                    }
                }
            }
            SettingsPage.NETWORKS -> {
                val all = remember { de.koeven.meeterz.ev.ChargeNetworks.all(context) }
                var search by remember { mutableStateOf("") }
                var version by remember { mutableStateOf(0) }
                Text(tr("Gemiedene Netze plant Meeterz nie als Ladestopp ein. Bevorzugte nimmt es, wenn sie auf der Strecke liegen – auch wenn ein anderer Stopp ein paar Minuten schneller wäre."),
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                OutlinedTextField(search, { search = it }, placeholder = { Text(tr("Netz suchen")) }, singleLine = true, modifier = Modifier.fillMaxWidth())
                val shown = all.filter { search.isBlank() || it.name.contains(search, ignoreCase = true) }
                Group {
                    shown.forEachIndexed { i, n ->
                        if (i > 0) GroupDivider()
                        val values = listOf<String?>(null, "preferred", "avoided")
                        val pref = if (version >= 0) de.koeven.meeterz.ev.ChargeNetworks.preference(n.id) else null
                        MenuRow(n.name, listOf(tr("Egal"), tr("Bevorzugt"), tr("Meiden")), values.indexOf(pref).coerceAtLeast(0)) {
                            de.koeven.meeterz.ev.ChargeNetworks.set(n.id, values[it]); version++
                        }
                    }
                }
            }
            SettingsPage.SUGGESTIONS -> {
                Group(footer = tr("Wie bei Google Maps schlägt Android Auto beim Einsteigen ein Ziel vor: einen Termin mit Ort, zu dem du bald losfahren musst, oder einen Ort, den du um diese Zeit oft ansteuerst. Die gelernten Orte bleiben nur auf diesem Gerät.")) {
                    ToggleRow(tr("Häufige Ziele vorschlagen"), frequent) { frequent = it; de.koeven.meeterz.suggest.RouteSuggestions.frequentEnabled = it }
                    GroupDivider()
                    ToggleRow(tr("Termine aus dem Kalender vorschlagen"), calendar) { on ->
                        if (!on) { calendar = false; de.koeven.meeterz.suggest.RouteSuggestions.calendarEnabled = false }
                        else if (de.koeven.meeterz.suggest.RouteSuggestions.calendarAllowed(context)) {
                            calendar = true; de.koeven.meeterz.suggest.RouteSuggestions.calendarEnabled = true
                        } else calendarPermission.launch(android.Manifest.permission.READ_CALENDAR)
                    }
                }
                // Welche Kalender zählen (wie iOS „Kalender für Vorschläge“)
                if (calendar) {
                    val calendars = remember(calendar) { de.koeven.meeterz.suggest.RouteSuggestions.allCalendars(context) }
                    var choice by remember { mutableStateOf(mapOf<Long, Boolean>()) }
                    if (calendars.isNotEmpty()) Group(header = tr("Kalender für Vorschläge"),
                        footer = tr("Nur Termine aus den eingeschalteten Kalendern werden vorgeschlagen.")) {
                        calendars.forEachIndexed { i, cal ->
                            if (i > 0) GroupDivider()
                            ToggleRow(cal.name, choice[cal.id] ?: de.koeven.meeterz.suggest.RouteSuggestions.isUsed(cal), subtitle = cal.account) { on ->
                                choice = choice + (cal.id to on)
                                de.koeven.meeterz.suggest.RouteSuggestions.setUsed(context, cal, on)
                            }
                        }
                    }
                }
                if (learned > 0) Group {
                    ActionRow(tr("Gelernte Orte löschen (%lld)", learned), destructive = true) {
                        de.koeven.meeterz.suggest.FrequentPlaces.clear(); learned = 0
                    }
                }
            }
            SettingsPage.PRIVACY -> Group(footer = tr("Standort, Mitteilungen, Kalender und Mikrofon verwaltest du in den Android-Einstellungen der App.")) {
                ActionRow(tr("Datenschutzerklärung")) {
                    context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://gianlucako95.github.io/Meeterz/datenschutz")))
                }
                GroupDivider()
                ActionRow(tr("Berechtigungen in den Android-Einstellungen")) {
                    context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}")))
                }
            }
            SettingsPage.DEVELOPER -> Group(tr("Diagnose")) {
                NavRow(if (showLog) tr("Protokoll ausblenden") else tr("Protokoll anzeigen")) { showLog = !showLog }
                if (showLog) Text(Diag.text.takeLast(20_000).ifEmpty { tr("Noch keine Einträge.") }, Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                    fontFamily = FontFamily.Monospace, fontSize = 10.sp)
                GroupDivider()
                ActionRow(tr("Teilen")) {
                    val send = Intent(Intent.ACTION_SEND).setType("text/plain")
                        .putExtra(Intent.EXTRA_SUBJECT, tr("Meeterz-Protokoll (Android)")).putExtra(Intent.EXTRA_TEXT, Diag.text)
                    context.startActivity(Intent.createChooser(send, tr("Protokoll teilen")))
                }
                GroupDivider()
                ActionRow(tr("Leeren"), destructive = true) { Diag.clear(); showLog = false }
            }
            SettingsPage.FAVORITES -> Group {
                favorites.forEachIndexed { i, fav ->
                    if (i > 0) GroupDivider()
                    Row(Modifier.padding(start = 16.dp, end = 4.dp, top = 6.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(fav.label)
                            fav.address?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                        }
                        TextButton(onClick = { AppState.favorites.remove(fav.id) }) { Text(tr("Löschen"), color = MaterialTheme.colorScheme.error) }
                    }
                }
            }
        }
    }
}

/** „Teilst live bis 18:30“, „Inkognito“, „Teilen pausiert“ */
fun sharingLabel(p: de.koeven.meeterz.data.Profile?): String {
    if (p == null) return tr("Nicht verfügbar")
    val time = { i: java.time.Instant -> DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(i.toEpochMilli())) }
    if (p.isIncognito) return if (p.isIncognitoIndefinitely) tr("Inkognito") else tr("Inkognito bis %@", time(p.incognitoUntilInstant!!))
    if (!p.isSharingNow) return tr("Teilen pausiert")
    return p.sharingUntilInstant?.let { tr("Teilst live bis %@", time(it)) } ?: tr("Teilst live")
}
