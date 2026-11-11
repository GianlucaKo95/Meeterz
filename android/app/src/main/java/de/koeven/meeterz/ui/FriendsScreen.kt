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
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
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
    var mutedVersion by remember { mutableStateOf(0) }
    val hiddenFrom by AppState.hiddenFrom.collectAsState()

    Surface(Modifier.fillMaxSize()) {
        Column(Modifier.statusBarsPadding()) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Zurück") }
                Text("Freunde", style = MaterialTheme.typography.titleLarge)
            }
            LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
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
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Avatar(row.friendId, row.displayName)
                        Column(Modifier.weight(1f)) {
                            Text(row.displayName)
                            Text(if (row.friendId in hiddenFrom) "@${row.handle} · sieht dich nicht" else "@${row.handle}",
                                style = MaterialTheme.typography.bodySmall)
                        }
                        // Standort und Routen vor diesem Freund verbergen (iOS: Freund-Ansicht)
                        val hidden = row.friendId in hiddenFrom
                        IconButton(onClick = { scope.launch { AppState.setHidden(row.friendId, !hidden) } }) {
                            Icon(if (hidden) Icons.Default.VisibilityOff else Icons.Default.Visibility,
                                if (hidden) "Für ihn verborgen" else "Sieht dich")
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

            }
        }
    }
}
