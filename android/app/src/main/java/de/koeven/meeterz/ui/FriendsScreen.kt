package de.koeven.meeterz.ui

import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Event
import de.koeven.meeterz.tr
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.PersonRemove
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.LocationOff
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
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material.icons.filled.Groups
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

/**
 * Freunde und Profil wie iOS (FriendsView): Titel „Hallo Luca“, Zahnrad zu den Einstellungen, Profilbild,
 * Freund hinzufügen, Anfragen, deine Freunde (Aktionen im Menü statt Wischgesten), Gesendet.
 */
@Composable
fun FriendsScreen(onClose: () -> Unit, onSettings: () -> Unit = {}, onMeetups: () -> Unit = {},
                  onTrips: () -> Unit = {}, onGroupMeetup: () -> Unit = {}, onFocus: (de.koeven.meeterz.data.FriendRow) -> Unit = {}) {
    BackHandler(onBack = onClose)
    val scope = rememberCoroutineScope()
    val auth by AppState.auth.state.collectAsState()
    val profile = (auth as? AuthRepository.State.Ready)?.profile
    val friends by AppState.friends.collectAsState()
    val error by AppState.friendError.collectAsState()
    val live by AppState.hub.positions.collectAsState()
    val routes by AppState.routes.routes.collectAsState()
    var handle by remember { mutableStateOf("") }
    var mutedVersion by remember { mutableStateOf(0) }
    val hiddenFrom by AppState.hiddenFrom.collectAsState()
    val hiddenForMe by de.koeven.meeterz.social.Passengers.hiddenForMe.collectAsState()
    val first = profile?.displayName?.split(" ")?.firstOrNull().orEmpty()

    GroupedPage(if (first.isEmpty()) tr("Hallo") else tr("Hallo %@", first), onBack = onClose, trailing = {
        IconButton(onClick = onSettings) { Icon(Icons.Default.Settings, tr("Einstellungen"), tint = MaterialTheme.colorScheme.primary) }
    }) {
        profile?.let { p ->
            Group(tr("Profilbild"), tr("Dein Foto sehen nur Freunde, deren Anfrage du angenommen hast. Ohne Foto erscheinen deine Initialen.")) {
                Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    AvatarEditor(p)
                    Column(Modifier.padding(start = 16.dp)) {
                        Text(p.displayName, fontWeight = FontWeight.SemiBold)
                        Text("@${p.handle}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
        Group(tr("Freund hinzufügen"), profile?.let { tr("Dein Benutzername: @%@", it.handle) }) {
            Row(Modifier.padding(start = 16.dp, end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                androidx.compose.foundation.text.BasicTextField(handle, { handle = it }, singleLine = true,
                    textStyle = MaterialTheme.typography.bodyLarge.copy(color = MaterialTheme.colorScheme.onSurface),
                    cursorBrush = androidx.compose.ui.graphics.SolidColor(MaterialTheme.colorScheme.primary),
                    modifier = Modifier.weight(1f).padding(vertical = 12.dp),
                    decorationBox = { inner ->
                        if (handle.isEmpty()) Text("@benutzername", color = MaterialTheme.colorScheme.onSurfaceVariant)
                        inner()
                    })
                val clean = handle.replace("@", "")
                TextButton(enabled = clean.length >= 3, onClick = { scope.launch { if (AppState.sendFriendRequest(clean)) handle = "" } }) {
                    Text(tr("Hinzufügen"))
                }
            }
        }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }

        val incoming = friends.filter { !it.isAccepted && it.incoming }
        if (incoming.isNotEmpty()) Group(tr("Anfragen")) {
            incoming.forEachIndexed { i, row ->
                if (i > 0) GroupDivider()
                Row(Modifier.padding(start = 16.dp, end = 8.dp, top = 8.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    FriendLabel(row, Modifier.weight(1f))
                    IconButton(onClick = { scope.launch { AppState.respond(row, false) } }) { Icon(Icons.Default.Close, tr("Ablehnen")) }
                    Button(onClick = { scope.launch { AppState.respond(row, true) } }) { Text(tr("Annehmen")) }
                }
            }
        }

        val accepted = friends.filter { it.isAccepted }
        Group(tr("Deine Freunde")) {
            if (accepted.isEmpty()) {
                Text(tr("Füge jemanden oben über den Benutzernamen hinzu – oder schick eine Einladung."), Modifier.padding(16.dp),
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            accepted.forEachIndexed { i, row ->
                if (i > 0) GroupDivider()
                var menu by remember { mutableStateOf(false) }
                val hidden = row.friendId in hiddenFrom
                val offMap = row.friendId in hiddenForMe
                val muted = mutedVersion >= 0 && de.koeven.meeterz.sound.SoundStore.isMuted(row.friendId)
                val status = when {
                    routes.containsKey(row.friendId) -> tr("unterwegs")
                    live[row.friendId] != null -> ago(live[row.friendId]!!.ageSeconds)
                    else -> tr("teilt nicht")
                }
                Box {
                    Row(Modifier.fillMaxWidth().clickable { menu = true }.padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 8.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        FriendLabel(row, Modifier.weight(1f))
                        if (hidden) Icon(Icons.Default.VisibilityOff, tr("Standort verborgen"), tint = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(end = 8.dp).size(18.dp))
                        // Entfernung wie früher im „Unterwegs“-Fenster (wie iOS)
                        val pos = live[row.friendId]
                        val me = AppState.lastLocation
                        if (pos != null && me != null) Text(distanceText(de.koeven.meeterz.ev.ChargePlanner.distance(me.latitude, me.longitude, pos.lat, pos.lng)) + " · ",
                            style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.SemiBold)
                        Text(status, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    DropdownMenu(menu, { menu = false }) {
                        // Auf der Karte zeigen (vorher im „Unterwegs“-Fenster – wie iOS, 24.11.)
                        if (live[row.friendId] != null || row.lat != null) DropdownMenuItem(text = { Text(tr("Auf Karte anzeigen")) },
                            leadingIcon = { Icon(Icons.Default.LocationOn, null) },
                            onClick = { menu = false; onFocus(row) })
                        DropdownMenuItem(text = { Text(if (hidden) tr("Standort wieder zeigen") else tr("Standort vor %@ verbergen", row.displayName)) },
                            leadingIcon = { Icon(if (hidden) Icons.Default.Visibility else Icons.Default.VisibilityOff, null) },
                            onClick = { menu = false; scope.launch { AppState.setHidden(row.friendId, !hidden) } })
                        DropdownMenuItem(text = { Text(if (offMap) tr("Auf meiner Karte einblenden") else tr("Auf meiner Karte ausblenden")) },
                            leadingIcon = { Icon(if (offMap) Icons.Default.LocationOn else Icons.Default.LocationOff, null) },
                            onClick = { menu = false; de.koeven.meeterz.social.Passengers.setHiddenForMe(row.friendId, !offMap) })
                        DropdownMenuItem(text = { Text(if (muted) tr("%@ abspielen", row.displayName) else tr("Schnipsel stumm")) },
                            leadingIcon = { Icon(if (muted) Icons.AutoMirrored.Filled.VolumeUp else Icons.AutoMirrored.Filled.VolumeOff, null) },
                            onClick = { menu = false; de.koeven.meeterz.sound.SoundStore.setMuted(row.friendId, !muted); mutedVersion++ })
                        DropdownMenuItem(text = { Text(tr("Entfernen"), color = MaterialTheme.colorScheme.error) },
                            leadingIcon = { Icon(Icons.Default.PersonRemove, null, tint = MaterialTheme.colorScheme.error) },
                            onClick = { menu = false; scope.launch { AppState.removeFriend(row) } })
                    }
                }
            }
        }

        val outgoing = friends.filter { !it.isAccepted && !it.incoming }
        if (outgoing.isNotEmpty()) Group(tr("Gesendet")) {
            outgoing.forEachIndexed { i, row ->
                if (i > 0) GroupDivider()
                Row(Modifier.padding(start = 16.dp, end = 8.dp, top = 8.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    FriendLabel(row, Modifier.weight(1f))
                    TextButton(onClick = { scope.launch { AppState.removeFriend(row) } }) {
                        Text(tr("Zurückziehen"), color = MaterialTheme.colorScheme.error)
                    }
                }
            }
        }

        // Treffen, Gruppen-Treffen und Fahrten – früher im „Unterwegs“-Fenster, jetzt am Ende des Profils (wie iOS, 24.11.)
        val meetups by AppState.meetups.meetups.collectAsState()
        val meetupCount = meetups.filter { it.isAccepted || it.isPending }.map { it.groupId ?: it.id }.toSet().size
        val convoy by de.koeven.meeterz.data.ConvoyFeed.key.collectAsState()
        val anyOnMap = accepted.any { live[it.friendId] != null }
        Group(tr("Treffen & Fahrten")) {
            if (meetupCount > 0) {
                NavRow(if (meetupCount == 1) tr("1 Treffen") else tr("%lld Treffen", meetupCount), icon = Icons.Default.Event, onClick = onMeetups)
                GroupDivider()
            }
            if (anyOnMap) {
                NavRow(tr("Gruppen-Treffen planen"), icon = Icons.Default.Groups, onClick = onGroupMeetup)
                GroupDivider()
            }
            NavRow(if (convoy != null) tr("Konvoi-Feed & Fahrten") else tr("Fahrten"),
                icon = if (convoy != null) Icons.Default.DirectionsCar else Icons.Default.History, onClick = onTrips)
        }
    }
}

/** Avatar mit Name und @Benutzername (iOS: FriendLabel) */
@Composable
private fun FriendLabel(row: de.koeven.meeterz.data.FriendRow, modifier: Modifier = Modifier) {
    Row(modifier, verticalAlignment = Alignment.CenterVertically) {
        Avatar(row.friendId, row.displayName, 36.dp)
        Column(Modifier.padding(start = 12.dp)) {
            Text(row.displayName, fontWeight = FontWeight.SemiBold)
            Text("@${row.handle}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** „live“ / „vor 5 Min.“ / „vor 2 Std.“ (wie iOS Format.age) */
internal fun ago(seconds: Double): String = when {
    seconds < 60 -> tr("live")
    seconds < 3600 -> tr("vor %lld Min.", (seconds / 60).toInt())
    else -> tr("vor %lld Std.", (seconds / 3600).toInt())
}
