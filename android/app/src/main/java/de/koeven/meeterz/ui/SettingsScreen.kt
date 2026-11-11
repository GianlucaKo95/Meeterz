package de.koeven.meeterz.ui

import de.koeven.meeterz.tr
import android.content.Intent
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
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
import de.koeven.meeterz.Diag
import de.koeven.meeterz.auth.AuthRepository
import de.koeven.meeterz.data.MessagesStore
import de.koeven.meeterz.live.LocationSharingService
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Date

/** Einstellungen (iOS: Einstellungen in der Freunde-Ansicht): Teilen, Inkognito, E-Auto, Sound-Pack, Protokoll */
@Composable
fun SettingsScreen(onClose: () -> Unit) {
    BackHandler(onBack = onClose)
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val auth by AppState.auth.state.collectAsState()
    val profile = (auth as? AuthRepository.State.Ready)?.profile
    val favorites by AppState.favorites.items.collectAsState()
    var showSounds by remember { mutableStateOf(false) }
    var showEv by remember { mutableStateOf(false) }
    var showLog by remember { mutableStateOf(false) }
    var autoDelay by remember { mutableStateOf(MessagesStore.autoDelay) }
    if (showSounds) { SoundPackScreen(onClose = { showSounds = false }); return }
    if (showEv) EvSettingsDialog(onClose = { showEv = false })

    Surface(Modifier.fillMaxSize()) {
        Column(Modifier.statusBarsPadding()) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, tr("Zurück")) }
                Text(tr("Einstellungen"), style = MaterialTheme.typography.titleLarge)
            }
            LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                profile?.let { p ->
                    item {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            AvatarEditor(p)
                            Column {
                                Text(p.displayName, style = MaterialTheme.typography.titleMedium)
                                Text("@${p.handle}", style = MaterialTheme.typography.bodySmall)
                            }
                        }
                        HorizontalDivider(Modifier.padding(top = 8.dp))
                    }
                    item {
                        Text(tr("Standort teilen"), fontWeight = FontWeight.SemiBold)
                        Text(sharingLabel(p), style = MaterialTheme.typography.bodySmall)
                        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            for (mode in AppState.SharingMode.entries) {
                                FilterChip(selected = p.isSharingNow && AppState.sharingMode == mode,
                                    onClick = { scope.launch { AppState.shareLocation(mode) } }, label = { Text(mode.title) })
                            }
                        }
                        if (p.isSharingNow) TextButton(onClick = { scope.launch { AppState.setSharing(false) } }) { Text(tr("Teilen pausieren")) }
                    }
                    item {
                        Text(tr("Inkognito"), fontWeight = FontWeight.SemiBold)
                        Text(tr("Freunde sehen weder deinen Standort noch deine Route – und erfahren nicht, dass du inkognito bist."),
                            style = MaterialTheme.typography.bodySmall)
                        if (p.isIncognito) {
                            OutlinedButton(onClick = { scope.launch { AppState.stopIncognito() } }) { Text(tr("Inkognito beenden")) }
                        } else {
                            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                for ((label, seconds) in listOf(tr("15 Min.") to 15 * 60L, tr("1 Std.") to 3600L, tr("3 Std.") to 3 * 3600L, tr("Bis ich es ausschalte") to null)) {
                                    FilterChip(selected = false, onClick = { scope.launch { AppState.startIncognito(seconds) } }, label = { Text(label) })
                                }
                            }
                        }
                    }
                    item {
                        SwitchRow(tr("Routen verbergen"), tr("Freunde sehen deinen Standort, aber nicht, wohin du fährst"), p.routesHidden) {
                            scope.launch { AppState.setHideRoutes(it) }
                        }
                        SwitchRow(tr("Bei Verspätung automatisch Bescheid geben"), tr("Ab 5 Minuten später an alle, die du am Ziel triffst"), autoDelay) {
                            autoDelay = it; MessagesStore.autoDelay = it
                        }
                        HorizontalDivider()
                    }
                }
                item {
                    Text(tr("Vorschläge und Parken"), fontWeight = FontWeight.SemiBold)
                    var parking by remember { mutableStateOf(de.koeven.meeterz.suggest.Parking.enabled) }
                    SwitchRow(tr("Geparktes Auto merken"), tr("Beim Trennen von Android Auto und wenn das Auto „geparkt“ meldet"), parking) {
                        parking = it; de.koeven.meeterz.suggest.Parking.enabled = it
                    }
                    var frequent by remember { mutableStateOf(de.koeven.meeterz.suggest.RouteSuggestions.frequentEnabled) }
                    SwitchRow(tr("Häufige Ziele vorschlagen"), tr("Lernt aus deinen Aufenthalten – bleibt auf dem Gerät"), frequent) {
                        frequent = it; de.koeven.meeterz.suggest.RouteSuggestions.frequentEnabled = it
                    }
                    var calendar by remember { mutableStateOf(de.koeven.meeterz.suggest.RouteSuggestions.calendarEnabled &&
                        de.koeven.meeterz.suggest.RouteSuggestions.calendarAllowed(context)) }
                    val calendarPermission = androidx.activity.compose.rememberLauncherForActivityResult(
                        androidx.activity.result.contract.ActivityResultContracts.RequestPermission()) { granted ->
                        calendar = granted; de.koeven.meeterz.suggest.RouteSuggestions.calendarEnabled = granted
                    }
                    SwitchRow(tr("Termine mit Ort vorschlagen"), tr("Aus deinem Kalender, rechtzeitig vor der Abfahrt"), calendar) { on ->
                        if (!on) { calendar = false; de.koeven.meeterz.suggest.RouteSuggestions.calendarEnabled = false }
                        else if (de.koeven.meeterz.suggest.RouteSuggestions.calendarAllowed(context)) { calendar = true; de.koeven.meeterz.suggest.RouteSuggestions.calendarEnabled = true }
                        else calendarPermission.launch(android.Manifest.permission.READ_CALENDAR)
                    }
                    TextButton(onClick = { de.koeven.meeterz.suggest.FrequentPlaces.clear() }) { Text(tr("Gelernte Orte löschen")) }
                    HorizontalDivider()
                }
                item {
                    Text(tr("Route (Auto)"), fontWeight = FontWeight.SemiBold)
                    Text(tr("Gilt für jede Route, auch für Neuberechnungen unterwegs"), style = MaterialTheme.typography.bodySmall)
                    for (o in de.koeven.meeterz.nav.RoutePreferences.Option.entries) {
                        var on by remember { mutableStateOf(de.koeven.meeterz.nav.RoutePreferences.isOn(o)) }
                        SwitchRow(o.title, o.shortTitle, on) { on = it; de.koeven.meeterz.nav.RoutePreferences.set(o, it) }
                    }
                    HorizontalDivider()
                }
                item {
                    OutlinedButton(onClick = { showEv = true }, modifier = Modifier.fillMaxWidth()) { Text(tr("E-Auto und Ladeplanung")) }
                    OutlinedButton(onClick = { showSounds = true }, modifier = Modifier.fillMaxWidth()) { Text(tr("Sound-Pack: eigene Schnipsel aufnehmen")) }
                }
                if (favorites.isNotEmpty()) {
                    item { HorizontalDivider(); Text(tr("Gespeicherte Orte"), fontWeight = FontWeight.SemiBold) }
                    items(favorites, key = { it.id }) { fav ->
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text(fav.label)
                                fav.address?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                            }
                            TextButton(onClick = { AppState.favorites.remove(fav.id) }) { Text(tr("Löschen")) }
                        }
                    }
                }
                item {
                    HorizontalDivider()
                    Text(tr("Protokoll"), fontWeight = FontWeight.SemiBold)
                    Text(tr("Hilft, Fehler von unterwegs zu finden. Enthält Ansagen und Ereignisse, keine Nachrichten."),
                        style = MaterialTheme.typography.bodySmall)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedButton(onClick = { showLog = !showLog }) { Text(if (showLog) tr("Ausblenden") else "Anzeigen") }
                        OutlinedButton(onClick = {
                            val send = Intent(Intent.ACTION_SEND).setType("text/plain")
                                .putExtra(Intent.EXTRA_SUBJECT, tr("Meeterz-Protokoll (Android)"))
                                .putExtra(Intent.EXTRA_TEXT, Diag.text)
                            context.startActivity(Intent.createChooser(send, tr("Protokoll teilen")))
                        }) { Text(tr("Teilen")) }
                        TextButton(onClick = { Diag.clear(); showLog = false }) { Text(tr("Leeren")) }
                    }
                    if (showLog) {
                        SelectionContainer {
                            Text(Diag.text.takeLast(20_000).ifEmpty { tr("(leer)") }, fontFamily = FontFamily.Monospace, fontSize = 10.sp,
                                modifier = Modifier.heightIn(max = 400.dp).verticalScroll(rememberScrollState()))
                        }
                    }
                }
                item {
                    HorizontalDivider()
                    OutlinedButton(onClick = {
                        scope.launch {
                            LocationSharingService.stop(context)
                            AppState.endSession()
                            AppState.auth.signOut()
                        }
                    }, modifier = Modifier.fillMaxWidth().padding(vertical = 16.dp)) { Text(tr("Abmelden")) }
                }
            }
        }
    }
}

@Composable
private fun SwitchRow(title: String, subtitle: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, fontWeight = FontWeight.SemiBold)
            Text(subtitle, style = MaterialTheme.typography.bodySmall)
        }
        Switch(checked = checked, onCheckedChange = onChange)
    }
}

/** „Teilst live bis 18:30“, „Inkognito“, „Teilen pausiert“ (wie die Status-Pille auf iOS) */
fun sharingLabel(p: de.koeven.meeterz.data.Profile): String {
    val time = { i: java.time.Instant -> DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(i.toEpochMilli())) }
    if (p.isIncognito) return if (p.isIncognitoIndefinitely) tr("Inkognito") else tr("Inkognito bis %@", time(p.incognitoUntilInstant!!))
    if (!p.isSharingNow) return tr("Teilen pausiert")
    return p.sharingUntilInstant?.let { tr("Teilst live bis %@", time(it)) } ?: tr("Teilst live")
}
