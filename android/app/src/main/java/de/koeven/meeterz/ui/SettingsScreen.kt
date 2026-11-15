package de.koeven.meeterz.ui

import de.koeven.meeterz.tr
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import android.speech.tts.TextToSpeech
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.horizontalScroll
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

private enum class SettingsPage(val title: String) {
    HOME("Einstellungen"), SHARING("Standort teilen"), APPEARANCE("Darstellung"),
    MAP("Karte & Navigation"), VOICE("Sprachansagen"), EV("E-Auto"),
    SUGGESTIONS("Routenvorschläge"), PRIVACY("Datenschutz"),
    DEVELOPER("Für Entwickler"), ACCOUNT("Konto"), FAVORITES("Gespeicherte Orte")
}

/** Android-Einstellungsstruktur an iOS angeglichen: Hauptmenü, gruppierte Unterseiten, Konto. */
@Composable
fun SettingsScreen(onClose: () -> Unit) {
    BackHandler { /* below: the current page owns the back action */ }
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val auth by AppState.auth.state.collectAsState()
    val profile = (auth as? AuthRepository.State.Ready)?.profile
    val favorites by AppState.favorites.items.collectAsState()
    val appearance by UiPreferences.appearance.collectAsState()
    val mapStyle by UiPreferences.mapStyle.collectAsState()
    val map3d by UiPreferences.map3d.collectAsState()
    val staleHours by UiPreferences.staleHours.collectAsState()
    var page by remember { mutableStateOf(SettingsPage.HOME) }
    var showEvDialog by remember { mutableStateOf(false) }
    var showLog by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    var autoDelay by remember { mutableStateOf(MessagesStore.autoDelay) }
    var parking by remember { mutableStateOf(de.koeven.meeterz.suggest.Parking.enabled) }
    var frequent by remember { mutableStateOf(de.koeven.meeterz.suggest.RouteSuggestions.frequentEnabled) }
    var calendar by remember { mutableStateOf(de.koeven.meeterz.suggest.RouteSuggestions.calendarEnabled &&
        de.koeven.meeterz.suggest.RouteSuggestions.calendarAllowed(context)) }
    val calendarPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        calendar = granted
        de.koeven.meeterz.suggest.RouteSuggestions.calendarEnabled = granted
    }

    BackHandler(enabled = page != SettingsPage.HOME) { page = SettingsPage.HOME }
    if (showEvDialog) EvSettingsDialog(onClose = { showEvDialog = false })
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
                        AppState.endSession()
                        AppState.auth.deleteAccount()
                    }
                }) { Text(tr("Konto und alle Daten löschen"), color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text(tr("Abbrechen")) } }
        )
    }

    Surface(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().statusBarsPadding()) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                TextButton(onClick = { if (page == SettingsPage.HOME) onClose() else page = SettingsPage.HOME }) {
                    Text(if (page == SettingsPage.HOME) tr("Schließen") else "‹  " + tr("Einstellungen"))
                }
                Spacer(Modifier.weight(1f))
                Text(page.title, style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(end = 12.dp))
            }
            HorizontalDivider()
            Column(
                Modifier.weight(1f).navigationBarsPadding().verticalScroll(rememberScrollState())
                    .padding(horizontal = 18.dp, vertical = 14.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                when (page) {
                    SettingsPage.HOME -> {
                        profile?.let { p ->
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                                AvatarEditor(p)
                                Column {
                                    Text(p.displayName, style = MaterialTheme.typography.titleMedium)
                                    Text("@\${p.handle}", style = MaterialTheme.typography.bodySmall)
                                }
                            }
                            HorizontalDivider()
                        }
                        SettingsSectionTitle(tr("Persönlich"))
                        SettingsNavRow(tr("Standort teilen"), sharingLabel(profile), "›") { page = SettingsPage.SHARING }
                        SettingsNavRow(tr("Sound-Pack"), if (de.koeven.meeterz.sound.SoundStore.enabled) tr("An") else tr("Aus"), "›") {
                            SoundPackScreen(onClose = { page = SettingsPage.HOME })
                        }
                        SettingsSectionTitle(tr("App"))
                        SettingsNavRow(tr("Darstellung"), when (appearance) {
                            "dark" -> tr("Dunkel"); "light" -> tr("Hell"); else -> tr("Wie System")
                        }, "›") { page = SettingsPage.APPEARANCE }
                        SettingsNavRow(tr("Karte & Navigation"), if (mapStyle == "satellite") tr("Satellit") else tr("Klassisch"), "›") { page = SettingsPage.MAP }
                        SettingsNavRow(tr("Sprachansagen"), if (NavigationController.muted) tr("Aus") else tr("An"), "›") { page = SettingsPage.VOICE }
                        SettingsNavRow(tr("E-Auto"), if (de.koeven.meeterz.ev.EvSettings.enabled) tr("An") else tr("Aus"), "›") { page = SettingsPage.EV }
                        SettingsNavRow(tr("Routenvorschläge"), if (frequent || calendar) tr("Aktiv") else tr("Aus"), "›") { page = SettingsPage.SUGGESTIONS }
                        SettingsNavRow(tr("Datenschutz"), "", "›") { page = SettingsPage.PRIVACY }
                        SettingsNavRow(tr("Für Entwickler"), "", "›") { page = SettingsPage.DEVELOPER }
                        SettingsNavRow(tr("Version"), BuildConfig.VERSION_NAME, "")
                        SettingsSectionTitle(tr("Konto"))
                        SettingsNavRow(tr("Kontoverwaltung"), tr("Abmelden und Konto löschen"), "›") { page = SettingsPage.ACCOUNT }
                        if (favorites.isNotEmpty()) {
                            SettingsSectionTitle(tr("Gespeicherte Orte"))
                            SettingsNavRow(tr("Favoriten verwalten"), "\${favorites.size}", "›") { page = SettingsPage.FAVORITES }
                        }
                    }
                    SettingsPage.SHARING -> {
                        profile?.let { p ->
                            SettingsSectionTitle(tr("Standortfreigabe"))
                            Text(sharingLabel(p), style = MaterialTheme.typography.bodySmall)
                            for (mode in AppState.SharingMode.entries) {
                                SettingsChoiceRow(mode.title, AppState.sharingMode == mode && p.isSharingNow) {
                                    scope.launch { AppState.shareLocation(mode) }
                                }
                            }
                            OutlinedButton(onClick = { scope.launch { AppState.setSharing(false) } }, Modifier.fillMaxWidth()) {
                                Text(tr("Teilen pausieren"))
                            }
                            HorizontalDivider()
                            SettingsSectionTitle(tr("Inkognito"))
                            Text(tr("Freunde sehen weder deinen Standort noch deine Route – und erfahren nicht, dass du inkognito bist."),
                                style = MaterialTheme.typography.bodySmall)
                            if (p.isIncognito) {
                                OutlinedButton(onClick = { scope.launch { AppState.stopIncognito() } }, Modifier.fillMaxWidth()) {
                                    Text(tr("Inkognito beenden"))
                                }
                            } else {
                                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    for ((label, seconds) in listOf(tr("15 Min.") to 900L, tr("1 Std.") to 3600L, tr("3 Std.") to 10800L, tr("Unbegrenzt") to null)) {
                                        OutlinedButton(onClick = { scope.launch { AppState.startIncognito(seconds) } }) { Text(label) }
                                    }
                                }
                            }
                            HorizontalDivider()
                            SettingsSwitch(tr("Routen verbergen"), tr("Freunde sehen deinen Standort, aber nicht, wohin du fährst"),
                                p.routesHidden) { scope.launch { AppState.setHideRoutes(it) } }
                            SettingsSwitch(tr("Bei Verspätung automatisch Bescheid geben"),
                                tr("Ab 5 Minuten später an alle, die du am Ziel triffst"), autoDelay) {
                                autoDelay = it; MessagesStore.autoDelay = it
                            }
                        }
                    }
                    SettingsPage.APPEARANCE -> {
                        SettingsSectionTitle(tr("App-Darstellung"))
                        SettingsChoiceRow(tr("Wie System"), appearance == "system") { UiPreferences.setAppearance("system") }
                        SettingsChoiceRow(tr("Hell"), appearance == "light") { UiPreferences.setAppearance("light") }
                        SettingsChoiceRow(tr("Dunkel"), appearance == "dark") { UiPreferences.setAppearance("dark") }
                    }
                    SettingsPage.MAP -> {
                        SettingsSectionTitle(tr("Kartenansicht"))
                        SettingsChoiceRow(tr("Klassische Karte"), mapStyle == "standard") { UiPreferences.setMapStyle("standard") }
                        SettingsChoiceRow(tr("Satellit"), mapStyle == "satellite") { UiPreferences.setMapStyle("satellite") }
                        Text(tr("Apple Flyover ist nur auf iOS verfügbar."), style = MaterialTheme.typography.bodySmall)
                        SettingsSwitch(tr("3D-Ansicht"), tr("Karte mit geneigter Perspektive darstellen"), map3d) { UiPreferences.setMap3d(it) }
                        HorizontalDivider()
                        SettingsSectionTitle(tr("Freunde"))
                        Text(tr("Freunde ohne aktuelle Standortdaten nach dieser Zeit von der Karte ausblenden."), style = MaterialTheme.typography.bodySmall)
                        for (hours in listOf(1, 3, 6, 12, 24, 0)) {
                            SettingsChoiceRow(if (hours == 0) tr("Nie") else tr("\${hours} Std."), staleHours == hours) {
                                UiPreferences.setStaleHours(hours)
                            }
                        }
                        HorizontalDivider()
                        SettingsSectionTitle(tr("Routenoptionen (Auto)"))
                        Text(tr("Gilt für jede Route, auch für Neuberechnungen unterwegs."), style = MaterialTheme.typography.bodySmall)
                        for (option in RoutePreferences.Option.entries) {
                            var checked by remember(option) { mutableStateOf(RoutePreferences.isOn(option)) }
                            SettingsSwitch(option.title, option.shortTitle, checked) {
                                checked = it; RoutePreferences.set(option, it)
                            }
                        }
                        HorizontalDivider()
                        SettingsSectionTitle(tr("Parken"))
                        SettingsSwitch(tr("Geparktes Auto merken"),
                            tr("Beim Trennen von Android Auto und wenn das Auto als geparkt erkannt wird"), parking) {
                            parking = it; de.koeven.meeterz.suggest.Parking.enabled = it
                        }
                    }
                    SettingsPage.VOICE -> {
                        SettingsSectionTitle(tr("Sprachansagen"))
                        SettingsSwitch(tr("Sprachansagen"), tr("Abbiegehinweise während der Navigation vorlesen"),
                            !NavigationController.muted) { NavigationController.muted = !it }
                        OutlinedButton(onClick = {
                            runCatching { context.startActivity(Intent(TextToSpeech.Engine.ACTION_TTS_SETTINGS)) }
                        }, Modifier.fillMaxWidth()) { Text(tr("Navigationsstimme und Sprache auswählen")) }
                        Text(tr("Die verfügbaren Stimmen und Sprachen werden von der auf deinem Android-Gerät installierten Sprachengine bereitgestellt."),
                            style = MaterialTheme.typography.bodySmall)
                    }
                    SettingsPage.EV -> {
                        SettingsSectionTitle(tr("E-Auto und Ladeplanung"))
                        Text(tr("Fahrzeug, Akkustand, Ladeplanung und bevorzugte Ladenetze verwalten."),
                            style = MaterialTheme.typography.bodySmall)
                        OutlinedButton(onClick = { showEvDialog = true }, Modifier.fillMaxWidth()) {
                            Text(tr("E-Auto-Einstellungen öffnen"))
                        }
                    }
                    SettingsPage.SUGGESTIONS -> {
                        SettingsSectionTitle(tr("Vorschläge"))
                        SettingsSwitch(tr("Häufige Ziele vorschlagen"), tr("Lernt aus deinen Aufenthalten – bleibt auf dem Gerät"),
                            frequent) { frequent = it; de.koeven.meeterz.suggest.RouteSuggestions.frequentEnabled = it }
                        SettingsSwitch(tr("Termine mit Ort vorschlagen"), tr("Aus deinem Kalender, rechtzeitig vor der Abfahrt"),
                            calendar) { on ->
                            if (!on) {
                                calendar = false
                                de.koeven.meeterz.suggest.RouteSuggestions.calendarEnabled = false
                            } else if (de.koeven.meeterz.suggest.RouteSuggestions.calendarAllowed(context)) {
                                calendar = true
                                de.koeven.meeterz.suggest.RouteSuggestions.calendarEnabled = true
                            } else calendarPermission.launch(android.Manifest.permission.READ_CALENDAR)
                        }
                        TextButton(onClick = { de.koeven.meeterz.suggest.FrequentPlaces.clear() }) {
                            Text(tr("Gelernte Orte löschen"))
                        }
                    }
                    SettingsPage.PRIVACY -> {
                        SettingsSectionTitle(tr("Datenschutz und Berechtigungen"))
                        Text(tr("Standort, Mitteilungen, Kalender und Mikrofon werden über die Android-App-Berechtigungen verwaltet."),
                            style = MaterialTheme.typography.bodySmall)
                        OutlinedButton(onClick = {
                            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:\${context.packageName}"))
                            context.startActivity(intent)
                        }, Modifier.fillMaxWidth()) { Text(tr("Berechtigungen und App-Informationen öffnen")) }
                        Text(tr("Die iOS-Option zur Mapbox-Telemetrie ist in der Android-App derzeit nicht separat verfügbar."),
                            style = MaterialTheme.typography.bodySmall)
                    }
                    SettingsPage.DEVELOPER -> {
                        SettingsSectionTitle(tr("Diagnose"))
                        Text(tr("Hilft, Fehler von unterwegs zu finden. Enthält Ansagen und Ereignisse, keine Nachrichten."),
                            style = MaterialTheme.typography.bodySmall)
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            OutlinedButton(onClick = { showLog = !showLog }) { Text(if (showLog) tr("Ausblenden") else tr("Protokoll anzeigen")) }
                            OutlinedButton(onClick = {
                                val send = Intent(Intent.ACTION_SEND).setType("text/plain")
                                    .putExtra(Intent.EXTRA_SUBJECT, tr("Meeterz-Protokoll (Android)"))
                                    .putExtra(Intent.EXTRA_TEXT, Diag.text)
                                context.startActivity(Intent.createChooser(send, tr("Protokoll teilen")))
                            }) { Text(tr("Teilen")) }
                            TextButton(onClick = { Diag.clear(); showLog = false }) { Text(tr("Leeren")) }
                        }
                        if (showLog) {
                            Text(Diag.text.takeLast(20_000).ifEmpty { tr("(leer)") },
                                fontFamily = FontFamily.Monospace, fontSize = 10.sp)
                        }
                    }
                    SettingsPage.ACCOUNT -> {
                        SettingsSectionTitle(tr("Konto"))
                        OutlinedButton(onClick = {
                            scope.launch {
                                LocationSharingService.stop(context)
                                AppState.endSession()
                                AppState.auth.signOut()
                            }
                        }, Modifier.fillMaxWidth()) { Text(tr("Abmelden")) }
                        OutlinedButton(onClick = { confirmDelete = true }, Modifier.fillMaxWidth()) {
                            Text(tr("Konto und alle Daten löschen"), color = MaterialTheme.colorScheme.error)
                        }
                    }
                    SettingsPage.FAVORITES -> {
                        for (fav in favorites) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Column(Modifier.weight(1f)) {
                                    Text(fav.label, fontWeight = FontWeight.SemiBold)
                                    fav.address?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                                }
                                TextButton(onClick = { AppState.favorites.remove(fav.id) }) { Text(tr("Löschen")) }
                            }
                            HorizontalDivider()
                        }
                    }
                }
                Spacer(Modifier.height(12.dp))
            }
        }
    }
}

@Composable
private fun SettingsSectionTitle(title: String) {
    Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold,
        color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(top = 8.dp))
}

@Composable
private fun SettingsNavRow(title: String, value: String, arrow: String, onClick: () -> Unit) {
    TextButton(onClick = onClick, modifier = Modifier.fillMaxWidth()) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(title, color = MaterialTheme.colorScheme.onSurface, modifier = Modifier.weight(1f))
            if (value.isNotBlank()) Text(value, color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodySmall)
            if (arrow.isNotBlank()) Text(arrow, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(start = 8.dp))
        }
    }
}

@Composable
private fun SettingsChoiceRow(title: String, selected: Boolean, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        RadioButton(selected = selected, onClick = onClick)
        Text(title, modifier = Modifier.weight(1f))
    }
}

@Composable
private fun SettingsSwitch(title: String, subtitle: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f).padding(end = 12.dp)) {
            Text(title, fontWeight = FontWeight.SemiBold)
            Text(subtitle, style = MaterialTheme.typography.bodySmall)
        }
        Switch(checked = checked, onCheckedChange = onChange)
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
