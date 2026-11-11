package de.koeven.meeterz.data

import de.koeven.meeterz.Diag
import android.location.Location
import de.koeven.meeterz.AppState
import de.koeven.meeterz.ev.ChargePlanner
import de.koeven.meeterz.live.PushService
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.text.DateFormat
import java.time.Instant
import java.util.Date

/** Zeile aus RPC `my_meetups()` (wie Meetup auf iOS) */
@Serializable
data class Meetup(
    val id: String,
    @SerialName("other_id") val otherId: String,
    @SerialName("other_name") val otherName: String,
    val incoming: Boolean,
    @SerialName("place_name") val placeName: String,
    val lat: Double,
    val lng: Double,
    val status: String,
    @SerialName("created_at") val createdAt: String,
    @SerialName("group_id") val groupId: String? = null,
    @SerialName("group_size") val groupSize: Int? = null,
    @SerialName("meet_at") val meetAt: String? = null,
) {
    val isPending get() = status == "pending"
    val isAccepted get() = status == "accepted"
    /** Verabredete Uhrzeit (Unix-Sekunden), null = „jetzt“ */
    val meetAtSeconds: Long? get() = meetAt?.let { runCatching { Instant.parse(it).epochSecond }.getOrNull() }
    fun distanceTo(lat: Double, lng: Double) = ChargePlanner.distance(this.lat, this.lng, lat, lng)
}

/**
 * Treffen (wie MeetupsStore auf iOS) – auf Android vorerst ohne eigene Oberfläche zum Vorschlagen/Annehmen.
 * Grundlage für die Sound-Pack-Momente, „ist losgefahren“, Verspätungsnachricht und Ankunft (Treffen auflösen).
 */
class MeetupsStore {
    @Serializable
    private data class GroupMember(@SerialName("user_id") val userId: String, val status: String)

    private val _meetups = MutableStateFlow<List<Meetup>>(emptyList())
    val meetups: StateFlow<List<Meetup>> = _meetups
    val accepted get() = _meetups.value.filter { it.isAccepted }

    /** Mein Vorschlag wurde angenommen (für den Moment „nimmt dein Treffen an“) */
    private val _acceptedByFriend = MutableSharedFlow<Meetup>(extraBufferCapacity = 4)
    val acceptedByFriend: SharedFlow<Meetup> = _acceptedByFriend

    /** Gruppen-Treffen: weitere Teilnehmer mit Zusage (je Treffen-ID, ohne mich und ohne otherId) */
    @Volatile private var groupPartners: Map<String, List<String>> = emptyMap()
    private var fetched = false
    private val arrivalReported = mutableSetOf<String>()

    fun partners(m: Meetup): List<String> = listOf(m.otherId) + (groupPartners[m.id] ?: emptyList())
    fun isPartner(friendId: String, m: Meetup) = m.otherId == friendId || groupPartners[m.id]?.contains(friendId) == true

    fun reset() { _meetups.value = emptyList(); groupPartners = emptyMap(); fetched = false; arrivalReported.clear() }

    suspend fun refresh() {
        val rows = runCatching { Backend.client.postgrest.rpc("my_meetups").decodeList<Meetup>() }.getOrNull() ?: return
        val wasPending = _meetups.value.filter { !it.incoming && it.isPending }.map { it.id }.toSet()
        if (fetched) rows.filter { !it.incoming && it.isAccepted && it.id in wasPending }.forEach { _acceptedByFriend.tryEmit(it) }
        fetched = true
        _meetups.value = rows
        val me = AppState.myId
        val byGroup = mutableMapOf<String, List<GroupMember>>()
        groupPartners = rows.filter { it.isAccepted && it.groupId != null }.associate { m ->
            val members = byGroup.getOrPut(m.groupId!!) {
                runCatching {
                    Backend.client.postgrest.rpc("group_members", buildJsonObject { put("gid", m.groupId) }).decodeList<GroupMember>()
                }.getOrDefault(emptyList())
            }
            m.id to members.filter { it.status == "accepted" && it.userId != me && it.userId != m.otherId }.map { it.userId }
        }
    }

    /** Am Treffpunkt angekommen (< 100 m): melden – sind alle da, löst der Server das Treffen auf (wie iOS) */
    suspend fun checkArrival(loc: Location) {
        for (m in accepted) {
            if (m.id in arrivalReported || m.distanceTo(loc.latitude, loc.longitude) >= 100) continue
            arrivalReported += m.id
            val done = runCatching {
                Backend.client.postgrest.rpc("arrive_at_meetup", buildJsonObject { put("p_meetup", m.id) }).decodeAs<Boolean>()
            }.getOrDefault(false)
            if (done) refresh()
        }
    }

    // Sender: losgefahren / verspätet (wie NavigationCoordinator.announceDeparture / checkDelay auf iOS)

    private val departedSent = mutableSetOf<String>()
    private val announcedArrival = mutableMapOf<String, Long>()

    /** Navigation zu einem Treffpunkt beginnt: allen Treffpartnern per Push Bescheid geben */
    fun announceDeparture(destLat: Double, destLng: Double) {
        for (m in accepted) {
            if (m.distanceTo(destLat, destLng) >= 300 || m.id in departedSent) continue
            departedSent += m.id
            partners(m).forEach { PushService.notify("meetup_departed", it, meetupId = m.id) }
            Diag.log("Losgefahren gemeldet: ${m.placeName}")
        }
    }

    /** Ankunft verschiebt sich um ≥ 5 Min.: automatische Nachricht an die Treffpartner (Einstellung wie iOS, Standard an) */
    suspend fun checkDelay(destLat: Double, destLng: Double, etaSeconds: Long) {
        if (!MessagesStore.autoDelay) return
        for (m in accepted) {
            if (m.distanceTo(destLat, destLng) >= 300) continue
            val before = announcedArrival[m.id] ?: run { announcedArrival[m.id] = etaSeconds; null } ?: continue
            val late = etaSeconds - before
            if (late < 5 * 60) continue
            announcedArrival[m.id] = etaSeconds
            val minutes = Math.round(late / 60.0)
            val at = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(etaSeconds * 1000))
            AppState.messages.send("Ich komme ca. $minutes Min. später – neue Ankunft $at", partners(m), m.id, automatic = true)
            Diag.log("Verspätung gemeldet: +$minutes Min.")
        }
    }

    fun navigationEnded() { announcedArrival.clear() }
}
