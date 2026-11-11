package de.koeven.meeterz.ev

import android.content.Context
import android.content.SharedPreferences
import com.mapbox.geojson.utils.PolylineUtils
import com.mapbox.navigation.base.route.NavigationRoute
import de.koeven.meeterz.AppState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json

/** Einstellungen des E-Autos und Ladeplan für eine Route (wie EVSettings auf iOS) */
object EvSettings {
    private lateinit var prefs: SharedPreferences
    private lateinit var appContext: Context
    private val json = Json { ignoreUnknownKeys = true }

    /** Ändert sich, wenn Einstellungen geändert werden (Oberfläche rechnet dann neu) */
    val version = MutableStateFlow(0)

    fun init(context: Context) {
        appContext = context.applicationContext
        prefs = context.getSharedPreferences("ev", Context.MODE_PRIVATE)
    }

    private fun changed() { version.value++ }

    var enabled: Boolean
        get() = prefs.getBoolean("enabled", false)
        set(v) { prefs.edit().putBoolean("enabled", v).apply(); changed() }

    var vehicle: EvVehicle?
        get() = prefs.getString("vehicle", null)?.let { runCatching { json.decodeFromString<EvVehicle>(it) }.getOrNull() }
        set(v) { prefs.edit().putString("vehicle", v?.let { json.encodeToString(EvVehicle.serializer(), it) }).apply(); changed() }

    /** Gewünschter Akkustand bei Ankunft (%) */
    var arrivalPercent: Double
        get() = prefs.getFloat("arrival", 20f).toDouble()
        set(v) { prefs.edit().putFloat("arrival", v.toFloat()).apply(); changed() }

    /** Mindestens an der Ladesäule (%) */
    var minAtChargerPercent: Double
        get() = prefs.getFloat("minCharger", 10f).toDouble()
        set(v) { prefs.edit().putFloat("minCharger", v.toFloat()).apply(); changed() }

    /** Akkustand von Hand (wenn das Auto keine Live-Daten liefert) */
    var manualPercent: Double
        get() = prefs.getFloat("charge", 80f).toDouble()
        set(v) { prefs.edit().putFloat("charge", v.toFloat()).apply(); changed() }

    /** Live-Akkustand vom Auto (wie iOS: Meldung höchstens 7 Tage alt) */
    val liveSoc: Double? get() = AppState.vehicle.status.value?.takeIf { it.ageSeconds < 7 * 86_400 }?.soc?.takeIf { it in 0.0..100.0 }

    val chargePercent: Double get() = liveSoc ?: manualPercent

    fun vehicles() = EvData.vehicles(appContext)

    /** Formpunkte der Route mit Strecke, Zeit und Tempo je Schritt (wie ChargePlanner.points(of:) auf iOS) */
    fun points(route: NavigationRoute): List<ChargePlanner.RoutePoint> {
        val out = mutableListOf<ChargePlanner.RoutePoint>()
        var d = 0.0; var t = 0.0
        for (leg in route.directionsRoute.legs().orEmpty()) for (step in leg.steps().orEmpty()) {
            val geometry = step.geometry() ?: continue
            val shape = runCatching { PolylineUtils.decode(geometry, 6) }.getOrNull() ?: continue
            if (shape.size < 2 || step.distance() <= 0) continue
            val kmh = if (step.duration() > 0) step.distance() / step.duration() * 3.6 else 50.0
            val secondsPerMeter = step.duration() / step.distance()
            var shapeLen = 0.0
            for ((a, b) in shape.zipWithNext()) shapeLen += ChargePlanner.distance(a.latitude(), a.longitude(), b.latitude(), b.longitude())
            val scale = if (shapeLen > 0) step.distance() / shapeLen else 1.0
            if (out.isEmpty()) out += ChargePlanner.RoutePoint(shape[0].latitude(), shape[0].longitude(), 0.0, 0.0, kmh)
            for ((a, b) in shape.zipWithNext()) {
                val m = ChargePlanner.distance(a.latitude(), a.longitude(), b.latitude(), b.longitude()) * scale
                d += m; t += m * secondsPerMeter
                out += ChargePlanner.RoutePoint(b.latitude(), b.longitude(), d, t, kmh)
            }
        }
        return out
    }

    /**
     * Einstellungen wie EVSettings.plannerSettings auf iOS: gelernter Verbrauch, Außentemperatur nur aus frischen
     * Fahrdaten (geparkt liefert das Auto teils 0 °C). Mit `points` kommen Live-Belegung, Höhe und Wetter dazu.
     */
    suspend fun plannerSettings(key: String? = null, points: List<ChargePlanner.RoutePoint>? = null): ChargePlanner.Settings {
        val status = AppState.vehicle.status.value
        val temperature = status?.takeIf { it.parked != true && it.ageSeconds < 3 * 3600 }?.extTemp
        return ChargePlanner.Settings(
            arrivalPercent = arrivalPercent, minAtChargerPercent = minAtChargerPercent, temperature = temperature,
            factors = vehicle?.let { ConsumptionLearner.factors(it) } ?: listOf(1.0, 1.0, 1.0),
            conditions = if (key != null && points != null) RouteConditions.load(key, points) else null,
            availability = if (points != null) ChargeStatusService.availability(appContext, points) else emptyMap(),
        )
    }

    /** Ladeplan für eine Route (null ohne E-Auto/Fahrzeug); ab `fromMeters` mit `startPercent` (Neuplanung unterwegs) */
    suspend fun plan(route: NavigationRoute, startPercent: Double = chargePercent, fromMeters: Double = 0.0,
                     fixed: List<ChargePlanner.Candidate> = emptyList()): ChargePlanner.Outcome? {
        if (!enabled) return null
        val vehicle = vehicle ?: return null
        val points = points(route)
        val settings = plannerSettings(route.id, points).copy(fixed = fixed)
        return withContext(Dispatchers.Default) {
            val profile = ChargePlanner.profile(points, vehicle, settings).suffix(fromMeters)
            ChargePlanner.plan(profile, vehicle, startPercent, settings, EvData.sites(appContext))
        }
    }
}
