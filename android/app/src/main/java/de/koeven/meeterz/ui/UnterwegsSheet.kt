package de.koeven.meeterz.ui

import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Event
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import de.koeven.meeterz.AppState
import de.koeven.meeterz.data.FriendRow
import de.koeven.meeterz.tr

/**
 * „Unterwegs“ hinter dem Freunde-Knopf der Karte (wie iOS UnterwegsSheet): Treffen, wer gerade sichtbar ist
 * (Antippen zeigt ihn auf der Karte), Gruppen-Treffen, „Freunde & Profil“.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun UnterwegsSheet(
    visible: List<FriendRow>,
    onDismiss: () -> Unit,
    onFocus: (FriendRow) -> Unit,
    onMeetups: () -> Unit,
    onGroupMeetup: () -> Unit,
    onManage: () -> Unit,
) {
    val context = LocalContext.current
    val friends by AppState.friends.collectAsState()
    val meetups by AppState.meetups.meetups.collectAsState()
    val live by AppState.hub.positions.collectAsState()
    val routes by AppState.routes.routes.collectAsState()
    val accepted = friends.filter { it.isAccepted }
    val onMap = visible.filter { it.isAccepted && (live[it.friendId] != null || it.lat != null) }
    val meetupCount = meetups.filter { it.isAccepted || it.isPending }.map { it.groupId ?: it.id }.toSet().size

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(),
        containerColor = MaterialTheme.colorScheme.background) {
        Column(Modifier.navigationBarsPadding().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(Modifier.fillMaxWidth()) {
                Text(tr("Unterwegs"), Modifier.align(Alignment.Center), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                TextButton(onClick = onDismiss, modifier = Modifier.align(Alignment.CenterEnd)) { Text(tr("Fertig")) }
            }
            if (meetupCount > 0) {
                Row(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surfaceContainerHigh, RoundedCornerShape(12.dp))
                    .clickable(onClick = onMeetups).padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Default.Event, null, tint = MaterialTheme.colorScheme.primary)
                    Text(if (meetupCount == 1) tr("1 Treffen") else tr("%@ Treffen", meetupCount), Modifier.weight(1f).padding(start = 10.dp),
                        fontWeight = FontWeight.SemiBold)
                    Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            if (accepted.isEmpty()) {
                EmptyState(tr("Noch keine Freunde"), tr("Lade jemanden ein oder füge ihn über den Benutzernamen hinzu. Dann seht ihr euch hier auf der Karte."))
                OutlinedButton(onClick = {
                    val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, tr("Lass uns Meeterz nutzen – dann sehen wir uns unterwegs auf der Karte."))
                    context.startActivity(Intent.createChooser(send, tr("Einladung senden")))
                }, Modifier.fillMaxWidth()) { Text(tr("Einladung senden")) }
            } else {
                Text(tr("%@ von %@ sichtbar", onMap.size, accepted.size), style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                for (f in onMap) {
                    val route = routes[f.friendId]
                    val pos = live[f.friendId]
                    val subtitle = route?.let { r ->
                        listOfNotNull(r.destinationName?.let { tr("nach %@", it) }, tr("Ankunft %@", clockAt(r.eta))).joinToString(" · ")
                    } ?: pos?.let { ago(it.ageSeconds) } ?: tr("teilt nicht")
                    Row(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surface, RoundedCornerShape(12.dp))
                        .clickable { onFocus(f) }.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        Avatar(f.friendId, f.displayName, 40.dp)
                        Column(Modifier.weight(1f).padding(start = 12.dp)) {
                            Text(f.displayName, fontWeight = FontWeight.SemiBold)
                            Text(subtitle, style = MaterialTheme.typography.bodySmall,
                                color = if (route != null) MaterialTheme.colorScheme.tertiary else MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                if (onMap.isEmpty()) EmptyState(tr("Gerade teilt niemand"),
                    tr("Sobald Freunde ihren Standort teilen, erscheinen sie hier. Lange nicht aktualisierte Freunde blendet Meeterz aus (Einstellungen → Karte & Navigation)."))
            }
            if (onMap.isNotEmpty()) {
                OutlinedButton(onClick = onGroupMeetup, Modifier.fillMaxWidth().padding(top = 8.dp)) {
                    Icon(Icons.Default.Groups, null, Modifier.size(18.dp)); Text(tr("Gruppen-Treffen planen"), Modifier.padding(start = 8.dp))
                }
            }
            Button(onClick = onManage, Modifier.fillMaxWidth()) {
                Text(if (accepted.isEmpty()) tr("Freunde hinzufügen") else tr("Freunde & Profil"))
            }
        }
    }
}

@Composable
private fun EmptyState(title: String, message: String) {
    Column(Modifier.fillMaxWidth().padding(vertical = 12.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(title, fontWeight = FontWeight.SemiBold)
        Text(message, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center)
    }
}
