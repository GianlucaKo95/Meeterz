package de.koeven.meeterz.social

import de.koeven.meeterz.AppState
import de.koeven.meeterz.Diag
import de.koeven.meeterz.ev.ChargePlanner
import de.koeven.meeterz.ev.EvData
import de.koeven.meeterz.ev.EvSettings
import de.koeven.meeterz.nav.NavigationController
import de.koeven.meeterz.nav.PlaceSearch
import de.koeven.meeterz.tr
import de.koeven.meeterz.ui.km
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.jsonObject
import java.util.UUID

/**
 * Konvoi-Pause (wie ConvoyPause.swift): Jemand tippt „Pause vorschlagen“, Meeterz wählt selbst einen Halt, den alle im
 * Konvoi noch vor sich haben – mit Ladesäule, sobald einer ein E-Auto fährt. Die anderen bekommen „Dabei“ / „Nein“;
 * wer zusagt, bekommt den Halt als Zwischenstopp. Übertragen über die Standort-Kanäle (Ereignisse „pause“, „pause_reply“).
 */
object ConvoyPause {
    @Serializable
    data class Proposal(val id: String, val from: String, val fromName: String, val name: String, val lat: Double, val lng: Double,
                        val charger: Boolean, val kw: Double? = null, val members: List<String>, val ts: Double)

    @Serializable
    data class Reply(val id: String, val userId: String, val accept: Boolean)

    private val _prompt = MutableStateFlow<Proposal?>(null)
    /** Offener Vorschlag (Android Auto zeigt ihn als Hinweis, sonst das Handy als Dialog) */
    val prompt: StateFlow<Proposal?> = _prompt
    private val _notices = MutableSharedFlow<String>(extraBufferCapacity = 4)
    val notices: SharedFlow<String> = _notices

    private val handled = mutableSetOf<String>()
    private var mine: Proposal? = null
    @Volatile private var proposing = false
    private val json = Json { encodeDefaults = true }

    // Vorschlagen

    suspend fun propose() {
        if (proposing) return
        proposing = true
        try {
            val members = Convoy.members()
            val me = AppState.profile
            if (NavigationController.guidance.value == null || me == null || members.isEmpty()) {
                notice(tr("Gerade fährt niemand mit dir im Konvoi.")); return
            }
            val route = Convoy.routeProfile() ?: run { notice(tr("Keine Route für die Pause gefunden.")); return }
            // Erreichbar für alle: hinter dem, der am weitesten vorn ist, mit 3 km Luft zum Abfahren
            val lead = maxOf(0.0, members.mapNotNull { it.gap }.maxOrNull() ?: 0.0)
            val total = route.cumulative.lastOrNull() ?: 0.0
            val start = route.mine + lead + 3_000
            val end = minOf(total - 2_000, start + 80_000)
            if (end <= start) { notice(tr("Bis zum Ziel ist kein Platz mehr für eine Pause.")); return }
            val live = AppState.hub.positions.value
            val ev = (EvSettings.enabled && EvSettings.vehicle != null) || members.any { live[it.friend.friendId]?.ev == true }
            Diag.log("Konvoi-Pause: suche ${if (ev) "Ladesäule" else "Rastplatz"} zwischen ${(start / 1000).toInt()} und ${(end / 1000).toInt()} km (Vorsprung ${lead.toInt()} m)")

            val pick = if (ev) chargeStop(route, start, end) else restStop(route, start, end)
            if (pick == null) {
                notice(if (ev) tr("Keine Ladesäule auf der Strecke gefunden, die alle noch erreichen.")
                       else tr("Kein Rastplatz auf der Strecke gefunden, den alle noch erreichen."))
                return
            }
            val p = Proposal(UUID.randomUUID().toString(), me.id.lowercase(), me.displayName, pick.name, pick.lat, pick.lng, ev, pick.kw,
                members.map { it.friend.friendId.lowercase() }, System.currentTimeMillis() / 1000.0)
            mine = p
            handled += p.id
            AppState.hub.broadcast("pause", json.encodeToJsonElement(p).jsonObject)
            Diag.log("Konvoi-Pause vorgeschlagen: ${pick.name} an ${members.size} Mitfahrende")
            AppState.appContextOrNull()?.let { NavigationController.addStop(it, p.name, p.lat, p.lng) }
            notice(tr("Pause vorgeschlagen: %@", pick.name))
        } finally { proposing = false }
    }

    private class Pick(val name: String, val lat: Double, val lng: Double, val kw: Double?)

    /** Schnelllader (≥ 50 kW, bevorzugt ≥ 100 kW) höchstens 800 m neben der Strecke – der erste, den alle erreichen */
    private fun chargeStop(route: Convoy.Profile, start: Double, end: Double): Pick? {
        val context = AppState.appContextOrNull() ?: return null
        val idx = route.cumulative.indices.filter { route.cumulative[it] in start..end }
        if (idx.isEmpty()) return null
        val minLat = idx.minOf { route.lats[it] } - 0.01; val maxLat = idx.maxOf { route.lats[it] } + 0.01
        val minLng = idx.minOf { route.lngs[it] } - 0.015; val maxLng = idx.maxOf { route.lngs[it] } + 0.015
        val found = EvData.sites(context).asSequence()
            .filter { it.plannedKW >= 50 && it.lat in minLat..maxLat && it.lng in minLng..maxLng }
            .mapNotNull { s -> Convoy.along(s.lat, s.lng, 800.0)?.takeIf { it in start..end }?.let { s to it } }
            .toList()
        val best = found.filter { it.first.maxKW >= 100 }.minByOrNull { it.second } ?: found.minByOrNull { it.second }
        return best?.let { (s, _) -> Pick(s.title, s.lat, s.lng, if (s.powerKnown) s.maxKW else null) }
    }

    /** Raststätte (sonst Tankstelle) höchstens 800 m neben der Strecke – die erste, die alle erreichen */
    private suspend fun restStop(route: Convoy.Profile, start: Double, end: Double): Pick? {
        fun point(meters: Double): Pair<Double, Double>? {
            val i = route.cumulative.indexOfFirst { it >= meters }.takeIf { it >= 0 } ?: return null
            return route.lats[i] to route.lngs[i]
        }
        val found = mutableListOf<Pair<PlaceSearch.Place, Double>>()
        for (category in listOf(PlaceSearch.Category.REST_AREA, PlaceSearch.Category.GAS)) {
            for (offset in listOf(8_000.0, 25_000.0, 50_000.0)) {
                if (start + offset - 8_000 >= end) continue
                val (lat, lng) = point(minOf(start + offset, end)) ?: continue
                for (p in PlaceSearch.places(category, lat, lng, 10)) {
                    Convoy.along(p.lat, p.lng, 800.0)?.takeIf { it in start..end }?.let { found += p to it }
                }
                if (found.isNotEmpty()) break
            }
            if (found.isNotEmpty()) break
        }
        return found.minByOrNull { it.second }?.first?.let { Pick(it.name, it.lat, it.lng, null) }
    }

    // Empfangen

    fun received(p: Proposal) {
        val me = AppState.myId?.lowercase() ?: return
        if (p.members.none { it.equals(me, true) } || p.id in handled || System.currentTimeMillis() / 1000.0 - p.ts > 15 * 60) return
        handled += p.id
        Diag.log("Konvoi-Pause von ${p.fromName}: ${p.name}")
        _prompt.value = p
    }

    fun received(r: Reply) {
        if (r.id != mine?.id) return
        val f = AppState.friends.value.firstOrNull { it.friendId.equals(r.userId, true) } ?: return
        notice(if (r.accept) tr("%@ ist bei der Pause dabei", f.firstName) else tr("%@ fährt weiter", f.firstName))
    }

    /** „Dabei“: Halt als Zwischenstopp; Antwort an alle Freunde (der Vorschlagende hört mit) */
    fun answer(p: Proposal, accept: Boolean) {
        if (_prompt.value?.id != p.id) return   // schon beantwortet (Auto oder Handy)
        _prompt.value = null
        val me = AppState.myId ?: return
        AppState.scope.launch {
            AppState.hub.broadcast("pause_reply", json.encodeToJsonElement(Reply(p.id, me.lowercase(), accept)).jsonObject)
            Diag.log("Konvoi-Pause ${if (accept) "angenommen" else "abgelehnt"}: ${p.name}")
            if (accept) AppState.appContextOrNull()?.let { NavigationController.addStop(it, p.name, p.lat, p.lng) }
        }
    }

    fun title(p: Proposal) = tr("%@ schlägt eine Pause vor", p.fromName.substringBefore(" "))

    /** „Raststätte Garbsen · 18 km · Schnelllader 150 kW“ */
    fun subtitle(p: Proposal): String = listOfNotNull(
        p.name,
        AppState.lastLocation?.let { km(ChargePlanner.distance(it.latitude, it.longitude, p.lat, p.lng)) },
        if (p.charger) p.kw?.let { tr("Schnelllader %lld kW", it.toInt()) } ?: tr("mit Ladesäule") else null,
    ).joinToString(" · ")

    private fun notice(text: String) { _notices.tryEmit(text) }
}
