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

    private val _ended = kotlinx.coroutines.flow.MutableSharedFlow<String>(extraBufferCapacity = 4)
    /** „Annika fährt nicht mehr hierher“ – für Handy und Android Auto (wie iOS) */
    val ended: kotlinx.coroutines.flow.SharedFlow<String> = _ended
    private var loaded = false

    /** Freund fuhr zu meinem Ziel oder unserem Treffpunkt, seine Route ist weg und er ist nicht dort angekommen */
    private fun noticeEnded(old: Map<String, FriendRoute>, new: Map<String, FriendRoute>) {
        if (!loaded) { loaded = true; return }
        val targets = de.koeven.meeterz.AppState.meetups.accepted.map { it.lat to it.lng } +
            listOfNotNull(de.koeven.meeterz.nav.NavigationController.guidance.value?.destination?.let { it.lat to it.lng })
        val dist = de.koeven.meeterz.ev.ChargePlanner::distance
        for ((id, r) in old) {
            if (id in new || targets.none { dist(it.first, it.second, r.destLat, r.destLng) < 300 }) continue
            val friend = de.koeven.meeterz.AppState.friends.value.firstOrNull { it.friendId == id } ?: continue
            val pos = de.koeven.meeterz.AppState.hub.positions.value[id]
            if (pos != null && dist(pos.lat, pos.lng, r.destLat, r.destLng) < 150) continue   // angekommen
            de.koeven.meeterz.Diag.log("Route beendet ohne Ankunft: ${friend.firstName}")
            _ended.tryEmit(de.koeven.meeterz.tr("%@ fährt nicht mehr hierher", friend.firstName))
        }
    }

    suspend fun refresh() {
        runCatching { Backend.client.postgrest.rpc("friends_routes").decodeList<Row>() }.onSuccess { rows ->
            val old = _routes.value
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
            noticeEnded(old, _routes.value)
        }
    }
}
