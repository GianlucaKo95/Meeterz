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
    @SerialName("reported_at") val reportedAt: String? = null,
    @SerialName("updated_at") val updatedAt: String,
) {
    /** Alter der Messung in Sekunden (nie negativ) */
    val ageSeconds: Long get() {
        val at = runCatching { Instant.parse(reportedAt ?: updatedAt) }.getOrNull() ?: return Long.MAX_VALUE
        return maxOf(0, Instant.now().epochSecond - at.epochSecond)
    }
}

class VehicleStore {
    private val _status = MutableStateFlow<VehicleStatus?>(null)
    val status: StateFlow<VehicleStatus?> = _status

    suspend fun refresh(userId: String) {
        runCatching {
            Backend.client.from("vehicle_status").select { filter { eq("user_id", userId) } }.decodeList<VehicleStatus>()
        }.onSuccess { _status.value = it.firstOrNull() }
    }
}
