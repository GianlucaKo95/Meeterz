package de.koeven.meeterz.data

import io.github.jan.supabase.postgrest.postgrest
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.time.Instant

/** Aktive Routen der Freunde (RPC friends_routes, wie RoutesStore auf iOS) */
data class FriendRoute(
    val friendId: String,
    val destinationName: String?,
    val destLat: Double,
    val destLng: Double,
    val eta: Instant,
    /** [lng, lat] */
    val coordinates: List<Pair<Double, Double>>,
)

class FriendRoutesStore {
    @Serializable
    private data class Row(
        val friend_id: String,
        val destination_name: String? = null,
        val dest_lat: Double,
        val dest_lng: Double,
        val eta: String,
        val path_geojson: String,
    )

    private val _routes = MutableStateFlow<Map<String, FriendRoute>>(emptyMap())
    val routes: StateFlow<Map<String, FriendRoute>> = _routes
    private val json = Json { ignoreUnknownKeys = true }

    suspend fun refresh() {
        runCatching { Backend.client.postgrest.rpc("friends_routes").decodeList<Row>() }.onSuccess { rows ->
            _routes.value = rows.mapNotNull { r ->
                val coords = runCatching {
                    json.parseToJsonElement(r.path_geojson).jsonObject["coordinates"]!!.jsonArray.mapNotNull { c ->
                        val a = c.jsonArray
                        if (a.size >= 2) a[0].jsonPrimitive.double to a[1].jsonPrimitive.double else null
                    }
                }.getOrNull() ?: return@mapNotNull null
                val eta = runCatching { Instant.parse(r.eta) }.getOrNull() ?: return@mapNotNull null
                r.friend_id to FriendRoute(r.friend_id, r.destination_name, r.dest_lat, r.dest_lng, eta, coords)
            }.toMap()
        }
    }
}
