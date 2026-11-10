package de.koeven.meeterz.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import de.koeven.meeterz.AppState
import de.koeven.meeterz.auth.AuthRepository
import de.koeven.meeterz.live.LocationSharingService
import kotlinx.coroutines.launch

/** Freunde und Einstellungen (iOS: FriendsView) */
@Composable
fun FriendsScreen(onClose: () -> Unit) {
    BackHandler(onBack = onClose)
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val auth by AppState.auth.state.collectAsState()
    val profile = (auth as? AuthRepository.State.Ready)?.profile
    val friends by AppState.friends.collectAsState()
    val error by AppState.friendError.collectAsState()
    val favorites by AppState.favorites.items.collectAsState()
    var handle by remember { mutableStateOf("") }
    var showSounds by remember { mutableStateOf(false) }
    var autoDelay by remember { mutableStateOf(de.koeven.meeterz.data.MessagesStore.autoDelay) }
    var mutedVersion by remember { mutableStateOf(0) }
    if (showSounds) { SoundPackScreen(onClose = { showSounds = false }); return }

    Surface(Modifier.fillMaxSize()) {
        Column(Modifier.statusBarsPadding()) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Zurück") }
                Text("Freunde & Einstellungen", style = MaterialTheme.typography.titleLarge)
            }
            LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                profile?.let { p ->
                    item {
                        Text(p.displayName, style = MaterialTheme.typography.titleMedium)
                        Text("@${p.handle}", style = MaterialTheme.typography.bodySmall)
                    }
                    item {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text("Standort teilen", fontWeight = FontWeight.SemiBold)
                                Text("Freunde sehen, wo du bist", style = MaterialTheme.typography.bodySmall)
                            }
                            Switch(checked = p.sharingEnabled, onCheckedChange = { on -> scope.launch { AppState.setSharing(on) } })
                        }
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text("Bei Verspätung automatisch Bescheid geben", fontWeight = FontWeight.SemiBold)
                                Text("Ab 5 Minuten später an alle, die du am Ziel triffst", style = MaterialTheme.typography.bodySmall)
                            }
                            Switch(checked = autoDelay, onCheckedChange = { autoDelay = it; de.koeven.meeterz.data.MessagesStore.autoDelay = it })
                        }
                        OutlinedButton(onClick = { showSounds = true }, modifier = Modifier.fillMaxWidth()) { Text("Sound-Pack: eigene Schnipsel aufnehmen") }
                        HorizontalDivider()
                    }
                }

                item {
                    Text("Freund hinzufügen", fontWeight = FontWeight.SemiBold)
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedTextField(handle, { handle = it }, label = { Text("Benutzername") }, singleLine = true, modifier = Modifier.weight(1f))
                        Button(onClick = { scope.launch { if (AppState.sendFriendRequest(handle)) handle = "" } }, enabled = handle.length >= 3) { Text("Anfragen") }
                    }
                    error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                }

                val incoming = friends.filter { !it.isAccepted && it.incoming }
                if (incoming.isNotEmpty()) item { Text("Anfragen", fontWeight = FontWeight.SemiBold) }
                items(incoming, key = { "in-" + it.friendId }) { row ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(row.displayName, Modifier.weight(1f))
                        TextButton(onClick = { scope.launch { AppState.respond(row, false) } }) { Text("Ablehnen") }
                        Button(onClick = { scope.launch { AppState.respond(row, true) } }) { Text("Annehmen") }
                    }
                }

                val outgoing = friends.filter { !it.isAccepted && !it.incoming }
                items(outgoing, key = { "out-" + it.friendId }) { row ->
                    Text("${row.displayName} – Anfrage gesendet", style = MaterialTheme.typography.bodySmall)
                }

                item { Text("Freunde", fontWeight = FontWeight.SemiBold) }
                val accepted = friends.filter { it.isAccepted }
                if (accepted.isEmpty()) item { Text("Noch keine Freunde – lade jemanden über den Benutzernamen ein.", style = MaterialTheme.typography.bodySmall) }
                items(accepted, key = { it.friendId }) { row ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(row.displayName)
                            Text("@${row.handle}", style = MaterialTheme.typography.bodySmall)
                        }
                        // Sound-Pack je Freund stumm schalten (iOS: in der Freund-Ansicht)
                        val muted = mutedVersion >= 0 && de.koeven.meeterz.sound.SoundStore.isMuted(row.friendId)
                        IconButton(onClick = { de.koeven.meeterz.sound.SoundStore.setMuted(row.friendId, !muted); mutedVersion++ }) {
                            Icon(if (muted) Icons.AutoMirrored.Filled.VolumeOff else Icons.AutoMirrored.Filled.VolumeUp,
                                if (muted) "Schnipsel stumm" else "Schnipsel an")
                        }
                        TextButton(onClick = { scope.launch { AppState.removeFriend(row) } }) { Text("Entfernen") }
                    }
                }

                if (favorites.isNotEmpty()) {
                    item { HorizontalDivider(); Text("Gespeicherte Orte", fontWeight = FontWeight.SemiBold) }
                    items(favorites, key = { it.id }) { fav ->
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text(fav.label)
                                fav.address?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                            }
                            TextButton(onClick = { AppState.favorites.remove(fav.id) }) { Text("Löschen") }
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
                    }, modifier = Modifier.fillMaxWidth().padding(vertical = 16.dp)) { Text("Abmelden") }
                }
            }
        }
    }
}
