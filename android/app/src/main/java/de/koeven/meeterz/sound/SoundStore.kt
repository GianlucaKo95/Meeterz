package de.koeven.meeterz.sound

import de.koeven.meeterz.tr
import de.koeven.meeterz.Diag
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.os.Build
import de.koeven.meeterz.AppState
import de.koeven.meeterz.data.Backend
import de.koeven.meeterz.nav.NavigationController
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.storage.storage
import io.ktor.http.ContentType
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.File

/** Die Momente, in denen ein Freund-Schnipsel abgespielt wird – Werte wie in der Datenbank und auf iOS */
enum class SoundMoment(val raw: String, val title: String, val example: String) {
    PASS("pass", tr("Fährt an dir vorbei"), tr("„Hup mal, ich bin's!“")),
    CATCH_UP("catchup", tr("Holt unterwegs zu dir auf"), tr("„Na, fahren wir zusammen weiter?“")),
    DEPARTED("departed", tr("Ist zum Treffpunkt losgefahren"), tr("„Bin unterwegs, stell schon mal Kaffee an!“")),
    SOON("soon", tr("Noch 5 Minuten bis zum Treffpunkt"), tr("„Bin gleich da, bestell schon mal!“")),
    LATE("late", tr("Verspätet sich"), tr("„Sorry, wird ein bisschen später!“")),
    ARRIVED("arrived", tr("Am Treffpunkt angekommen"), tr("„Wo bleibst du denn?“")),
    ACCEPTED("accepted", tr("Nimmt dein Treffen an"), tr("„Deal, wir sehen uns!“"));

    /** Ansage, falls der Freund nichts aufgenommen hat */
    fun fallback(name: String) = when (this) {
        PASS -> tr("%@ ist gerade an dir vorbeigefahren.", name)
        CATCH_UP -> tr("%@ und du seid jetzt zusammen unterwegs.", name)
        DEPARTED -> tr("%@ ist zum Treffpunkt losgefahren.", name)
        SOON -> tr("%@ ist in etwa fünf Minuten am Treffpunkt.", name)
        LATE -> tr("%@ verspätet sich.", name)
        ARRIVED -> tr("%@ ist am Treffpunkt angekommen.", name)
        ACCEPTED -> tr("%@ hat dein Treffen angenommen.", name)
    }

    companion object { fun of(raw: String) = entries.firstOrNull { it.raw == raw } }
}

/**
 * Sound-Pack (wie SoundStore auf iOS): eigene Sprachschnipsel (≤ 5 s) aufnehmen und hochladen, Schnipsel der
 * Freunde laden und abspielen. Bucket „sounds“, Pfad „<user_id>/<moment>.m4a“ – dieselben Dateien wie auf iOS.
 */
object SoundStore {
    const val MAX_SECONDS = 5L
    private const val BUCKET = "sounds"

    @Serializable
    private data class Row(@SerialName("user_id") val userId: String, val moment: String, val version: Int)

    private val _versions = MutableStateFlow<Map<String, Map<SoundMoment, Int>>>(emptyMap())
    /** Version je Nutzer und Moment (fehlt = kein Schnipsel); enthält auch meine eigenen */
    val versions: StateFlow<Map<String, Map<SoundMoment, Int>>> = _versions
    private val _recording = MutableStateFlow<SoundMoment?>(null)
    val recording: StateFlow<SoundMoment?> = _recording
    val busy = MutableStateFlow(false)

    private lateinit var context: Context
    private val prefs get() = context.getSharedPreferences("sounds", Context.MODE_PRIVATE)
    private var recorder: MediaRecorder? = null
    private var stopJob: Job? = null
    private var player: MediaPlayer? = null
    private val lastPlayed = mutableMapOf<String, Long>()

    fun init(context: Context) { this.context = context.applicationContext }

    var enabled: Boolean
        get() = prefs.getBoolean("enabled", true)
        set(v) { prefs.edit().putBoolean("enabled", v).apply() }

    fun isMuted(id: String) = prefs.getStringSet("muted", emptySet())!!.contains(id)
    fun setMuted(id: String, muted: Boolean) {
        val set = prefs.getStringSet("muted", emptySet())!!.toMutableSet()
        if (muted) set += id else set -= id
        prefs.edit().putStringSet("muted", set).apply()
    }

    fun hasClip(user: String, moment: SoundMoment) = (_versions.value[user]?.get(moment) ?: 0) > 0

    // Synchronisieren

    suspend fun sync() {
        val rows = runCatching { Backend.client.postgrest.rpc("friend_sounds").decodeList<Row>() }.getOrNull() ?: return
        val next = mutableMapOf<String, MutableMap<SoundMoment, Int>>()
        for (r in rows) SoundMoment.of(r.moment)?.let { next.getOrPut(r.userId) { mutableMapOf() }[it] = r.version }
        _versions.value = next
        // kleine Dateien gleich vorladen, damit das Abspielen sofort klappt
        for ((user, moments) in next) for ((m, v) in moments) ensureLocal(user, m, v)
    }

    fun reset() { stopPlayback(); _versions.value = emptyMap() }

    // Eigene Schnipsel

    /** Aufnahme starten (Mikrofon-Berechtigung muss vorher erteilt sein); endet spätestens nach 5 s und lädt hoch */
    fun startRecording(moment: SoundMoment) {
        if (_recording.value != null) return
        stopPlayback()
        val file = tempFile()
        file.delete()
        val rec = (if (Build.VERSION.SDK_INT >= 31) MediaRecorder(context) else @Suppress("DEPRECATION") MediaRecorder())
        runCatching {
            rec.setAudioSource(MediaRecorder.AudioSource.MIC)
            rec.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            rec.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            rec.setAudioSamplingRate(22_050)
            rec.setAudioChannels(1)
            rec.setAudioEncodingBitRate(32_000)
            rec.setOutputFile(file.absolutePath)
            rec.prepare()
            rec.start()
        }.onFailure { Diag.log("Aufnahme fehlgeschlagen: ${it.message}"); rec.release(); return }
        recorder = rec
        _recording.value = moment
        stopJob = AppState.scope.launch { delay(MAX_SECONDS * 1000 + 300); stopRecording() }
    }

    /** Aufnahme beenden und hochladen */
    fun stopRecording() {
        val rec = recorder ?: return
        val moment = _recording.value ?: return
        stopJob?.cancel()
        runCatching { rec.stop() }
        rec.release()
        recorder = null
        _recording.value = null
        val me = AppState.myId ?: return
        val data = tempFile().takeIf { it.exists() }?.readBytes() ?: return
        if (data.size < 1500) return
        AppState.scope.launch { setMine(moment, data, me) }
    }

    private suspend fun setMine(moment: SoundMoment, data: ByteArray, me: String) {
        busy.value = true
        runCatching {
            Backend.client.storage.from(BUCKET).upload(path(me, moment), data) {
                upsert = true
                contentType = ContentType.parse("audio/mp4")
            }
            val version = Backend.client.postgrest.rpc("set_sound", buildJsonObject { put("p_moment", moment.raw) }).decodeAs<Int>()
            writeCache(data, me, moment, version)
            _versions.value = _versions.value.toMutableMap().apply { put(me, (get(me) ?: emptyMap()) + (moment to version)) }
        }.onFailure { Diag.log("Schnipsel nicht gespeichert: ${it.message}") }
        busy.value = false
    }

    suspend fun removeMine(moment: SoundMoment) {
        val me = AppState.myId ?: return
        busy.value = true
        runCatching {
            Backend.client.storage.from(BUCKET).delete(listOf(path(me, moment)))
            Backend.client.postgrest.rpc("set_sound", buildJsonObject { put("p_moment", moment.raw); put("remove", true) })
            _versions.value = _versions.value.toMutableMap().apply { put(me, (get(me) ?: emptyMap()) - moment) }
        }.onFailure { Diag.log("Schnipsel nicht entfernt: ${it.message}") }
        busy.value = false
    }

    // Abspielen

    /** Zur Probe (eigene Schnipsel) – ohne Stummschaltung */
    suspend fun preview(user: String, moment: SoundMoment) {
        val v = _versions.value[user]?.get(moment) ?: return
        ensureLocal(user, moment, v)
        cacheFile(user, moment, v).takeIf { it.exists() }?.let { play(it) }
    }

    /**
     * Spielt den Moment für einen Freund ab; ohne Schnipsel die Ansage. `cooldown` (ms) verhindert Wiederholungen,
     * `key` unterscheidet z. B. Treffen.
     */
    suspend fun trigger(moment: SoundMoment, friendId: String, firstName: String, cooldown: Long = 0, key: String = "") {
        if (!enabled || isMuted(friendId) || _recording.value != null) return
        val k = "$friendId-${moment.raw}$key"
        val now = System.currentTimeMillis()
        if (now - (lastPlayed[k] ?: 0) < cooldown) return
        lastPlayed[k] = now
        val v = _versions.value[friendId]?.get(moment)
        if (v != null && v > 0) {
            ensureLocal(friendId, moment, v)
            val file = cacheFile(friendId, moment, v)
            if (file.exists()) { play(file); return }
        }
        NavigationController.announce(moment.fallback(firstName))
    }

    private val audio get() = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val attributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
        .build()
    private val focus by lazy {
        AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK).setAudioAttributes(attributes).build()
    }

    /** Musik wird kurz leiser, danach wieder laut */
    private fun play(file: File) {
        stopPlayback()
        runCatching {
            audio.requestAudioFocus(focus)
            player = MediaPlayer().apply {
                setAudioAttributes(attributes)
                setDataSource(file.absolutePath)
                setOnCompletionListener { stopPlayback() }
                prepare()
                start()
            }
        }.onFailure { stopPlayback() }
    }

    fun stopPlayback() {
        player?.runCatching { stop(); release() }
        player = null
        runCatching { audio.abandonAudioFocusRequest(focus) }
    }

    // Dateien

    private fun path(id: String, m: SoundMoment) = "${id.lowercase()}/${m.raw}.m4a"
    private fun tempFile() = File(context.cacheDir, "meeterz-aufnahme.m4a")
    private fun cacheDir() = File(context.cacheDir, "sounds").apply { mkdirs() }
    private fun cacheFile(id: String, m: SoundMoment, v: Int) = File(cacheDir(), "${id.lowercase()}-${m.raw}-$v.m4a")

    private fun writeCache(data: ByteArray, id: String, m: SoundMoment, v: Int) {
        val prefix = "${id.lowercase()}-${m.raw}-"
        cacheDir().listFiles()?.filter { it.name.startsWith(prefix) }?.forEach { it.delete() }
        cacheFile(id, m, v).writeBytes(data)
    }

    private suspend fun ensureLocal(id: String, m: SoundMoment, v: Int) {
        if (cacheFile(id, m, v).exists()) return
        val data = runCatching { Backend.client.storage.from(BUCKET).downloadAuthenticated(path(id, m)) }.getOrNull() ?: return
        withContext(Dispatchers.IO) { writeCache(data, id, m, v) }
    }
}
