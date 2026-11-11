package de.koeven.meeterz.nav

import de.koeven.meeterz.tr
import com.mapbox.navigation.base.trip.model.RouteProgress
import com.mapbox.navigation.base.trip.model.roadobject.incident.Incident
import com.mapbox.navigation.base.trip.model.roadobject.incident.IncidentImpact
import com.mapbox.navigation.base.trip.model.roadobject.incident.IncidentType
import de.koeven.meeterz.AppState
import de.koeven.meeterz.Diag
import de.koeven.meeterz.ev.ChargePlanner
import de.koeven.meeterz.ui.km
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * Unfälle, Sperrungen und schwere Staus voraus melden, einmal je Ereignis (wie IncidentWatcher.swift).
 * Die Daten liefert Mapbox mit der Route (`upcomingRoadObjects`, Entfernung vom aktuellen Standort).
 */
object IncidentWatcher {
    data class Alert(val title: String, val subtitle: String?)
    private val _alerts = MutableSharedFlow<Alert>(extraBufferCapacity = 4)
    /** Für Handy (Hinweis) und Android Auto (Hinweis) – vorgelesen wird hier */
    val alerts: SharedFlow<Alert> = _alerts
    private val announced = mutableSetOf<String>()

    fun reset() = announced.clear()

    private data class Message(val title: String, val subtitle: String?, val closure: Boolean)

    fun check(progress: RouteProgress) {
        for (upcoming in progress.upcomingRoadObjects) {
            val incident = upcoming.roadObject as? Incident ?: continue
            val info = incident.info
            if (info.id in announced) continue
            val message = message(info, incident.length) ?: continue
            val distance = upcoming.distanceToStart ?: continue
            // Sperrungen früh (bis 15 km), sonst bis 6 km; unter 300 m ist es zu spät für einen Hinweis
            val horizon = if (message.closure) 15_000.0 else 6_000.0
            if (distance <= 300) { announced += info.id; continue }
            if (distance >= horizon) continue
            announced += info.id
            val title = "${message.title} in ${km(distance)}"
            Diag.log("Verkehrsmeldung: $title${message.subtitle?.let { " – $it" } ?: ""}")
            _alerts.tryEmit(Alert(title, message.subtitle))
            NavigationController.announce(tr("Achtung, %@ in %@.", message.title, if (de.koeven.meeterz.L10n.language == "de") spoken(distance) else km(distance)))
            return   // höchstens eine Meldung auf einmal
        }
    }

    private fun message(info: com.mapbox.navigation.base.trip.model.roadobject.incident.IncidentInfo, length: Double?): Message? {
        val road = info.affectedRoadNames?.firstOrNull()
        val lanes = info.lanesBlocked.size
        val lengthText = length?.takeIf { it > 300 }?.let { tr("%@ lang", km(it)) }
        val severe = info.impact == IncidentImpact.MAJOR || info.impact == IncidentImpact.CRITICAL
        if (info.isClosed || info.type == IncidentType.ROAD_CLOSURE) return Message(tr("Sperrung"), road?.let { tr("%@ gesperrt", it) } ?: tr("Straße gesperrt"), true)
        return when (info.type) {
            IncidentType.ACCIDENT -> Message(tr("Unfall"), if (lanes > 0) tr("%lld Fahrstreifen blockiert", lanes) else road, false)
            IncidentType.DISABLED_VEHICLE -> Message(tr("Liegengebliebenes Fahrzeug"), road, false)
            IncidentType.ROAD_HAZARD -> Message(tr("Gefahr auf der Fahrbahn"), road, false)
            IncidentType.CONGESTION -> if (severe) Message(tr("Stau"), listOfNotNull(lengthText, road).joinToString(" · ").ifEmpty { null }, false) else null
            IncidentType.CONSTRUCTION -> if (lanes > 0 || severe) Message(tr("Baustelle"), if (lanes > 0) tr("%lld Fahrstreifen gesperrt", lanes) else road, false) else null
            IncidentType.WEATHER -> if (severe) Message(tr("Wettergefahr"), road, false) else null
            else -> null
        }
    }

    /** „3 Kilometern“, „800 Metern“ – Dativ für die Ansage („Achtung, Stau in 3 Kilometern“) */
    fun spoken(meters: Double): String {
        if (meters >= 1_000) {
            val k = Math.round(meters / 1_000)
            return if (k == 1L) "einem Kilometer" else "$k Kilometern"
        }
        return "${Math.round(meters / 100) * 100} Metern"
    }
}

/**
 * „Vorfahrt achten“ / „Stopp“ kurz vor dem Schild einblenden, ohne Ansage (wie RightOfWaySigns.swift).
 * Angaben aus den Kreuzungen der Route, darum nur während einer Führung.
 */
object RightOfWaySigns {
    data class Sign(val stop: Boolean, val distance: Double, val lat: Double, val lng: Double)
    const val SHOW_WITHIN = 150.0
    private val _sign = MutableStateFlow<Sign?>(null)
    val sign: StateFlow<Sign?> = _sign

    fun clear() { _sign.value = null }

    fun update(progress: RouteProgress) {
        val next = upcoming(progress)
        if ((next == null) != (_sign.value == null) || next?.stop != _sign.value?.stop) {
            next?.let { Diag.log("Schild eingeblendet: ${if (it.stop) "Stopp" else "Vorfahrt achten"} in ${it.distance.toInt()} m") }
        }
        _sign.value = next
    }

    private fun upcoming(progress: RouteProgress): Sign? {
        val here = AppState.lastLocation ?: return null
        val leg = progress.currentLegProgress ?: return null
        val step = leg.currentStepProgress ?: return null
        val all = step.step?.intersections().orEmpty()
        val ahead = all.drop(minOf(step.intersectionIndex + 1, all.size)) + leg.upcomingStep?.intersections().orEmpty().drop(1)
        for (x in ahead) {
            val p = x.location()
            val d = ChargePlanner.distance(here.latitude, here.longitude, p.latitude(), p.longitude())
            if (d > 2 * SHOW_WITHIN) break
            if (d > SHOW_WITHIN) continue
            if (x.stopSign() == true) return Sign(true, d, p.latitude(), p.longitude())
            if (x.yieldSign() == true) return Sign(false, d, p.latitude(), p.longitude())
        }
        return null
    }
}
