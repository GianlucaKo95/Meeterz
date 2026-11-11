package de.koeven.meeterz.social

import de.koeven.meeterz.tr
import com.mapbox.geojson.LineString
import com.mapbox.navigation.core.lifecycle.MapboxNavigationApp
import de.koeven.meeterz.AppState
import de.koeven.meeterz.Diag
import de.koeven.meeterz.data.FriendRow
import de.koeven.meeterz.ev.ChargePlanner
import de.koeven.meeterz.nav.NavigationController
import de.koeven.meeterz.sound.SoundMoments
import de.koeven.meeterz.ui.km
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.text.DateFormat
import java.util.Date
import kotlin.math.abs

private fun clock(seconds: Long) = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(seconds * 1000))

/**
 * Konvoi (wie ConvoyTracker.swift): Freunde, die zum selben Ziel fahren oder dort mit mir verabredet sind.
 * Abstand entlang meiner Route; Hinweise, wenn jemand anhält, deutlich zurückfällt oder eine andere Strecke nimmt.
 */
object Convoy {
    data class Member(val friend: FriendRow, val gap: Double?, val arrival: Long?, val stopped: Boolean) {
        val summary: String get() = listOfNotNull(
            when {
                gap == null -> tr("andere Strecke")
                abs(gap) < 150 -> tr("direkt bei dir")
                gap > 0 -> tr("%@ vor dir", km(abs(gap)))
                else -> tr("%@ hinter dir", km(abs(gap)))
            },
            tr("hält gerade").takeIf { stopped },
            arrival?.let { "an ${clock(it)}" },
        ).joinToString(" · ")
    }

    private class State(var behindFar: Boolean = false, var offRoute: Boolean = false, var stoppedSince: Long? = null, var stopAnnounced: Boolean = false)
    private val states = mutableMapOf<String, State>()
    private val arrivalAnnounced = mutableMapOf<String, Pair<Long, Long>>()   // Freund → (ETA, wann gemeldet)

    private var routeKey = ""
    private var coords: List<Point2> = emptyList()
    private var cumulative: DoubleArray = DoubleArray(0)
    private data class Point2(val lat: Double, val lng: Double)

    fun reset() { states.clear(); arrivalAnnounced.clear() }

    /** Route eines Freundes zu diesem Ort (sein Ziel höchstens 300 m entfernt, Ankunft in der Zukunft) */
    fun arrival(friendId: String, lat: Double, lng: Double): Long? {
        val r = AppState.routes.routes.value[friendId] ?: return null
        if (ChargePlanner.distance(r.destLat, r.destLng, lat, lng) >= 300) return null
        return r.eta.epochSecond.takeIf { it > System.currentTimeMillis() / 1000 }
    }

    /** Aktuelle Konvoi-Mitglieder (nur während einer Führung) */
    fun members(): List<Member> {
        val dest = NavigationController.guidance.value?.destination ?: return emptyList()
        loadRoute()
        val me = AppState.lastLocation
        val myIndex = me?.let { nearest(it.latitude, it.longitude)?.first }
        val meetupIds = AppState.meetups.accepted.filter { it.distanceTo(dest.lat, dest.lng) < 300 }.flatMap { AppState.meetups.partners(it) }.toSet()
        val live = AppState.hub.positions.value
        val riding = Passengers.riding
        return AppState.friends.value.filter { it.isAccepted && it.friendId !in riding }.mapNotNull { f ->
            val p = live[f.friendId] ?: return@mapNotNull null
            val eta = arrival(f.friendId, dest.lat, dest.lng)
            if (eta == null && f.friendId !in meetupIds) return@mapNotNull null
            val gap = if (myIndex != null) nearest(p.lat, p.lng)?.takeIf { it.second < 300 }?.let { cumulative[it.first] - cumulative[myIndex] } else null
            val stopped = p.ageSeconds < 120 && (p.speed ?: 0.0) < 1 && ChargePlanner.distance(p.lat, p.lng, dest.lat, dest.lng) > 300
            Member(f, gap, eta, stopped)
        }.sortedByDescending { it.gap ?: -Double.MAX_VALUE }
    }

    /** Alle 30 s (Android Auto, wie der CarPlay-Takt): Hinweise bei Veränderungen */
    fun check(notify: (String, FriendRow) -> Unit) {
        val current = members()
        val ids = current.map { it.friend.friendId }.toSet()
        states.keys.retainAll(ids)
        val now = System.currentTimeMillis()
        for (m in current) {
            val s = states.getOrPut(m.friend.friendId) { State() }
            val first = m.friend.firstName
            m.gap?.let { gap ->
                // Zurückgefallen: > 3 km hinter mir (erst wieder melden, wenn er unter 1,5 km aufholt)
                if (gap < -3_000 && !s.behindFar) { s.behindFar = true; notify(tr("%@ ist %@ hinter dir", first, km(-gap)), m.friend) }
                if (gap > -1_500) s.behindFar = false
            }
            if (m.gap == null && !s.offRoute) { s.offRoute = true; notify(tr("%@ fährt eine andere Strecke", first), m.friend) }
            if (m.gap != null) s.offRoute = false
            if (m.stopped) {
                val since = s.stoppedSince ?: now.also { s.stoppedSince = it }
                if (!s.stopAnnounced && now - since > 120_000) { s.stopAnnounced = true; notify(tr("%@ hält gerade an", first), m.friend) }
            } else { s.stoppedSince = null; s.stopAnnounced = false }
        }
    }

    /** „Lisa fährt auch hierher“ – beim Start und wenn sich ihre Ankunft deutlich verschiebt (höchstens ein Hinweis je Aufruf) */
    fun announceHeadingHere(notify: (String, String, FriendRow) -> Unit) {
        val g = NavigationController.guidance.value ?: return
        val now = System.currentTimeMillis()
        val myEta = if (g.remainingSeconds > 0) now / 1000 + g.remainingSeconds.toLong() else null
        for (f in AppState.friends.value.filter { it.isAccepted && it.friendId !in Passengers.riding }) {
            val eta = arrival(f.friendId, g.destination.lat, g.destination.lng) ?: continue
            val last = arrivalAnnounced[f.friendId]
            if (last != null && (abs(last.first - eta) < 300 || now - last.second < 600_000)) continue
            arrivalAnnounced[f.friendId] = eta to now
            var subtitle = tr("Ankunft %@", clock(eta))
            if (myEta != null) {
                val diff = Math.round((eta - myEta) / 60.0)
                subtitle += when {
                    diff > 0 -> tr(" · %lld Min. nach dir", diff)
                    diff < 0 -> tr(" · %lld Min. vor dir", -diff)
                    else -> tr(" · gleichzeitig mit dir")
                }
            }
            notify(tr("%@ fährt auch hierher", f.firstName), subtitle, f)
            return
        }
    }

    /** Meine Strecke mit aufsummierten Metern und wo ich gerade bin (für den Pausenvorschlag) */
    class Profile(val lats: DoubleArray, val lngs: DoubleArray, val cumulative: DoubleArray, val mine: Double)

    fun routeProfile(): Profile? {
        loadRoute()
        val me = AppState.lastLocation ?: return null
        val hit = nearest(me.latitude, me.longitude) ?: return null
        return Profile(coords.map { it.lat }.toDoubleArray(), coords.map { it.lng }.toDoubleArray(), cumulative, cumulative[hit.first])
    }

    /** Meter entlang meiner Strecke für einen Punkt, nur wenn er höchstens `within` daneben liegt */
    fun along(lat: Double, lng: Double, within: Double): Double? =
        nearest(lat, lng)?.takeIf { it.second <= within }?.let { cumulative[it.first] }

    private fun loadRoute() {
        val geometry = MapboxNavigationApp.current()?.getNavigationRoutes()?.firstOrNull()?.directionsRoute?.geometry()
        if (geometry == null) { coords = emptyList(); cumulative = DoubleArray(0); routeKey = ""; return }
        if (geometry.length.toString() + geometry.take(24) == routeKey) return
        routeKey = geometry.length.toString() + geometry.take(24)
        coords = LineString.fromPolyline(geometry, 6).coordinates().map { Point2(it.latitude(), it.longitude()) }
        cumulative = DoubleArray(coords.size)
        for (i in 1 until coords.size) cumulative[i] = cumulative[i - 1] + ChargePlanner.distance(coords[i - 1].lat, coords[i - 1].lng, coords[i].lat, coords[i].lng)
    }

    private fun nearest(lat: Double, lng: Double): Pair<Int, Double>? {
        if (coords.isEmpty()) return null
        var best = 0; var bestD = Double.MAX_VALUE
        coords.forEachIndexed { i, c -> val d = ChargePlanner.distance(c.lat, c.lng, lat, lng); if (d < bestD) { bestD = d; best = i } }
        return best to bestD
    }
}

/**
 * Mitfahrer und „auf meiner Karte ausblenden“ (wie Passengers.swift): Wer dicht mitfährt, wird nach Rückfrage
 * für diese Fahrt ausgeblendet. Wer mit mir verabredet ist, bleibt bis zur Ankunft am Treffpunkt sichtbar.
 */
object Passengers {
    private val ridingNow = mutableSetOf<String>()
    private val asked = mutableSetOf<String>()
    private val arrivedAt = mutableSetOf<String>()
    private val _hiddenForMe = MutableStateFlow<Set<String>>(emptySet())
    val hiddenForMe: StateFlow<Set<String>> = _hiddenForMe
    /** Ändert sich, wenn sich die ausgeblendeten Freunde ändern (für Karten) */
    private val _version = MutableStateFlow(0)
    val version: StateFlow<Int> = _version

    private fun prefs(): android.content.SharedPreferences? = AppState.appContextOrNull()?.getSharedPreferences("app", 0)

    fun load() { _hiddenForMe.value = prefs()?.getStringSet("map.hiddenFriends", emptySet()).orEmpty().toSet() }

    /** Freunde mit angenommenem Treffen, die noch nicht am Treffpunkt sind */
    val meetingPartners: Set<String> get() {
        val live = AppState.hub.positions.value
        val ids = mutableSetOf<String>()
        for (m in AppState.meetups.accepted) for (partner in AppState.meetups.partners(m)) {
            val key = "${m.id}-$partner"
            if (key in arrivedAt) continue
            val p = live[partner]
            if (p != null && m.distanceTo(p.lat, p.lng) < 100) { arrivedAt += key; continue }
            ids += partner
        }
        return ids
    }

    /** Alles, was auf meinen Karten nicht erscheint */
    val riding: Set<String> get() = (ridingNow + _hiddenForMe.value) - meetingPartners

    fun setHiddenForMe(id: String, hidden: Boolean) {
        _hiddenForMe.value = if (hidden) _hiddenForMe.value + id else { ridingNow.remove(id); _hiddenForMe.value - id }
        prefs()?.edit()?.putStringSet("map.hiddenFriends", _hiddenForMe.value)?.apply()
        _version.value++
        Diag.log("Auf meiner Karte ${if (hidden) "ausgeblendet" else "eingeblendet"}: $id")
    }

    fun setRiding(id: String, riding: Boolean) {
        if (riding) ridingNow += id else ridingNow -= id
        _version.value++
        Diag.log("Mitfahrer ${if (riding) "ausgeblendet" else "eingeblendet"}: $id")
    }

    /** Fahrt vorbei (Android Auto getrennt) */
    fun reset() { ridingNow.clear(); asked.clear(); _version.value++ }

    /** Alle 30 s: wer fährt seit ≥ 1,5 Min. zeitgleich dicht bei mir? ask gibt zurück, ob die Frage erschien */
    fun check(ask: (FriendRow) -> Boolean) {
        val r = riding
        for (f in AppState.friends.value.filter { it.isAccepted }) {
            val id = f.friendId
            if (id in r || id in asked || !SoundMoments.isCompanion(id, 3, 90.0)) continue
            if (ask(f)) asked += id
        }
    }
}
