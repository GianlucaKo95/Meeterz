package de.koeven.meeterz.data

import de.koeven.meeterz.tr
import android.location.Location
import de.koeven.meeterz.AppState
import de.koeven.meeterz.live.PushService
import de.koeven.meeterz.nav.NavigationController
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.text.DateFormat
import java.time.Instant
import java.util.Date

/** Zeile aus RPC `my_messages()` (letzte 12 Stunden) – wie MessagesStore.Message auf iOS */
@Serializable
data class Message(
    val id: String,
    @SerialName("other_id") val otherId: String,
    @SerialName("other_name") val otherName: String,
    val incoming: Boolean,
    val body: String,
    @SerialName("meetup_id") val meetupId: String? = null,
    val automatic: Boolean = false,
    @SerialName("created_at") val createdAt: String,
) {
    val firstName get() = otherName.split(" ").firstOrNull() ?: otherName
}

/** Kurznachrichten unter Freunden: Schnellantworten (auch im Auto). Kein Chat-Verlauf. */
class MessagesStore {
    private val _messages = MutableStateFlow<List<Message>>(emptyList())
    val messages: StateFlow<List<Message>> = _messages
    /** Neu eingegangene Nachricht (für Android Auto: Hinweis und Vorlesen) */
    private val _received = MutableSharedFlow<Message>(extraBufferCapacity = 8)
    val received: SharedFlow<Message> = _received

    private val seen = mutableSetOf<String>()
    private var loadedOnce = false

    fun reset() { _messages.value = emptyList(); seen.clear(); loadedOnce = false }

    suspend fun refresh() {
        val rows = runCatching { Backend.client.postgrest.rpc("my_messages").decodeList<Message>() }.getOrNull() ?: return
        val fresh = rows.filter { it.incoming && it.id !in seen }
        rows.forEach { seen += it.id }
        _messages.value = rows
        // Beim ersten Laden nichts nachmelden – nur, was neu ankommt (höchstens 10 Minuten alt)
        if (loadedOnce) {
            val now = Instant.now()
            fresh.reversed()
                .filter { runCatching { Instant.parse(it.createdAt).isAfter(now.minusSeconds(600)) }.getOrDefault(false) }
                .forEach { _received.tryEmit(it) }
        }
        loadedOnce = true
    }

    /** Sendet an alle Empfänger, liefert die Zahl der gesendeten */
    suspend fun send(body: String, to: Collection<String>, meetupId: String? = null, automatic: Boolean = false): Int {
        var sent = 0
        for (id in to.toSet()) {
            runCatching {
                Backend.client.postgrest.rpc("send_message", buildJsonObject {
                    put("to_user_id", id); put("body", body); put("automatic", automatic)
                    if (meetupId != null) put("meetup_id", meetupId) else put("meetup_id", JsonNull)
                }).decodeAs<String>()
            }.onSuccess { messageId ->
                PushService.notify("message", id, messageId = messageId)
                sent++
            }
        }
        refresh()
        return sent
    }

    companion object {
        /** Bei Verspätung von 5 Minuten oder mehr automatisch Bescheid geben (wie iOS, Standard an) */
        var autoDelay: Boolean
            get() = AppState.appContextOrNull()?.getSharedPreferences("messages", 0)?.getBoolean("autoDelay", true) ?: true
            set(v) { AppState.appContextOrNull()?.getSharedPreferences("messages", 0)?.edit()?.putBoolean("autoDelay", v)?.apply() }

        /** Vorgefertigte Antworten – mit Ankunftszeit, wenn gerade navigiert wird (Texte wie iOS) */
        fun quickReplies(etaMillis: Long?): List<String> = buildList {
            etaMillis?.let { add(tr("Bin um %@ da", DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(it)))) }
            addAll(listOf(tr("Bin gleich da"), tr("Bin unterwegs"), tr("Komme ca. 10 Min. später"), tr("Stehe im Stau"),
                tr("Bin da – wo seid ihr?"), tr("Fangt schon ohne mich an"), tr("Alles klar 👍")))
        }

        /**
         * Wen betrifft mein Fahrtziel? Freunde, die schon dort sind (z. B. zu Hause) oder auch hinfahren –
         * wie meetupPartners in CarPlay. Leer = Freund selbst wählen.
         */
        fun recipientsAtDestination(): List<FriendRow> {
            val dest = NavigationController.guidance.value?.destination ?: return emptyList()
            val live = AppState.hub.positions.value
            val routes = AppState.routes.routes.value
            return AppState.friends.value.filter { it.isAccepted }.filter { f ->
                val p = live[f.friendId]
                val here = p != null && distance(p.lat, p.lng, dest.lat, dest.lng) < 150
                val coming = routes[f.friendId]?.let { distance(it.destLat, it.destLng, dest.lat, dest.lng) < 300 && it.eta.isAfter(Instant.now()) } == true
                here || coming
            }
        }

        /** Alle Freunde, nächste zuerst (Auswahl, wenn am Ziel niemand erkennbar ist) */
        fun friendsByDistance(): List<FriendRow> {
            val me = AppState.lastLocation
            val live = AppState.hub.positions.value
            return AppState.friends.value.filter { it.isAccepted }.sortedBy { f ->
                val p = live[f.friendId]
                if (me == null || p == null) Double.MAX_VALUE else distance(me.latitude, me.longitude, p.lat, p.lng)
            }
        }

        private fun distance(lat1: Double, lng1: Double, lat2: Double, lng2: Double): Double =
            FloatArray(1).also { Location.distanceBetween(lat1, lng1, lat2, lng2, it) }[0].toDouble()
    }
}
