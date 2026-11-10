package de.koeven.meeterz.sound

import android.location.Location
import android.util.Log
import de.koeven.meeterz.AppState
import de.koeven.meeterz.data.FriendRow
import de.koeven.meeterz.data.LivePosition
import de.koeven.meeterz.ev.ChargePlanner
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import java.text.DateFormat
import java.util.Date
import kotlin.math.abs

/**
 * Wann ein Sound-Pack-Moment fällig ist – dieselben Regeln wie AppModel.checkSoundMoments / checkMeetupJourneys
 * und Passengers.encounter auf iOS. Läuft bei jeder eigenen Positionsmeldung und bei jeder Aktualisierung (30 s).
 */
object SoundMoments {
    /** Hinweis für Android Auto (CarPlay: friendNotice) */
    data class Notice(val moment: SoundMoment, val friend: FriendRow, val text: String)
    private val _notices = MutableSharedFlow<Notice>(extraBufferCapacity = 8)
    val notices: SharedFlow<Notice> = _notices

    // Begegnungen: zeitgleicher Abstand je Freund (seine Position gegen meine Position zu seinem Zeitstempel)
    private data class Sample(val ts: Double, val distance: Double, val sameDirection: Boolean?, val moving: Boolean, val friendMoving: Boolean)
    private val samples = mutableMapOf<String, MutableList<Sample>>()
    private val lastEncounter = mutableMapOf<String, Long>()

    // Treffen
    private val announced = mutableSetOf<String>()
    private val meetupAway = mutableSetOf<String>()
    private val meetupDistance = mutableMapOf<String, Double>()
    private val journeyRoute = mutableMapOf<String, Boolean>()
    private val lateBaseline = mutableMapOf<String, Long>()
    private val lateAnnounced = mutableMapOf<String, Long>()
    private val lateNotified = mutableMapOf<String, Long>()

    fun reset() {
        samples.clear(); lastEncounter.clear(); announced.clear(); meetupAway.clear(); meetupDistance.clear()
        journeyRoute.clear(); lateBaseline.clear(); lateAnnounced.clear(); lateNotified.clear()
    }

    /** Kam für diesen Freund gerade (≤ 3 Min.) schon eine Verspätung? Dann wird die automatische Nachricht nicht vorgelesen. */
    fun lateRecentlyNotified(id: String) = System.currentTimeMillis() - (lateNotified[id] ?: 0) < 180_000
    fun noteLateNotified(id: String) { lateNotified[id] = System.currentTimeMillis() }

    private fun clock(seconds: Long) = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(seconds * 1000))

    private suspend fun fire(moment: SoundMoment, f: FriendRow, text: String, cooldown: Long = 0, key: String = "") {
        Log.i("Meeterz", "Moment ${moment.raw}: $text")
        _notices.tryEmit(Notice(moment, f, text))
        SoundStore.trigger(moment, f.friendId, f.firstName, cooldown, key)
    }

    // Begegnung

    private fun observe(id: String, p: LivePosition) {
        val list = samples.getOrPut(id) { mutableListOf() }
        if (list.isNotEmpty() && p.ts <= list.last().ts + 1) return
        val me = AppState.locationAt(p.ts) ?: return
        var same: Boolean? = null
        val heading = p.heading
        if (heading != null && heading >= 0 && me.hasBearing() && me.speed > 2) {
            val diff = abs(((heading - me.bearing + 540) % 360) - 180)
            same = diff < 50
        }
        list += Sample(p.ts, ChargePlanner.distance(p.lat, p.lng, me.latitude, me.longitude), same, me.speed > 4, (p.speed ?: 0.0) > 3)
        list.removeAll { p.ts - it.ts > 600 }
    }

    /** Fährt dicht mit mir (Mitfahrer): die letzten zeitgleichen Messpunkte (≥ 2) alle unter 150 m, während ich fahre */
    private fun isCompanion(id: String): Boolean {
        val close = samples[id]?.asReversed()?.takeWhile { it.distance < 150 && it.moving && it.sameDirection != false } ?: return false
        return close.size >= 2
    }

    private enum class Encounter { PASS, CATCH_UP }

    /** Gegenverkehr/kreuzend → vorbei; gleiche Richtung und vorher fahrend > 800 m weg → holt auf */
    private fun encounter(id: String): Encounter? {
        val list = samples[id] ?: return null
        val now = list.lastOrNull() ?: return null
        if (now.distance >= 300 || !now.moving || isCompanion(id)) return null
        if (now.sameDirection == false) return Encounter.PASS
        val wasFar = list.dropLast(1).any { now.ts - it.ts < 300 && it.distance > 800 && it.friendMoving }
        if (!wasFar) return null
        return if (now.sameDirection == true) Encounter.CATCH_UP else Encounter.PASS
    }

    /** Bei jeder eigenen Positionsmeldung */
    suspend fun onLocation(loc: Location) {
        AppState.recordLocation(loc)
        val myMoving = loc.speed > 3
        val now = System.currentTimeMillis()
        checkJourneys()
        val live = AppState.hub.positions.value
        for (f in AppState.friends.value.filter { it.isAccepted }) {
            val p = live[f.friendId] ?: continue
            if (p.ageSeconds >= 45) continue
            val id = f.friendId
            observe(id, p)
            val speed = p.speed ?: 0.0

            // 1. Begegnung – höchstens alle 15 Min. je Freund
            if (myMoving && speed > 3 && now - (lastEncounter[id] ?: 0) > 15 * 60_000) {
                encounter(id)?.let { e ->
                    lastEncounter[id] = now
                    if (e == Encounter.PASS) fire(SoundMoment.PASS, f, "${f.firstName} fährt gerade an dir vorbei", 15 * 60_000)
                    else fire(SoundMoment.CATCH_UP, f, "${f.firstName} fährt jetzt mit dir", 15 * 60_000)
                }
            }

            // 2./3. Treffpunkt: gleich da / angekommen – nur anstehende Treffen, nur wenn er vorher weg war
            for (m in AppState.meetups.accepted.filter { AppState.meetups.isPartner(id, it) }) {
                val at = m.meetAtSeconds
                if (at != null && abs(at - now / 1000) > 3 * 3600) continue
                val key = "${m.id}-$id"
                val d = m.distanceTo(p.lat, p.lng)
                val previous = meetupDistance[key]
                meetupDistance[key] = d
                if (d > 300) meetupAway += key
                if (key !in meetupAway) continue
                if (d < 100 && "arrived-$key" !in announced) {
                    announced += "arrived-$key"; announced += "soon-$key"
                    fire(SoundMoment.ARRIVED, f, "${f.firstName} ist am Treffpunkt angekommen", key = m.id)
                } else if (d > 150 && "soon-$key" !in announced) {
                    val route = AppState.routes.routes.value[id]?.takeIf { ChargePlanner.distance(it.destLat, it.destLng, m.lat, m.lng) < 300 }
                    val eta: Double? = when {
                        route != null -> (route.eta.epochSecond - now / 1000).toDouble()
                        speed > 2 && previous != null && d < previous - 20 -> d * 1.3 / maxOf(speed, 8.0)
                        else -> null
                    }
                    if (eta != null && eta > 0 && eta < 330) {
                        announced += "soon-$key"
                        fire(SoundMoment.SOON, f, "${f.firstName} ist in ca. 5 Min. am Treffpunkt", key = m.id)
                    }
                }
            }
        }
    }

    /** „Ist losgefahren“ und „verspätet sich“ aus den geteilten Routen der Treffpartner (auch im Stand) */
    suspend fun checkJourneys() {
        val nowS = System.currentTimeMillis() / 1000
        val friends = AppState.friends.value.associateBy { it.friendId }
        val routes = AppState.routes.routes.value
        val live = AppState.hub.positions.value
        for (m in AppState.meetups.accepted) {
            val at = m.meetAtSeconds
            if (at != null && abs(at - nowS) > 3 * 3600) continue
            for (id in AppState.meetups.partners(m)) {
                val f = friends[id] ?: continue
                val key = "${m.id}-$id"
                val route = routes[id]?.takeIf { ChargePlanner.distance(it.destLat, it.destLng, m.lat, m.lng) < 300 }
                val had = journeyRoute[key]
                journeyRoute[key] = route != null
                if (route == null) continue
                val eta = route.eta.epochSecond
                if (eta <= nowS) continue
                val baseline = lateBaseline.getOrPut(key) { eta }
                val reference = lateAnnounced[key] ?: at ?: baseline
                val isLate = eta - reference >= if (lateAnnounced[key] == null) 5 * 60 else 10 * 60

                val alreadyThere = live[id]?.let { m.distanceTo(it.lat, it.lng) < 300 } ?: false
                if (had == false && "departed-$key" !in announced && !alreadyThere) {
                    announced += "departed-$key"
                    if (!isLate) {
                        fire(SoundMoment.DEPARTED, f, "${f.firstName} ist losgefahren – Ankunft ${clock(eta)}", key = m.id)
                        continue
                    }
                }
                if (isLate) {
                    lateAnnounced[key] = eta
                    if (lateRecentlyNotified(id)) continue
                    noteLateNotified(id)
                    fire(SoundMoment.LATE, f, "${f.firstName} verspätet sich – Ankunft ${clock(eta)}", key = "${m.id}-$eta")
                }
            }
        }
    }

    /** Mein Vorschlag wurde angenommen */
    suspend fun accepted(friendId: String, meetupId: String) {
        val f = AppState.friends.value.firstOrNull { it.friendId == friendId } ?: return
        fire(SoundMoment.ACCEPTED, f, "${f.firstName} hat dein Treffen angenommen", key = meetupId)
    }
}
