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
    lateinit var favorites: FavoritesStore
        private set

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
            while (isActive) {
                refreshFriends()
                // ponytail: Nachrichten alle 30 s und bei jedem Push statt Live-Kanal wie auf iOS
                messages.refresh()
                // ponytail: Auto alle 30 s abfragen statt Live-Kanal wie auf iOS – reicht für die Anzeige
                vehicle.refresh(userId)
                delay(30_000)
            }
        }
    }

    fun endSession() { session?.cancel(); session = null; messages.reset() }

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
    suspend fun setSharing(enabled: Boolean) {
        val id = (auth.state.value as? AuthRepository.State.Ready)?.profile?.id ?: return
        runCatching {
            Backend.client.from("profiles").update(buildJsonObject { put("sharing_enabled", enabled); put("sharing_until", JsonNull) }) {
                filter { eq("id", id) }
            }
            auth.reload()
        }
    }
}
