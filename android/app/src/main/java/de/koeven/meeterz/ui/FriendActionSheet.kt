package de.koeven.meeterz.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.Directions
import androidx.compose.material.icons.filled.Flag
import androidx.compose.material.icons.filled.Place
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.Route
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import de.koeven.meeterz.AppState
import de.koeven.meeterz.data.FriendRoute
import de.koeven.meeterz.data.MessagesStore
import de.koeven.meeterz.nav.NavigationController
import de.koeven.meeterz.tr
import kotlinx.coroutines.launch

/**
 * Freund auf der Karte angetippt (wie iOS FriendActionSheet): letzte Nachricht, Profil, auf der Karte bzw. Route
 * zeigen, hin navigieren, kurz Bescheid geben, zum Ziel des Freundes navigieren.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FriendActionSheet(
    friendId: String,
    onDismiss: () -> Unit,
    onShow: (lat: Double, lng: Double, route: FriendRoute?) -> Unit,
    onNavigate: (name: String, lat: Double, lng: Double) -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val friends by AppState.friends.collectAsState()
    val live by AppState.hub.positions.collectAsState()
    val routes by AppState.routes.routes.collectAsState()
    val messages by AppState.messages.messages.collectAsState()
    val guidance by NavigationController.guidance.collectAsState()
    val friend = friends.firstOrNull { it.friendId == friendId } ?: return
    val pos = live[friendId]
    val lat = pos?.lat ?: friend.lat ?: return
    val lng = pos?.lng ?: friend.lng ?: return
    val route = routes[friendId]
    val last = messages.firstOrNull { it.otherId == friendId }
    var showProfile by remember { mutableStateOf(false) }
    var replies by remember { mutableStateOf(false) }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = MaterialTheme.colorScheme.background) {
        Column(Modifier.navigationBarsPadding().padding(horizontal = 20.dp).padding(bottom = 20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            if (showProfile) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = { showProfile = false }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, tr("Zurück"), tint = MaterialTheme.colorScheme.primary) }
                    Text(tr("Profil"), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                }
                Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Avatar(friendId, friend.displayName, 110.dp)
                    Text(friend.displayName, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
                    Text("@${friend.handle}", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Group {
                    pos?.let { ValueRow(tr("Standort"), ago(it.ageSeconds)) }
                    AppState.lastLocation?.let { me ->
                        GroupDivider()
                        ValueRow(tr("Entfernung"), distanceText(de.koeven.meeterz.ev.ChargePlanner.distance(me.latitude, me.longitude, lat, lng)))
                    }
                    pos?.speed?.takeIf { it > 1 }?.let { GroupDivider(); ValueRow(tr("Tempo"), tr("%lld km/h", Math.round(it * 3.6))) }
                    route?.let {
                        GroupDivider(); ValueRow(tr("Ziel"), it.destinationName ?: tr("Unterwegs"))
                        GroupDivider(); ValueRow(tr("Ankunft"), clockAt(it.eta))
                    }
                }
                return@Column
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Avatar(friendId, friend.displayName, 56.dp)
                Column(Modifier.padding(start = 12.dp)) {
                    Text(friend.displayName, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
                    val status = route?.let { r ->
                        tr("%@ · an %@", r.destinationName?.let { tr("Nach %@", it) } ?: tr("Unterwegs"), clockAt(r.eta))
                    } ?: pos?.let { tr("Standort %@", ago(it.ageSeconds)) } ?: ""
                    Text(status, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            last?.let { m ->
                Row(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surface, RoundedCornerShape(12.dp)).padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.AutoMirrored.Filled.Chat, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(if (m.incoming) m.body else tr("Du: %@", m.body), Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                    Text(runCatching { clockAt(java.time.Instant.parse(m.createdAt)) }.getOrDefault(""),
                        style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                if (de.koeven.meeterz.data.StoriesStore.hasStories(friendId)) {
                    Button(onClick = { onDismiss(); de.koeven.meeterz.data.StoriesStore.open(friendId) }, Modifier.fillMaxWidth()) {
                        Icon(Icons.Default.PlayCircle, null, Modifier.size(18.dp)); Spacer(Modifier.width(8.dp)); Text(tr("Story ansehen"))
                    }
                }
                SheetButton(tr("Profil anzeigen"), Icons.Default.AccountCircle) { showProfile = true }
                SheetButton(if (route == null) tr("Auf Karte anzeigen") else tr("Route anzeigen"),
                    if (route == null) Icons.Default.Place else Icons.Default.Route) { onShow(lat, lng, route) }
                Button(onClick = { onNavigate(friend.displayName, lat, lng) }, Modifier.fillMaxWidth()) {
                    Icon(Icons.Default.Directions, null, Modifier.size(18.dp)); Spacer(Modifier.width(8.dp))
                    Text(tr("Zu %@ navigieren", friend.displayName))
                }
                Box {
                    SheetButton(tr("Kurz Bescheid geben"), Icons.AutoMirrored.Filled.Chat) { replies = true }
                    DropdownMenu(replies, { replies = false }) {
                        val eta = guidance?.let { NavigationController.progress.value?.durationRemaining }?.let { System.currentTimeMillis() + (it * 1000).toLong() }
                        for (text in MessagesStore.quickReplies(eta)) {
                            DropdownMenuItem(text = { Text(text) }, onClick = {
                                replies = false
                                scope.launch {
                                    val n = AppState.messages.send(text, listOf(friendId))
                                    android.widget.Toast.makeText(context, if (n > 0) tr("Gesendet") else tr("Nachricht nicht gesendet"),
                                        android.widget.Toast.LENGTH_SHORT).show()
                                }
                            })
                        }
                    }
                }
                route?.let { r ->
                    SheetButton(tr("Zum Ziel von %@ navigieren", friend.displayName), Icons.Default.Flag) {
                        onNavigate(r.destinationName ?: tr("Ziel von %@", friend.displayName), r.destLat, r.destLng)
                    }
                }
            }
        }
    }
}

@Composable
private fun SheetButton(label: String, icon: ImageVector, onClick: () -> Unit) {
    OutlinedButton(onClick = onClick, Modifier.fillMaxWidth()) {
        Icon(icon, null, Modifier.size(18.dp)); Spacer(Modifier.width(8.dp)); Text(label)
    }
}

/** „350 m“ / „12 km“ (wie iOS ActivityFormat.distance) */
internal fun distanceText(meters: Double): String =
    if (meters < 1000) "${(Math.round(meters / 10) * 10)} m"
    else if (meters < 10_000) String.format(java.util.Locale.getDefault(), "%.1f km", meters / 1000)
    else "${Math.round(meters / 1000)} km"
