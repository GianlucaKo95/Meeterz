package de.koeven.meeterz.ui

import de.koeven.meeterz.tr
import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
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
import de.koeven.meeterz.data.FairMeetupFinder
import de.koeven.meeterz.data.GroupMember
import de.koeven.meeterz.data.Meetup
import de.koeven.meeterz.data.MeetupCandidate
import de.koeven.meeterz.ev.ChargePlanner
import de.koeven.meeterz.nav.NavigationController
import de.koeven.meeterz.nav.PlaceSearch
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Calendar
import java.util.Date

private fun clock(seconds: Long) = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(seconds * 1000))

/** „Heute 18:30“ / „Morgen 9:00“ / „Fr., 14.11. 18:30“ (wie Meetup.timeText auf iOS) */
fun meetupTime(seconds: Long): String {
    val day = Calendar.getInstance().apply { timeInMillis = seconds * 1000 }
    val today = Calendar.getInstance()
    val diff = day.get(Calendar.DAY_OF_YEAR) - today.get(Calendar.DAY_OF_YEAR) +
        365 * (day.get(Calendar.YEAR) - today.get(Calendar.YEAR))
    val prefix = when (diff) {
        0 -> tr("Heute")
        1 -> tr("Morgen")
        else -> java.text.SimpleDateFormat("EE, dd.MM.", java.util.Locale.getDefault()).format(Date(seconds * 1000))
    }
    return "$prefix ${clock(seconds)}"
}

/**
 * Karte über der Karte (wie SocialCards auf iOS): eingehende Einladung, angenommenes Treffen, wartender Vorschlag
 * oder eine Gelegenheit („kreuzt deinen Weg“) – immer nur die wichtigste.
 */
@Composable
fun SocialCard(modifier: Modifier = Modifier, onPlan: (MeetupCandidate) -> Unit) {
    val meetups by AppState.meetups.meetups.collectAsState()
    val candidates by AppState.meetups.candidates.collectAsState()
    val friends by AppState.friends.collectAsState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val guidance by NavigationController.guidance.collectAsState()
    val incoming = meetups.firstOrNull { it.incoming && it.isPending }
    val accepted = meetups.firstOrNull { it.isAccepted }
    val waiting = meetups.firstOrNull { !it.incoming && it.isPending }
    val candidate = candidates.let { AppState.meetups.visibleCandidates() }.firstOrNull { c -> friends.any { it.friendId == c.friendId } }
    if (incoming == null && accepted == null && waiting == null && candidate == null) return

    Surface(modifier.fillMaxWidth().padding(12.dp), shape = RoundedCornerShape(20.dp), shadowElevation = 8.dp) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            when {
                incoming != null -> {
                    Text(if (incoming.isGroup) tr("%@ lädt %lld Freunde ein", incoming.otherName, maxOf(2, (incoming.groupSize ?: 3) - 1))
                        else tr("%@ möchte sich treffen", incoming.otherName),
                        color = MeeterzColors.mintLight, fontWeight = FontWeight.Bold, style = MaterialTheme.typography.labelMedium)
                    Text(incoming.placeName, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
                    incoming.meetAtSeconds?.let { Text("🕒 ${meetupTime(it)}", fontWeight = FontWeight.SemiBold) }
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        OutlinedButton(onClick = { scope.launch { AppState.meetups.respond(incoming, false) } }, Modifier.weight(1f)) { Text(tr("Ablehnen")) }
                        Button(onClick = {
                            scope.launch {
                                AppState.meetups.respond(incoming, true)
                                // Treffen später: nicht gleich als Ziel – die Losfahr-Erinnerung meldet sich rechtzeitig
                                val soon = (incoming.meetAtSeconds ?: 0) - System.currentTimeMillis() / 1000 < 45 * 60
                                if (soon) NavigationController.addStop(context, incoming.placeName, incoming.lat, incoming.lng)
                            }
                        }, Modifier.weight(1f)) { Text(tr("Annehmen")) }
                    }
                }
                accepted != null -> {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(tr("Treffen mit %@", if (accepted.incoming) accepted.withText else accepted.otherName),
                                color = MeeterzColors.mintLight, fontWeight = FontWeight.Bold, style = MaterialTheme.typography.labelMedium)
                            Text(accepted.placeName, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                            accepted.meetAtSeconds?.let { Text(meetupTime(it), style = MaterialTheme.typography.bodySmall) }
                        }
                        TextButton(onClick = { scope.launch { AppState.meetups.cancel(accepted) } }) { Text(tr("Absagen")) }
                    }
                    Button(onClick = { scope.launch { NavigationController.addStop(context, accepted.placeName, accepted.lat, accepted.lng) } },
                        Modifier.fillMaxWidth()) { Text(if (guidance != null) tr("Als Zwischenstopp") else tr("Hinfahren")) }
                }
                waiting != null -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp)
                    Column(Modifier.weight(1f)) {
                        Text(tr("Warte auf %@", waiting.otherName), fontWeight = FontWeight.SemiBold)
                        Text(waiting.placeName, style = MaterialTheme.typography.bodySmall)
                    }
                    TextButton(onClick = { scope.launch { AppState.meetups.cancel(waiting) } }) { Text(tr("Zurückziehen")) }
                }
                candidate != null -> {
                    val f = friends.first { it.friendId == candidate.friendId }
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Avatar(f.friendId, f.displayName)
                        Column(Modifier.weight(1f)) {
                            Text(tr("%@ kreuzt deinen Weg", f.displayName), fontWeight = FontWeight.SemiBold)
                            val minutes = (maxOf(candidate.myEtaSeconds, candidate.friendEtaSeconds) - System.currentTimeMillis() / 1000) / 60
                            Text(tr("In %@ Min. seid ihr nah beieinander", maxOf(1, minutes)), style = MaterialTheme.typography.bodySmall)
                        }
                        IconButton(onClick = { AppState.meetups.dismiss(candidate) }) { Icon(Icons.Default.Close, tr("Ausblenden")) }
                    }
                    Button(onClick = { onPlan(candidate) }, Modifier.fillMaxWidth()) { Text(tr("Treffen planen")) }
                }
            }
        }
    }
}

/** Treffen planen, wenn sich Wege kreuzen (wie MeetupPlanningSheet auf iOS) */
@Composable
fun CandidatePlanDialog(candidate: MeetupCandidate, onClose: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val friend = AppState.friends.value.firstOrNull { it.friendId == candidate.friendId }
    val friendName = friend?.displayName ?: tr("Freund")
    val categories = PlaceSearch.Category.available(allByCar = (candidate.friendMode ?: "car") == "car")
    var category by remember { mutableStateOf(categories[1]) }
    var places by remember { mutableStateOf<List<PlaceSearch.Place>>(emptyList()) }
    val spot = PlaceSearch.Place(tr("Treffpunkt auf der Route"), null, candidate.lat, candidate.lng)
    var selected by remember { mutableStateOf<PlaceSearch.Place?>(null) }
    var sending by remember { mutableStateOf(false) }
    LaunchedEffect(category) { places = PlaceSearch.places(category, candidate.lat, candidate.lng) }

    AlertDialog(
        onDismissRequest = onClose,
        title = { Text(tr("Treffen mit %@", friendName)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(tr("Du %@", clock(candidate.myEtaSeconds)) + " · " + (friend?.firstName ?: friendName) + " " +
                    clock(candidate.friendEtaSeconds) + " · " + tr("%@ Abstand", km(candidate.distanceM)),
                    style = MaterialTheme.typography.bodySmall)
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    for (c in categories) FilterChip(selected = c == category, onClick = { category = c }, label = { Text(c.title) })
                }
                LazyColumn(Modifier.fillMaxWidth().padding(top = 4.dp)) {
                    items(listOf(spot) + places) { p ->
                        Row(Modifier.fillMaxWidth().clickable { selected = p }.padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text(if (p == selected) "◉" else "○", color = MeeterzColors.mintLight, modifier = Modifier.padding(end = 10.dp))
                            Column {
                                Text(p.name, fontWeight = FontWeight.SemiBold)
                                p.address?.let { Text(it, style = MaterialTheme.typography.bodySmall, maxLines = 1) }
                            }
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(enabled = selected != null && !sending, onClick = {
                val p = selected ?: return@TextButton
                sending = true
                scope.launch {
                    if (AppState.meetups.propose(candidate.friendId, p.name, p.lat, p.lng)) {
                        Toast.makeText(context, tr("Vorschlag an %@ gesendet.", friendName), Toast.LENGTH_SHORT).show()
                        onClose()
                    }
                    sending = false
                }
            }) { Text(if (sending) tr("Wird gesendet …") else tr("Treffen vorschlagen")) }
        },
        dismissButton = { TextButton(onClick = onClose) { Text(tr("Abbrechen")) } },
    )
}

/** Freunde zu einem Ort einladen, optional mit Uhrzeit (wie InviteFriendsView auf iOS) */
@Composable
fun InviteFriendsDialog(placeName: String, address: String?, lat: Double, lng: Double, onClose: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val friends = AppState.friends.value.filter { it.isAccepted }
    val selected = remember { mutableStateListOf<String>() }
    var sending by remember { mutableStateOf(false) }
    // Uhrzeit: jetzt oder in festen Schritten (Material-Zeitwahl wäre im Dialog unhandlich)
    val choices = listOf<Pair<String, Long?>>(tr("Jetzt") to null, tr("In 30 Min.") to 30 * 60L, tr("In 1 Std.") to 3600L,
        tr("In 2 Std.") to 7200L, tr("Morgen") to null)
    var choice by remember { mutableStateOf(0) }
    var tomorrowHour by remember { mutableStateOf(18) }
    fun meetAt(): Long? {
        val now = System.currentTimeMillis() / 1000
        return when (choice) {
            0 -> null
            4 -> Calendar.getInstance().apply {
                add(Calendar.DAY_OF_YEAR, 1); set(Calendar.HOUR_OF_DAY, tomorrowHour); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0)
            }.timeInMillis / 1000
            else -> {
                val t = now + choices[choice].second!!
                t - t % 900 + 900   // auf die nächste Viertelstunde
            }
        }
    }
    AlertDialog(
        onDismissRequest = onClose,
        title = { Column { Text(tr("Einladen nach")); Text(placeName, fontWeight = FontWeight.Bold) } },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                address?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                LazyColumn(Modifier.fillMaxWidth()) {
                    items(friends, key = { it.friendId }) { f ->
                        Row(Modifier.fillMaxWidth().clickable { if (f.friendId in selected) selected.remove(f.friendId) else selected.add(f.friendId) }
                            .padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            Avatar(f.friendId, f.displayName, 32.dp)
                            Text(f.displayName, Modifier.weight(1f))
                            Checkbox(f.friendId in selected, { on -> if (on) selected.add(f.friendId) else selected.remove(f.friendId) })
                        }
                    }
                }
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    choices.forEachIndexed { i, (label, _) -> FilterChip(selected = choice == i, onClick = { choice = i }, label = { Text(label) }) }
                }
                if (choice == 4) Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    for (h in listOf(8, 10, 12, 14, 16, 18, 19, 20)) FilterChip(selected = tomorrowHour == h, onClick = { tomorrowHour = h }, label = { Text("$h:00") })
                }
                meetAt()?.let { Text(tr("Treffen %@ – Meeterz erinnert alle rechtzeitig ans Losfahren.", meetupTime(it)), style = MaterialTheme.typography.bodySmall) }
            }
        },
        confirmButton = {
            TextButton(enabled = selected.isNotEmpty() && !sending, onClick = {
                sending = true
                scope.launch {
                    val at = meetAt()
                    val sent = selected.count { AppState.meetups.propose(it, placeName, lat, lng, at) }
                    sending = false
                    Toast.makeText(context, when (sent) { 0 -> tr("Einladung konnte nicht gesendet werden."); 1 -> tr("Einladung gesendet."); else -> tr("%lld Einladungen gesendet.", sent) },
                        Toast.LENGTH_SHORT).show()
                    if (sent > 0) onClose()
                }
            }) { Text(if (sending) tr("Wird gesendet …") else tr("Einladung senden")) }
        },
        dismissButton = { TextButton(onClick = onClose) { Text(tr("Abbrechen")) } },
    )
}

/** Gruppen-Treffen mit fairem Treffpunkt (wie GroupMeetupView auf iOS) */
@Composable
fun GroupMeetupScreen(onClose: () -> Unit) {
    BackHandler(onBack = onClose)
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val live by AppState.hub.positions.collectAsState()
    val friends = AppState.friends.value.filter { it.isAccepted }
    val visible = friends.filter { f -> live[f.friendId] != null || f.lat != null }
    val selected = remember { mutableStateListOf<String>() }
    var options by remember { mutableStateOf<List<FairMeetupFinder.Option>>(emptyList()) }
    var searching by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var sending by remember { mutableStateOf<String?>(null) }

    Surface(Modifier.fillMaxSize()) {
        Column(Modifier.statusBarsPadding()) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, tr("Zurück")) }
                Text(tr("Gruppen-Treffen"), style = MaterialTheme.typography.titleLarge)
            }
            LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                item {
                    if (visible.isEmpty()) Text(tr("Gerade teilt niemand seinen Standort. Für einen fairen Treffpunkt braucht Meeterz die Standorte."),
                        style = MaterialTheme.typography.bodySmall)
                    Text(tr("Wer kommt mit?"), fontWeight = FontWeight.SemiBold)
                }
                items(visible, key = { it.friendId }) { f ->
                    Row(Modifier.fillMaxWidth().clickable { if (f.friendId in selected) selected.remove(f.friendId) else selected.add(f.friendId) },
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Avatar(f.friendId, f.displayName, 36.dp)
                        Text(f.displayName, Modifier.weight(1f))
                        Checkbox(f.friendId in selected, { on -> if (on) selected.add(f.friendId) else selected.remove(f.friendId) })
                    }
                }
                item {
                    Button(enabled = selected.isNotEmpty() && !searching, modifier = Modifier.fillMaxWidth(), onClick = {
                        searching = true; error = null
                        scope.launch {
                            val me = AppState.lastLocation
                            val people = buildList {
                                if (me != null) add(FairMeetupFinder.Participant("me", "Du", me.latitude, me.longitude))
                                for (id in selected) {
                                    val f = friends.first { it.friendId == id }
                                    val p = live[id]
                                    add(FairMeetupFinder.Participant(id, f.displayName, p?.lat ?: f.lat!!, p?.lng ?: f.lng!!))
                                }
                            }
                            runCatching { FairMeetupFinder.find(people) }
                                .onSuccess { options = it }.onFailure { error = it.message; options = emptyList() }
                            searching = false
                        }
                    }) { Text(if (searching) tr("Suche …") else tr("Fairen Treffpunkt finden")) }
                    error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                }
                if (options.isNotEmpty()) item {
                    HorizontalDivider()
                    Text(tr("Vorschläge – fair für alle"), fontWeight = FontWeight.SemiBold)
                    Text(tr("Sortiert nach der längsten Anfahrt: Niemand soll viel weiter fahren als die anderen."), style = MaterialTheme.typography.bodySmall)
                }
                items(options, key = { it.place.name + it.place.lat }) { o ->
                    Column(Modifier.fillMaxWidth().border(1.dp, MeeterzColors.mint.copy(alpha = 0.4f), RoundedCornerShape(14.dp)).padding(12.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Row { Text(o.place.name, Modifier.weight(1f), fontWeight = FontWeight.Bold); Text(tr("max. %@ Min.", (o.longest / 60).toInt())) }
                        o.place.address?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                        Text(o.durations.entries.joinToString(" · ") { (id, s) ->
                            val name = if (id == "me") "Du" else friends.firstOrNull { it.friendId == id }?.firstName ?: "?"
                            tr("%@ %@ Min.", name, (s / 60).toInt())
                        }, style = MaterialTheme.typography.bodySmall)
                        Button(enabled = sending == null, modifier = Modifier.fillMaxWidth(), onClick = {
                            sending = o.place.name
                            scope.launch {
                                if (AppState.meetups.proposeGroup(selected.toList(), o.place.name, o.place.lat, o.place.lng)) {
                                    Toast.makeText(context, tr("Einladung an %@ Freunde gesendet.", selected.size), Toast.LENGTH_SHORT).show()
                                    onClose()
                                }
                                sending = null
                            }
                        }) { Text(if (sending == o.place.name) tr("Wird gesendet …") else tr("Alle hierher einladen")) }
                    }
                }
                item { Spacer(Modifier.size(24.dp)) }
            }
        }
    }
}

/** Alle Treffen mit Teilnehmern und Stand (wie MeetupsOverviewView auf iOS) */
@Composable
fun MeetupsOverviewScreen(onClose: () -> Unit) {
    BackHandler(onBack = onClose)
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val meetups by AppState.meetups.meetups.collectAsState()
    val live by AppState.hub.positions.collectAsState()
    var showGroup by remember { mutableStateOf(false) }
    if (showGroup) { GroupMeetupScreen(onClose = { showGroup = false }); return }
    // Gruppen zusammenfassen: ein Eintrag je Gruppe
    val entries = meetups.filter { it.isPending || it.isAccepted }.groupBy { it.groupId ?: it.id }.values.toList()

    Surface(Modifier.fillMaxSize()) {
        Column(Modifier.statusBarsPadding()) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, tr("Zurück")) }
                Text(tr("Treffen"), style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
                TextButton(onClick = { showGroup = true }) { Text(tr("Gruppe planen")) }
            }
            LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                if (entries.isEmpty()) item {
                    Text(tr("Keine Treffen geplant. Lade Freunde über ein Ziel ein („Freunde einladen“) oder plane ein Gruppen-Treffen."),
                        style = MaterialTheme.typography.bodySmall)
                }
                items(entries, key = { it.first().groupId ?: it.first().id }) { rows ->
                    val m = rows.first()
                    var members by remember(m.groupId) { mutableStateOf<List<GroupMember>>(emptyList()) }
                    LaunchedEffect(m.groupId, meetups) { m.groupId?.let { members = AppState.meetups.groupMembers(it) } }
                    Column(Modifier.fillMaxWidth().border(1.dp, MeeterzColors.mint.copy(alpha = 0.35f), RoundedCornerShape(16.dp)).padding(14.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(m.placeName, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                        m.meetAtSeconds?.let { Text(meetupTime(it), fontWeight = FontWeight.SemiBold) }
                        val people: List<Triple<String, String, String>> = if (m.groupId != null && members.isNotEmpty())
                            members.map { Triple(it.userId, it.displayName, if (it.organizer) tr("lädt ein") else state(it.status)) }
                        else rows.map { Triple(it.otherId, it.otherName, state(it.status)) }
                        for ((id, name, st) in people) {
                            val eta = AppState.routes.routes.value[id]?.takeIf { ChargePlanner.distance(it.destLat, it.destLng, m.lat, m.lng) < 300 }
                            val here = live[id]?.let { m.distanceTo(it.lat, it.lng) < 100 } == true
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                Avatar(id, name, 28.dp)
                                Text(name, Modifier.weight(1f))
                                Text(when {
                                    here -> tr("ist da")
                                    eta != null -> "an ${clock(eta.eta.epochSecond)}"
                                    else -> st
                                }, style = MaterialTheme.typography.bodySmall)
                            }
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            if (m.incoming && m.isPending) {
                                OutlinedButton(onClick = { scope.launch { AppState.meetups.respond(m, false) } }) { Text(tr("Ablehnen")) }
                                Button(onClick = { scope.launch { AppState.meetups.respond(m, true) } }) { Text(tr("Zusagen")) }
                            } else {
                                if (m.isAccepted) Button(onClick = {
                                    scope.launch { NavigationController.addStop(context, m.placeName, m.lat, m.lng) }; onClose()
                                }) { Text(tr("Hinfahren")) }
                                TextButton(onClick = { scope.launch { rows.forEach { AppState.meetups.cancel(it) } } }) {
                                    Text(if (m.incoming) tr("Absagen") else if (m.isPending) tr("Zurückziehen") else tr("Absagen"))
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private fun state(status: String) = when (status) {
    "accepted" -> "kommt"
    "pending" -> tr("noch offen")
    "declined" -> tr("kommt nicht")
    else -> status
}

/**
 * „Wer ist wann da“ (wie MeetingPointCard auf iOS): Fahren Freunde zum selben Ziel (laufende Führung, sonst das
 * nächste zugesagte Treffen) oder sind schon dort, alle Ankunftszeiten nebeneinander – unterwegs mit „Bescheid geben“.
 */
@Composable
fun MeetingPointCard(modifier: Modifier = Modifier) {
    val guidance by NavigationController.guidance.collectAsState()
    val meetups by AppState.meetups.meetups.collectAsState()
    val live by AppState.hub.positions.collectAsState()
    val routes by AppState.routes.routes.collectAsState()
    val friends by AppState.friends.collectAsState()
    val version by de.koeven.meeterz.social.Passengers.version.collectAsState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var menu by remember { mutableStateOf(false) }

    val g = guidance
    val target = g?.destination?.let { Triple(it.name, it.lat, it.lng) }
        ?: meetups.firstOrNull { it.isAccepted }?.let { Triple(it.placeName, it.lat, it.lng) } ?: return
    val (name, lat, lng) = target
    data class Arrival(val id: String, val name: String, val eta: Long?, val here: Boolean)
    val riding = if (version >= 0) de.koeven.meeterz.social.Passengers.riding else emptySet()
    val others = friends.filter { it.isAccepted && it.friendId !in riding }.mapNotNull { f ->
        val p = live[f.friendId]
        val here = p != null && ChargePlanner.distance(p.lat, p.lng, lat, lng) < 150
        val eta = routes[f.friendId]?.takeIf { ChargePlanner.distance(it.destLat, it.destLng, lat, lng) < 300 }?.eta?.epochSecond
        if (!here && eta == null) null else Arrival(f.friendId, f.firstName, eta, here)
    }
    if (others.isEmpty()) return
    val me = g?.let { listOf(Arrival("me", "Du", System.currentTimeMillis() / 1000 + it.remainingSeconds.toLong(), false)) }.orEmpty()
    val all = (me + others).sortedWith(compareBy({ if (it.here) 0 else 1 }, { it.eta ?: Long.MAX_VALUE }))

    Surface(modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp), shape = RoundedCornerShape(18.dp), shadowElevation = 6.dp) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("🏁 $name", Modifier.weight(1f), fontWeight = FontWeight.Bold, maxLines = 1)
                if (g != null) androidx.compose.foundation.layout.Box {
                    TextButton(onClick = { menu = true }) { Text(tr("Bescheid geben")) }
                    androidx.compose.material3.DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        val eta = System.currentTimeMillis() + (g.remainingSeconds * 1000).toLong()
                        for (text in de.koeven.meeterz.data.MessagesStore.quickReplies(eta)) {
                            androidx.compose.material3.DropdownMenuItem(text = { Text(text) }, onClick = {
                                menu = false
                                scope.launch {
                                    val n = AppState.messages.send(text, others.map { it.id })
                                    Toast.makeText(context, if (n > 0) tr("Gesendet: „%@“", text) else tr("Nachricht nicht gesendet"), Toast.LENGTH_SHORT).show()
                                }
                            })
                        }
                    }
                }
            }
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (a in all) Surface(shape = RoundedCornerShape(50), color = MaterialTheme.colorScheme.surfaceVariant) {
                    Row(Modifier.padding(horizontal = 10.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Surface(Modifier.size(10.dp), shape = RoundedCornerShape(50), color = if (a.id == "me") MeeterzColors.mint else MeeterzColors.amber) {}
                        Text(a.name, fontWeight = FontWeight.SemiBold, style = MaterialTheme.typography.bodySmall)
                        Text(if (a.here) "da" else a.eta?.let { clock(it) } ?: "–", fontWeight = FontWeight.Black,
                            style = MaterialTheme.typography.bodySmall, color = if (a.here) MeeterzColors.mintLight else MaterialTheme.colorScheme.onSurface)
                    }
                }
            }
        }
    }
}
