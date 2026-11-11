package de.koeven.meeterz.ev

import de.koeven.meeterz.tr
import android.content.Context
import android.content.SharedPreferences
import de.koeven.meeterz.data.VehicleStatus
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

/**
 * Lernt den echten Verbrauch aus den Live-Fahrzeugdaten (wie ConsumptionLearner.swift): zwischen zwei Meldungen
 * Kilometerstand- und Akkustand-Differenz, je Tempobereich. Ergebnis: Korrekturfaktor gegenüber dem Modell.
 */
object ConsumptionLearner {
    /** Ab so vielen Kilometern in einem Bereich gilt der gelernte Wert */
    const val MIN_KM = 25.0
    val bandNames = listOf(tr("Stadt"), tr("Landstraße"), tr("Autobahn"))

    @Serializable
    data class Bucket(val km: Double = 0.0, val measured: Double = 0.0, val modeled: Double = 0.0) {
        val factor: Double? get() = if (km >= MIN_KM && modeled > 0) (measured / modeled).coerceIn(0.65, 1.5) else null
        val per100: Double? get() = if (km > 0) measured / km * 100 else null
    }

    private lateinit var prefs: SharedPreferences
    private val serializer = ListSerializer(Bucket.serializer())

    fun init(context: Context) { prefs = context.getSharedPreferences("ev-learned", Context.MODE_PRIVATE) }

    fun buckets(vehicle: EvVehicle): List<Bucket> =
        prefs.getString(vehicle.id, null)?.let { runCatching { Json.decodeFromString(serializer, it) }.getOrNull() }
            ?.takeIf { it.size == 3 } ?: List(3) { Bucket() }

    /** Faktoren je Bereich; fehlt einer, gilt der Mittelwert der gelernten, sonst 1 */
    fun factors(vehicle: EvVehicle): List<Double> {
        val b = buckets(vehicle)
        val known = b.mapNotNull { it.factor }
        val fallback = if (known.isEmpty()) 1.0 else known.average()
        return b.map { it.factor ?: fallback }
    }

    /** Zwei aufeinanderfolgende Meldungen auswerten (nur während der Fahrt, nicht beim Laden) */
    fun record(a: VehicleStatus, b: VehicleStatus) {
        if (!EvSettings.enabled) return
        val vehicle = EvSettings.vehicle ?: return
        val socA = a.soc ?: return; val socB = b.soc ?: return
        val kmA = a.odometerKm ?: return; val kmB = b.odometerKm ?: return
        if (a.charging == true || b.charging == true) return
        val km = kmB - kmA
        val seconds = (b.measuredAt - a.measuredAt).toDouble()
        // Plausibel: 0,3–30 km in höchstens 15 Minuten, Akku nicht gestiegen
        if (km < 0.3 || km > 30 || seconds <= 20 || seconds >= 15 * 60 || socB > socA + 0.5) return
        val kmh = km / (seconds / 3600)
        if (kmh <= 5 || kmh >= 220) return
        val measured = (socA - socB) / 100 * vehicle.battery
        val modeled = ChargePlanner.consumption(kmh, vehicle.consumption, b.extTemp ?: a.extTemp) * km
        val all = buckets(vehicle).toMutableList()
        val i = ChargePlanner.band(kmh)
        all[i] = Bucket(all[i].km + km, all[i].measured + measured, all[i].modeled + modeled)
        prefs.edit().putString(vehicle.id, Json.encodeToString(serializer, all)).apply()
    }

    fun reset(vehicle: EvVehicle) { prefs.edit().remove(vehicle.id).apply() }
}
