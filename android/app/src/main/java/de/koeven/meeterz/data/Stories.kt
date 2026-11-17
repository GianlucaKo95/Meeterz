package de.koeven.meeterz.data

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import de.koeven.meeterz.AppState
import de.koeven.meeterz.Diag
import de.koeven.meeterz.nav.NavigationController
import de.koeven.meeterz.social.Convoy
import de.koeven.meeterz.tr
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import io.github.jan.supabase.storage.storage
import io.ktor.http.ContentType
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.io.ByteArrayOutputStream
import java.io.File
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import java.util.Locale
import java.util.UUID

/** Zeile aus RPC `friend_stories()` – wie StoriesStore.Story auf iOS */
@Serializable
data class Story(
    val id: String,
    @SerialName("user_id") val userId: String,
    @SerialName("display_name") val displayName: String,
    val kind: String,
    @SerialName("media_path") val mediaPath: String,
    val lat: Double,
    val lng: Double,
    @SerialName("place_name") val placeName: String? = null,
    val caption: String? = null,
    @SerialName("convoy_key") val convoyKey: String? = null,
    @SerialName("created_at") val createdAt: String,
    @SerialName("expires_at") val expiresAt: String,
    val seen: Boolean = false,
) {
    val isVideo get() = kind == "video"
    val firstName get() = displayName.split(" ").firstOrNull() ?: displayName
}

/**
 * Stories (wie StoriesStore.swift): Foto oder Video (≤ 15 s) am Ort, 24 h für Freunde. Bucket „stories“,
 * Pfad „<user_id>/<story_id>.jpg|mp4“.
 */
object StoriesStore {
    private const val BUCKET = "stories"
    private lateinit var context: Context
    private val _stories = MutableStateFlow<List<Story>>(emptyList())
    val stories: StateFlow<List<Story>> = _stories
    /** Gerade geöffnete Stories (Vollbild) */
    val viewing = MutableStateFlow<List<Story>?>(null)
    val posting = MutableStateFlow(false)
    /** Neue Story eines Freundes (Android Auto: Hinweis) */
    private val _received = MutableSharedFlow<Story>(extraBufferCapacity = 8)
    val received: SharedFlow<Story> = _received

    private val known = mutableSetOf<String>()
    private var loadedOnce = false
    private var cleaned = false

    fun init(context: Context) { this.context = context.applicationContext }
    private fun cacheDir() = File(context.cacheDir, "stories").apply { mkdirs() }

    fun of(userId: String) = _stories.value.filter { it.userId == userId }
    fun hasUnseen(userId: String) = userId != AppState.myId && _stories.value.any { it.userId == userId && !it.seen }
    fun hasStories(userId: String) = _stories.value.any { it.userId == userId }
    fun open(userId: String) { of(userId).takeIf { it.isNotEmpty() }?.let { viewing.value = it } }

    fun reset() { _stories.value = emptyList(); known.clear(); loadedOnce = false; cleaned = false; viewing.value = null }

    // ponytail: alle 30 s mit den Nachrichten statt Live-Kanal (wie Nachrichten auf Android)
    suspend fun refresh() {
        val rows = runCatching { Backend.client.postgrest.rpc("friend_stories").decodeList<Story>() }.getOrNull() ?: return
        val me = AppState.myId
        val fresh = rows.filter { it.id !in known && it.userId != me }
        rows.forEach { known += it.id }
        _stories.value = rows
        if (loadedOnce) {
            val now = Instant.now()
            fresh.filter { runCatching { Instant.parse(it.createdAt).isAfter(now.minusSeconds(600)) }.getOrDefault(false) }
                .forEach { _received.tryEmit(it) }
        }
        loadedOnce = true
        if (!cleaned) { cleaned = true; removeExpired() }
    }

    @Serializable data class Viewer(val viewer: String, @SerialName("seen_at") val seenAt: String)

    /** Wer eine eigene Story gesehen hat (die Datenbank zeigt nur dem Besitzer die Aufrufe) */
    suspend fun viewers(story: Story): List<Viewer> = runCatching {
        Backend.client.from("story_views").select(Columns.raw("viewer,seen_at")) {
            filter { eq("story_id", story.id) }
            order("seen_at", Order.DESCENDING)
        }.decodeList<Viewer>()
    }.getOrDefault(emptyList())

    fun markSeen(story: Story) {
        if (story.seen || story.userId == AppState.myId) return
        _stories.value = _stories.value.map { if (it.id == story.id) it.copy(seen = true) else it }
        AppState.scope.launch {
            @Serializable data class Row(@SerialName("story_id") val storyId: String)
            runCatching { Backend.client.from("story_views").upsert(Row(story.id)) { ignoreDuplicates = true } }
        }
    }

    /** Datei lokal – für Bild und Video */
    suspend fun file(story: Story): File? = withContext(Dispatchers.IO) {
        val f = File(cacheDir(), story.mediaPath.substringAfterLast('/'))
        if (f.exists()) return@withContext f
        val data = runCatching { Backend.client.storage.from(BUCKET).downloadAuthenticated(story.mediaPath) }.getOrNull() ?: return@withContext null
        f.writeBytes(data); f
    }

    /** Foto (JPEG, längste Kante 1440) oder Video (≤ 15 s, so wie aufgenommen) teilen */
    suspend fun post(uri: Uri, video: Boolean, caption: String, placeName: String?, lat: Double, lng: Double): Boolean {
        val me = AppState.myId ?: return false
        posting.value = true
        try {
            val id = UUID.randomUUID().toString()
            val data = withContext(Dispatchers.IO) {
                if (video) context.contentResolver.openInputStream(uri)!!.use { it.readBytes() }
                else {
                    val src = context.contentResolver.openInputStream(uri)!!.use { BitmapFactory.decodeStream(it) }
                    val scale = minOf(1f, 1440f / maxOf(src.width, src.height))
                    val img = Bitmap.createScaledBitmap(src, (src.width * scale).toInt(), (src.height * scale).toInt(), true)
                    ByteArrayOutputStream().also { img.compress(Bitmap.CompressFormat.JPEG, 80, it) }.toByteArray()
                }
            }
            if (data.size > 25 * 1024 * 1024) { Diag.log("Story zu groß: ${data.size} Bytes"); return false }
            val path = "${me.lowercase()}/$id.${if (video) "mp4" else "jpg"}"
            @Serializable data class Row(
                val id: String, val kind: String, @SerialName("media_path") val mediaPath: String, val lat: Double, val lng: Double,
                @SerialName("place_name") val placeName: String?, val caption: String?, @SerialName("convoy_key") val convoyKey: String?,
            )
            val convoy = ConvoyFeed.key.value
            Backend.client.storage.from(BUCKET).upload(path, data) { contentType = if (video) ContentType.Video.MP4 else ContentType.Image.JPEG }
            runCatching {
                Backend.client.from("stories").insert(Row(id, if (video) "video" else "photo", path, lat, lng,
                    placeName?.take(120), caption.trim().take(140).ifEmpty { null }, convoy))
            }.onFailure {
                runCatching { Backend.client.storage.from(BUCKET).delete(listOf(path)) }
                throw it
            }
            File(cacheDir(), path.substringAfterLast('/')).writeBytes(data)
            if (convoy != null) ConvoyFeed.post("story", storyId = id)
            refresh()
            return true
        } catch (e: Exception) {
            Diag.log("Story nicht gespeichert: ${e.message}")
            return false
        } finally { posting.value = false }
    }

    suspend fun delete(story: Story) {
        runCatching { Backend.client.storage.from(BUCKET).delete(listOf(story.mediaPath)) }
        runCatching { Backend.client.from("stories").delete { filter { eq("id", story.id) } } }
        _stories.value = _stories.value.filter { it.id != story.id }
        viewing.value = viewing.value?.filter { it.id != story.id }?.ifEmpty { null }
    }

    /** Eigene abgelaufene Stories samt Datei entfernen, Cache älter als 25 h leeren */
    private suspend fun removeExpired() {
        @Serializable data class Old(val id: String, @SerialName("media_path") val mediaPath: String)
        val old = runCatching {
            Backend.client.from("stories").select(Columns.raw("id,media_path")) { filter { lt("expires_at", Instant.now().toString()) } }.decodeList<Old>()
        }.getOrNull().orEmpty()
        if (old.isNotEmpty()) {
            runCatching { Backend.client.storage.from(BUCKET).delete(old.map { it.mediaPath }) }
            runCatching { Backend.client.from("stories").delete { filter { isIn("id", old.map { it.id }) } } }
        }
        withContext(Dispatchers.IO) {
            cacheDir().listFiles()?.filter { System.currentTimeMillis() - it.lastModified() > 25 * 3600_000L }?.forEach { it.delete() }
        }
    }

    /** Länge eines aufgenommenen Videos in Sekunden (Android-Kameras halten EXTRA_DURATION_LIMIT nicht immer ein) */
    fun videoSeconds(uri: Uri): Double = runCatching {
        MediaMetadataRetriever().use { r ->
            r.setDataSource(context, uri)
            (r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toDouble() ?: 0.0) / 1000
        }
    }.getOrDefault(0.0)
}

/** Konvoi-Feed (wie ConvoyFeed.swift): Ereignisse einer gemeinsamen Fahrt, danach als Chronik unter „Fahrten“ */
object ConvoyFeed {
    @Serializable
    data class Event(
        val id: String,
        @SerialName("convoy_key") val convoyKey: String,
        @SerialName("user_id") val userId: String,
        val kind: String,
        val text: String? = null,
        @SerialName("dest_name") val destName: String? = null,
        @SerialName("story_id") val storyId: String? = null,
        @SerialName("created_at") val createdAt: String,
    )

    @Serializable
    data class Trip(
        @SerialName("convoy_key") val convoyKey: String,
        @SerialName("dest_name") val destName: String? = null,
        @SerialName("started_at") val startedAt: String,
        @SerialName("last_at") val lastAt: String,
        val members: List<String> = emptyList(),
        val entries: Int = 0,
    )

    /** Laufender Konvoi (null = ich fahre gerade mit niemandem) */
    val key = MutableStateFlow<String?>(null)
    val trips = MutableStateFlow<List<Trip>>(emptyList())
    val entries = MutableStateFlow<List<Event>>(emptyList())
    val shownKey = MutableStateFlow<String?>(null)

    private val members = mutableSetOf<String>()
    private var destName: String? = null
    private var destLat = 0.0
    private var destLng = 0.0

    fun reset() { key.value = null; members.clear(); trips.value = emptyList(); entries.value = emptyList(); shownKey.value = null }

    /** Alle 30 s: Konvoi erkennen, Mitfahrende sammeln, „dazugekommen“ einmal je Fahrt */
    fun update() {
        val dest = NavigationController.guidance.value?.destination ?: return
        val current = Convoy.members().map { it.friend.friendId }
        if (current.isEmpty()) return
        val k = key(dest.lat, dest.lng)
        if (k != key.value) { key.value = k; members.clear() }
        members += current
        destName = dest.name; destLat = dest.lat; destLng = dest.lng
        val prefs = AppState.appContextOrNull()?.getSharedPreferences("convoy", 0) ?: return
        if (!prefs.getBoolean("joined.$k", false)) {
            prefs.edit().putBoolean("joined.$k", true).apply()
            post("joined")
        }
        if (shownKey.value != null) AppState.scope.launch { shownKey.value?.let { load(it) } }
    }

    /** Navigation endet: am Ziel „angekommen“, dann ist der Konvoi vorbei */
    fun navigationEnded() {
        if (key.value == null) return
        val here = AppState.lastLocation
        if (here != null && de.koeven.meeterz.ev.ChargePlanner.distance(here.latitude, here.longitude, destLat, destLng) < 400) post("arrived")
        key.value = null
        members.clear()
    }

    fun post(kind: String, text: String? = null, storyId: String? = null) {
        val k = key.value ?: return
        if (members.isEmpty()) return
        @Serializable data class Row(
            @SerialName("convoy_key") val convoyKey: String, val members: List<String>, val kind: String, val text: String?,
            @SerialName("dest_name") val destName: String?, @SerialName("story_id") val storyId: String?, val lat: Double?, val lng: Double?,
        )
        val here = AppState.lastLocation
        val row = Row(k, members.take(20), kind, text?.take(200), destName, storyId, here?.latitude, here?.longitude)
        AppState.scope.launch {
            runCatching { Backend.client.from("convoy_events").insert(row) }
                .onFailure { Diag.log("Konvoi-Feed: $kind nicht gespeichert – ${it.message}") }
            if (shownKey.value == k) load(k)
        }
    }

    /** Nachricht an Mitfahrende auch in den Feed */
    fun messageSent(body: String, to: Collection<String>) {
        if (key.value != null && to.isNotEmpty() && members.containsAll(to)) post("message", body)
    }

    // ponytail: Ziel auf 2 Nachkommastellen – genau auf einer Rundungsgrenze bekommen Mitfahrende verschiedene Feeds
    fun key(lat: Double, lng: Double): String {
        AppState.meetups.accepted.firstOrNull { it.distanceTo(lat, lng) < 300 }?.let { return "m-${(it.groupId ?: it.id).lowercase()}" }
        return String.format(Locale.US, "d-%.2f,%.2f-", lat, lng) + LocalDate.now(ZoneOffset.UTC)
    }

    suspend fun loadTrips() {
        runCatching { Backend.client.postgrest.rpc("my_convoys").decodeList<Trip>() }.onSuccess { trips.value = it }
    }

    suspend fun show(k: String?) {
        shownKey.value = k
        entries.value = emptyList()
        if (k != null) load(k)
    }

    suspend fun load(k: String) {
        val rows = runCatching {
            Backend.client.from("convoy_events").select(Columns.raw("id,convoy_key,user_id,kind,text,dest_name,story_id,created_at")) {
                filter { eq("convoy_key", k) }
                order("created_at", Order.ASCENDING)
            }.decodeList<Event>()
        }.getOrNull() ?: return
        if (shownKey.value == k) entries.value = rows
    }

    fun describe(e: Event): String {
        val me = e.userId == AppState.myId
        val name = if (me) tr("Du") else AppState.friends.value.firstOrNull { it.friendId == e.userId }?.displayName?.split(" ")?.firstOrNull() ?: tr("Jemand")
        return when (e.kind) {
            "joined" -> if (me) tr("Du bist losgefahren") else tr("%@ fährt mit", name)
            "pause" -> tr("%@ schlägt eine Pause vor: %@", name, e.text.orEmpty())
            "charge" -> if (me) tr("Du lädst") else tr("%@ lädt", name)
            "message" -> "$name: ${e.text.orEmpty()}"
            "story" -> if (me) tr("Du hast eine Story geteilt") else tr("%@ hat eine Story geteilt", name)
            else -> if (me) tr("Du bist angekommen") else tr("%@ ist angekommen", name)
        }
    }
}
