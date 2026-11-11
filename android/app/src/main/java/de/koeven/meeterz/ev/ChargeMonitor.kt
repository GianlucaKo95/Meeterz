package de.koeven.meeterz.ev

import de.koeven.meeterz.Diag
import android.content.Context
import com.mapbox.navigation.base.trip.model.RouteProgress
import de.koeven.meeterz.AppState
import de.koeven.meeterz.nav.NavigationController
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Ladeplan unterwegs nachführen (wie ChargeMonitor.swift): Akku-Prognose am nächsten Stopp bzw. Ziel, und alle
 * 2 Minuten mit dem Live-Akkustand für die Reststrecke neu planen. Passt der neue Plan nicht mehr zur Route
 * (Stopp fehlt, anderer Stopp, Stopp unnötig), Vorschlag mit „Übernehmen“ – im Auto als Hinweis, auf dem Handy als Dialog.
 */
object ChargeMonitor {
    /** „Ziel 21 %“ bzw. „Stopp 18 %“; live = vom Auto gemessen statt hochgerechnet */
    data class Forecast(val label: String, val percent: Double, val low: Boolean, val live: Boolean) {
        val text get() = "${if (live) "🔋" else "≈"} $label ${maxOf(0, Math.round(percent).toInt())} %"
    }
    data class Suggestion(val title: String, val subtitle: String, val plan: ChargePlanner.Plan?)

    private val _forecast = MutableStateFlow<Forecast?>(null)
    val forecast: StateFlow<Forecast?> = _forecast
    private val _suggestions = MutableSharedFlow<Suggestion>(extraBufferCapacity = 2)
    val suggestions: SharedFlow<Suggestion> = _suggestions

    private var job: Job? = null
    private var anchorSoc = 0.0
    private var anchorTraveled = 0.0
    private var lastEstimate: Double? = null
    private var profileKey = ""
    private var profile: ChargePlanner.Profile? = null
    private var lastAlert = 0L
    private var lastSignature = ""

    fun start(context: Context) {
        stop()
        if (!EvSettings.enabled || EvSettings.vehicle == null) return
        anchorSoc = EvSettings.chargePercent
        anchorTraveled = 0.0
        lastEstimate = null
        job = AppState.scope.launch {
            var tick = 0
            while (isActive) {
                delay(10_000)
                runCatching { updateForecast() }.onFailure { Diag.log("Akku-Prognose: ${it.message}") }
                if (++tick % 12 == 0) runCatching { check(context) }.onFailure { Diag.log("Ladeplan unterwegs: ${it.message}") }
            }
        }
    }

    fun stop() {
        job?.cancel(); job = null
        profile = null; profileKey = ""; lastSignature = ""
        _forecast.value = null
    }

    private fun pct(kwh: Double) = kwh / (EvSettings.vehicle?.battery ?: 1.0) * 100

    /** Ende des aktuellen Abschnitts (m ab Start der Route): Zwischenziel bzw. Ziel */
    private fun legEnd(progress: RouteProgress): Pair<Double, Boolean> {
        val legs = progress.navigationRoute.directionsRoute.legs().orEmpty()
        val index = progress.currentLegProgress?.legIndex ?: 0
        val end = legs.take(index + 1).sumOf { it.distance() ?: 0.0 }
        return end to (index >= legs.size - 1)
    }

    private suspend fun updateForecast() {
        val vehicle = EvSettings.vehicle ?: return
        val progress = NavigationController.progress.value ?: return
        val route = progress.navigationRoute
        val points = EvSettings.points(route)
        val traveled = progress.distanceTraveled.toDouble()
        val conditions = RouteConditions.load(route.id, points)
        // Höhe und Wetter, sobald geladen (dann einmal neu rechnen)
        val key = "${route.id}-${conditions != null}"
        if (key != profileKey) {
            val settings = EvSettings.plannerSettings().copy(conditions = conditions)
            profile = withContext(Dispatchers.Default) { ChargePlanner.profile(points, vehicle, settings) }
            // Neue Route (auch nach Neuberechnung): ab dem zuletzt geschätzten Stand weiterrechnen
            if (profileKey.isNotEmpty()) lastEstimate?.let { anchorSoc = it }
            anchorTraveled = traveled
            profileKey = key
        }
        val p = profile ?: return
        val status = AppState.vehicle.status.value
        val live = if ((status?.ageSeconds ?: Long.MAX_VALUE) < 5 * 60) EvSettings.liveSoc else null
        if (live != null) { anchorSoc = live; anchorTraveled = traveled }
        val now = anchorSoc - pct(p.energy(anchorTraveled, maxOf(traveled, anchorTraveled)))
        lastEstimate = now
        val (end, last) = legEnd(progress)
        val arrival = now - pct(p.energy(traveled, end))
        val limit = if (last) EvSettings.arrivalPercent else EvSettings.minAtChargerPercent
        _forecast.value = Forecast(if (last) "Ziel" else "Stopp", arrival, arrival < limit, live != null)
    }

    private suspend fun check(context: Context) {
        val soc = EvSettings.liveSoc ?: return
        val status = AppState.vehicle.status.value ?: return
        if (status.ageSeconds >= 4 * 60) return                                    // nur mit frischem Live-Wert
        val progress = NavigationController.progress.value ?: return
        val route = progress.navigationRoute
        val result = EvSettings.plan(route, soc, progress.distanceTraveled.toDouble()) ?: return
        // Inzwischen andere Route oder beendet: kein Hinweis zu einer Route, die es nicht mehr gibt
        if (NavigationController.progress.value?.navigationRoute?.id != route.id) return

        // Zwischenziele der laufenden Route, die noch vor mir liegen (bereits übernommene Ladestopps)
        val coords = route.directionsRoute.routeOptions()?.coordinatesList().orEmpty()
        val legIndex = progress.currentLegProgress?.legIndex ?: 0
        val upcoming = if (coords.size > 2) coords.subList(minOf(legIndex + 1, coords.size - 1), coords.size - 1) else emptyList()

        val message = when (result) {
            is ChargePlanner.Outcome.Unreachable ->
                Suggestion("Akku reicht nicht bis zum Ziel", "Reichweite ca. ${result.reachKm.toInt()} km", null)
            is ChargePlanner.Outcome.Planned -> {
                val plan = result.plan
                val matches = plan.stops.size == upcoming.size && plan.stops.zip(upcoming).all { (s, u) ->
                    ChargePlanner.distance(s.site.lat, s.site.lng, u.latitude(), u.longitude()) < 600
                }
                when {
                    matches || (plan.direct && upcoming.isEmpty()) -> null
                    plan.direct -> Suggestion("Ladestopp nicht mehr nötig", "Ankunft mit ${Math.round(plan.arrivalPercent)} % auch ohne Laden", plan)
                    else -> Suggestion("Neuer Ladeplan: ${plan.summary}",
                        "Nächster Stopp: ${plan.stops[0].site.title} in ${(plan.stops[0].distanceFromStart / 1000).toInt()} km", plan)
                }
            }
        } ?: return
        // Nicht dauernd melden: gleicher Vorschlag nur einmal, sonst höchstens alle 10 Minuten
        val signature = message.title + (message.plan?.stops?.joinToString { "${it.site.lat}" } ?: "")
        if (signature == lastSignature || System.currentTimeMillis() - lastAlert < 10 * 60_000) return
        lastSignature = signature
        lastAlert = System.currentTimeMillis()
        Diag.log("Ladeplan unterwegs (${soc.toInt()} %): ${message.title}")
        _suggestions.tryEmit(message)
    }

    /** Vorschlag übernehmen: Route ab hier über die neuen Stopps (oder ohne Stopp) */
    suspend fun adopt(context: Context, plan: ChargePlanner.Plan): Boolean {
        val ok = NavigationController.reroute(context, plan.stops.map { com.mapbox.geojson.Point.fromLngLat(it.site.lng, it.site.lat) })
        if (ok) ChargingSession.plan = plan
        return ok
    }
}
