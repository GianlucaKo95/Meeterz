package de.koeven.meeterz

import android.content.Context
import de.koeven.meeterz.auth.AuthRepository
import de.koeven.meeterz.data.Backend
import de.koeven.meeterz.data.FavoritesStore
import de.koeven.meeterz.data.FriendRow
import de.koeven.meeterz.data.VehicleStore
import de.koeven.meeterz.live.LiveLocationHub
import de.koeven.meeterz.live.PushService
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** Gegenstück zu AppModel auf iOS: hält Anmeldung, Freunde und Live-Positionen für App und Android Auto */
object AppState {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    val auth = AuthRepository(scope).also { it.start() }
    val hub = LiveLocationHub(scope)
    val vehicle = VehicleStore()
    val routes = de.koeven.meeterz.data.FriendRoutesStore()
    val messages = de.koeven.meeterz.data.MessagesStore()
    val meetups = de.koeven.meeterz.data.MeetupsStore()

    /** Eigene Positionen der letzten 15 Minuten – für Begegnungen zählt meine Position zum Zeitstempel des Freundes */
    private val history = ArrayDeque<android.location.Location>()

    @Synchronized fun recordLocation(loc: android.location.Location) {
        history.addLast(loc)
        while (history.isNotEmpty() && loc.time - history.first().time > 15 * 60_000) history.removeFirst()
    }

    /** Meine Position zu einem Zeitpunkt (Unix-Sekunden), höchstens 20 s daneben */
    @Synchronized fun locationAt(ts: Double): android.location.Location? =
        history.minByOrNull { kotlin.math.abs(it.time / 1000.0 - ts) }?.takeIf { kotlin.math.abs(it.time / 1000.0 - ts) <= 20 }
    lateinit var favorites: FavoritesStore
        private set

    /** Eigene Nutzer-ID (klein geschrieben wie in der Datenbank) */
    val myId: String? get() = (auth.state.value as? AuthRepository.State.Ready)?.profile?.id

    /** Letzter eigener Standort (für Suche und Routenplanung) */
    @Volatile var lastLocation: android.location.Location? = null

    private val _friends = MutableStateFlow<List<FriendRow>>(emptyList())
    val friends: StateFlow<List<FriendRow>> = _friends
    val friendError = MutableStateFlow<String?>(null)

    private var session: Job? = null

    private lateinit var appContext: Context

    fun init(context: Context) { appContext = context.applicationContext; favorites = FavoritesStore(context) }

    fun appContextOrNull(): Context? = if (::appContext.isInitialized) appContext else null

    /** Nach der Anmeldung: Senden starten, alle 30 s Freunde und Auto laden (wie refreshSocial auf iOS) */
    fun startSession(userId: String) {
        if (session?.isActive == true) return
        favorites.load(userId)
        session = scope.launch {
            hub.startPublishing(userId)
            PushService.registerCurrent(appContext)
            launch { meetups.acceptedByFriend.collect { de.koeven.meeterz.sound.SoundMoments.accepted(it.otherId, it.id) } }
            while (isActive) {
                refreshFriends()
                // ponytail: Nachrichten alle 30 s und bei jedem Push statt Live-Kanal wie auf iOS
                messages.refresh()
                refreshHidden()
                de.koeven.meeterz.data.AvatarStore.sync(friends.value, profile)
                meetups.refresh()
                de.koeven.meeterz.sound.SoundStore.sync()
                de.koeven.meeterz.sound.SoundMoments.checkJourneys()
                // ponytail: Auto alle 30 s abfragen statt Live-Kanal wie auf iOS – reicht für die Anzeige
                vehicle.refresh(userId)
                de.koeven.meeterz.widget.WidgetSnapshotWriter.update(appContext)
                delay(30_000)
            }
        }
    }

    fun endSession() {
        session?.cancel(); session = null
        messages.reset(); meetups.reset()
        de.koeven.meeterz.sound.SoundStore.reset(); de.koeven.meeterz.sound.SoundMoments.reset()
        if (::appContext.isInitialized) {
            de.koeven.meeterz.widget.WidgetSnapshotWriter.clear(appContext)
            scope.launch { de.koeven.meeterz.widget.WidgetSnapshotWriter.update(appContext, force = true) }
        }
    }

    suspend fun refreshFriends() {
        runCatching { Backend.client.postgrest.rpc("my_friends").decodeList<FriendRow>() }
            .onSuccess { _friends.value = it; hub.sync(it); requestFreshPositions(it) }
        routes.refresh()
    }

    private val lastPoke = mutableMapOf<String, Long>()
    /** App sichtbar? (nur dann Freunde wecken – wie iOS bei offener App) */
    @Volatile var foreground = false

    /** Freunde mit veralteter Position (> 45 s) bitten, kurz ihren Standort zu senden – je Freund höchstens alle 2 Min. */
    private fun requestFreshPositions(rows: List<FriendRow>) {
        if (!foreground) return
        val now = System.currentTimeMillis()
        val stale = rows.filter { it.isAccepted }.filter { f ->
            val age = hub.positions.value[f.friendId]?.ageSeconds ?: f.locationUpdatedAt?.let { runCatching { now / 1000.0 - java.time.Instant.parse(it).epochSecond }.getOrNull() } ?: return@filter false
            age > 45 && now - (lastPoke[f.friendId] ?: 0) > 120_000
        }.map { it.friendId }
        stale.forEach { lastPoke[it] = now }
        PushService.requestLocations(stale)
    }

    // Freunde verwalten (gleiche RPCs wie FriendsStore auf iOS)

    suspend fun sendFriendRequest(handle: String): Boolean {
        val h = handle.trim().lowercase()
        val ok = mutate { Backend.client.postgrest.rpc("send_friend_request", buildJsonObject { put("target_handle", h) }) }
        if (ok) _friends.value.firstOrNull { it.handle == h }?.let { PushService.notify("friend_request", it.friendId) }
        return ok
    }

    suspend fun respond(row: FriendRow, accept: Boolean): Boolean {
        val ok = mutate { Backend.client.postgrest.rpc("respond_friend_request", buildJsonObject { put("request_id", row.friendshipId); put("accept", accept) }) }
        if (ok && accept) PushService.notify("friend_accepted", row.friendId)
        return ok
    }

    suspend fun removeFriend(row: FriendRow) = mutate {
        Backend.client.postgrest.rpc("remove_friend", buildJsonObject { put("friend_id", row.friendId) })
    }

    private suspend fun mutate(op: suspend () -> Unit): Boolean {
        friendError.value = null
        return runCatching { op(); refreshFriends() }
            .onFailure { friendError.value = it.message?.substringBefore("\n") }
            .isSuccess
    }

    /** Teilen an/aus (unbegrenzt) */
    val profile: de.koeven.meeterz.data.Profile? get() = (auth.state.value as? AuthRepository.State.Ready)?.profile

    /** Teilen an/aus, optional bis zu einem Zeitpunkt (null = unbegrenzt) */
    suspend fun setSharing(enabled: Boolean, until: java.time.Instant? = null) {
        val id = profile?.id ?: return
        runCatching {
            Backend.client.from("profiles").update(buildJsonObject {
                put("sharing_enabled", enabled)
                if (until != null) put("sharing_until", until.toString()) else put("sharing_until", JsonNull)
            }) { filter { eq("id", id) } }
            auth.reload()
        }
    }

    /** Wie lange teilen (wie SharingMode auf iOS) */
    enum class SharingMode(val title: String, val explanation: String) {
        FIFTEEN("15 Min.", "Das Teilen endet automatisch nach 15 Minuten."),
        HOUR("1 Std.", "Das Teilen endet automatisch nach einer Stunde."),
        UNTIL_ARRIVAL("Bis Ankunft", "Das Teilen endet 15 Minuten nach der Ankunft deiner nächsten Fahrt."),
        ALWAYS("Immer", "Freunde sehen dich, bis du das Teilen pausierst.");

        fun until(etaSeconds: Long?): java.time.Instant? = when (this) {
            FIFTEEN -> java.time.Instant.now().plusSeconds(15 * 60)
            HOUR -> java.time.Instant.now().plusSeconds(3600)
            UNTIL_ARRIVAL -> etaSeconds?.let { java.time.Instant.ofEpochSecond(it + 15 * 60) }
            ALWAYS -> null
        }
    }

    var sharingMode: SharingMode
        get() = SharingMode.entries.getOrNull(appContext.getSharedPreferences("app", 0).getInt("sharingMode", 3)) ?: SharingMode.ALWAYS
        set(v) { appContext.getSharedPreferences("app", 0).edit().putInt("sharingMode", v.ordinal).apply() }

    suspend fun shareLocation(mode: SharingMode) {
        sharingMode = mode
        if (profile?.isIncognito == true) stopIncognito()
        val eta = de.koeven.meeterz.nav.NavigationController.guidance.value?.let { System.currentTimeMillis() / 1000 + it.remainingSeconds.toLong() }
        setSharing(true, mode.until(eta))
    }

    /** Inkognito: Freunde sehen weder Standort noch Route (und erfahren es nicht); null = bis ich es ausschalte */
    suspend fun startIncognito(seconds: Long?) {
        val p = profile ?: return
        hub.announceGone(p.id)
        val until = java.time.Instant.now().plusSeconds(seconds ?: (50L * 365 * 86400))
        runCatching {
            Backend.client.from("profiles").update(buildJsonObject { put("incognito_until", until.toString()) }) { filter { eq("id", p.id) } }
            auth.reload()
        }
        if (profile?.isIncognito == true) runCatching { Backend.client.postgrest.rpc("clear_active_route") }
    }

    suspend fun stopIncognito() {
        val p = profile ?: return
        runCatching {
            Backend.client.from("profiles").update(buildJsonObject { put("incognito_until", JsonNull) }) { filter { eq("id", p.id) } }
            auth.reload()
        }
    }

    /** Eigene Routen dauerhaft verbergen */
    suspend fun setHideRoutes(hide: Boolean) {
        val p = profile ?: return
        runCatching {
            Backend.client.from("profiles").update(buildJsonObject { put("hide_routes", hide) }) { filter { eq("id", p.id) } }
            auth.reload()
            if (hide) Backend.client.postgrest.rpc("clear_active_route")
        }
    }

    /** Freunde, vor denen ich Standort und Routen verberge */
    private val _hiddenFrom = MutableStateFlow<Set<String>>(emptySet())
    val hiddenFrom: StateFlow<Set<String>> = _hiddenFrom

    suspend fun refreshHidden() {
        runCatching { Backend.client.postgrest.rpc("my_hidden_friends").decodeList<String>() }.onSuccess { _hiddenFrom.value = it.toSet() }
    }

    suspend fun setHidden(friendId: String, hidden: Boolean) {
        runCatching {
            Backend.client.postgrest.rpc("set_hidden_from", buildJsonObject { put("friend_id", friendId); put("hidden", hidden) })
            _hiddenFrom.value = if (hidden) _hiddenFrom.value + friendId else _hiddenFrom.value - friendId
            // Sofort von seiner Karte nehmen (er bekommt danach keine Positionen mehr)
            if (hidden) profile?.id?.let { hub.announceGone(it) }
        }.onFailure { Diag.log("Verbergen fehlgeschlagen: ${it.message}") }
    }
}
