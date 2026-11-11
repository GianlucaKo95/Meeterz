package de.koeven.meeterz.data

import io.github.jan.supabase.postgrest.from
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.Instant

/** Live-Daten des Autos aus vehicle_status (vom Home-Assistant-Add-on) – wie VehicleStore auf iOS */
@Serializable
data class VehicleStatus(
    val soc: Double? = null,
    @SerialName("range_km") val rangeKm: Double? = null,
    val charging: Boolean? = null,
    @SerialName("power_kw") val powerKw: Double? = null,
    @SerialName("charge_target_percent") val chargeTarget: Double? = null,
    @SerialName("ext_temp") val extTemp: Double? = null,
    @SerialName("odometer_km") val odometerKm: Double? = null,
    @SerialName("speed_kmh") val speedKmh: Double? = null,
    val parked: Boolean? = null,
    val lat: Double? = null,
    val lng: Double? = null,
    /** Restladezeit laut Auto (s) und wann gemeldet */
    @SerialName("charge_remaining_s") val chargeRemainingS: Double? = null,
    @SerialName("charge_remaining_at") val chargeRemainingAt: String? = null,
    @SerialName("reported_at") val reportedAt: String? = null,
    @SerialName("updated_at") val updatedAt: String,
) {
    /** Wann im Auto gemessen (Unix-Sekunden) */
    val measuredAt: Long get() = runCatching { Instant.parse(reportedAt ?: updatedAt).epochSecond }.getOrDefault(0)

    /** Ladeziel laut Auto (40–100 %) */
    val carChargeTarget: Double? get() = chargeTarget?.takeIf { it in 40.0..100.0 }

    /** Restladezeit laut Auto (s ab jetzt), wenn höchstens 15 Minuten alt */
    val liveChargeRemaining: Double? get() {
        val s = chargeRemainingS?.takeIf { it > 0 } ?: return null
        val at = chargeRemainingAt?.let { runCatching { Instant.parse(it).epochSecond }.getOrNull() } ?: return null
        val elapsed = Instant.now().epochSecond - at
        return if (elapsed < 15 * 60) maxOf(0.0, s - elapsed) else null
    }

    /** Alter der Messung in Sekunden (nie negativ) */
    val ageSeconds: Long get() {
        val at = runCatching { Instant.parse(reportedAt ?: updatedAt) }.getOrNull() ?: return Long.MAX_VALUE
        return maxOf(0, Instant.now().epochSecond - at.epochSecond)
    }
}

class VehicleStore {
    private val _status = MutableStateFlow<VehicleStatus?>(null)
    val status: StateFlow<VehicleStatus?> = _status

    private var feed: de.koeven.meeterz.live.RealtimeFeed? = null

    /** Live-Kanal auf vehicle_status (wie iOS) statt Abfragen im 30-s-Takt */
    fun start(scope: kotlinx.coroutines.CoroutineScope, userId: String) {
        if (feed != null) return
        feed = de.koeven.meeterz.live.RealtimeFeed(scope, "vehicle-$userId", "vehicle_status", "user_id", userId) { refresh(userId) }
            .also { it.start() }
    }

    fun stop() { feed?.stop(); feed = null; _status.value = null }

    suspend fun refresh(userId: String) {
        runCatching {
            Backend.client.from("vehicle_status").select { filter { eq("user_id", userId) } }.decodeList<VehicleStatus>()
        }.onSuccess { rows ->
            val new = rows.firstOrNull() ?: return@onSuccess
            val old = _status.value
            _status.value = new
            // Neue Meldung: Verbrauch lernen und Laden verfolgen (wie iOS bei jeder Live-Meldung)
            if (old == null || new.measuredAt != old.measuredAt) {
                if (old != null) de.koeven.meeterz.ev.ConsumptionLearner.record(old, new)
                de.koeven.meeterz.ev.ChargingSession.update(new)
                de.koeven.meeterz.suggest.Parking.vehicleUpdate(new)
            }
        }
    }
}
