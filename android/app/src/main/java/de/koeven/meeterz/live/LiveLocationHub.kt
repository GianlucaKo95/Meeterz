package de.koeven.meeterz.live

import android.location.Location
import de.koeven.meeterz.data.Backend
import de.koeven.meeterz.data.FriendRow
import de.koeven.meeterz.data.Gone
import de.koeven.meeterz.data.LivePosition
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.realtime.RealtimeChannel
import io.github.jan.supabase.realtime.broadcast
import io.github.jan.supabase.realtime.broadcastFlow
import io.github.jan.supabase.realtime.channel
import io.github.jan.supabase.realtime.realtime
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Wie LiveLocationHub auf iOS: eigene Position in den privaten Kanal „loc:<id>“ senden und die Kanäle der
 * Freunde abonnieren. RLS (realtime.messages) lässt nur Freunde mit aktivem Teilen zu.
 */
class LiveLocationHub(private val scope: CoroutineScope) {
    private val client = Backend.client
    private val _positions = MutableStateFlow<Map<String, LivePosition>>(emptyMap())
    val positions: StateFlow<Map<String, LivePosition>> = _positions

    private var own: RealtimeChannel? = null
    private val friendChannels = mutableMapOf<String, RealtimeChannel>()
    private val listeners = mutableMapOf<String, List<Job>>()
    private var lastSent: LivePosition? = null
    private var lastPersisted = 0L

    private fun topic(id: String) = "loc:${id.lowercase()}"

    suspend fun startPublishing(userId: String) {
        if (own != null) return
        val ch = client.channel(topic(userId)) {
            isPrivate = true
            broadcast { receiveOwnBroadcasts = false }
        }
        runCatching { ch.subscribe(blockUntilSubscribed = true) }
        own = ch
    }

    suspend fun publish(location: Location, userId: String, sharing: Boolean, force: Boolean = false) {
        val ch = own ?: return
        if (!sharing) return
        val pos = LivePosition(
            userId = userId,
            lat = location.latitude,
            lng = location.longitude,
            heading = if (location.hasBearing()) location.bearing.toDouble() else null,
            speed = if (location.hasSpeed()) location.speed.toDouble() else null,
            ts = location.time / 1000.0,
        )
        if (!force && !shouldSend(pos)) return
        runCatching { ch.broadcast("pos", pos) }.onSuccess { lastSent = pos }

        // Letzte Position seltener dauerhaft speichern (für den App-Start der Freunde)
        if (force || System.currentTimeMillis() - lastPersisted > 120_000) {
            lastPersisted = System.currentTimeMillis()
            val params = buildJsonObject {
                put("lat", pos.lat); put("lng", pos.lng); put("heading", pos.heading); put("speed", pos.speed)
            }
            runCatching { client.postgrest.rpc("update_last_location", params) }
        }
    }

    /** Gleiche Taktung wie iOS: in Fahrt ca. alle 5 s, im Stand höchstens jede Minute */
    private fun shouldSend(pos: LivePosition): Boolean {
        val last = lastSent ?: return true
        val elapsed = pos.ts - last.ts
        val moving = (pos.speed ?: 0.0) > 2
        val d = FloatArray(1).also { Location.distanceBetween(last.lat, last.lng, pos.lat, pos.lng, it) }[0]
        return if (moving) elapsed >= 5 || d >= 50 else elapsed >= 60 || d >= 30
    }

    /** Letzte bekannte Positionen übernehmen und Abos mit der Freundesliste abgleichen */
    suspend fun sync(friends: List<FriendRow>) {
        val accepted = friends.filter { it.isAccepted }
        val ids = accepted.map { it.friendId }.toSet()
        for (id in friendChannels.keys - ids) unsubscribe(id)
        for (id in ids - friendChannels.keys) subscribe(id)
    }

    private suspend fun subscribe(friendId: String) {
        val ch = client.channel(topic(friendId)) { isPrivate = true }
        friendChannels[friendId] = ch
        val positions = ch.broadcastFlow<LivePosition>("pos")
        val gone = ch.broadcastFlow<Gone>("gone")
        listeners[friendId] = listOf(
            scope.launch { positions.collect { p -> if (p.userId.equals(friendId, true)) _positions.update { it + (friendId to p) } } },
            scope.launch { gone.collect { g -> if (g.userId.equals(friendId, true)) _positions.update { it - friendId } } },
        )
        runCatching { ch.subscribe() }
    }

    private suspend fun unsubscribe(friendId: String) {
        listeners.remove(friendId)?.forEach { it.cancel() }
        friendChannels.remove(friendId)?.let { client.realtime.removeChannel(it) }
        _positions.update { it - friendId }
    }
}
