package de.koeven.meeterz

import android.content.Context
import de.koeven.meeterz.auth.AuthRepository
import de.koeven.meeterz.data.Backend
import de.koeven.meeterz.data.FavoritesStore
import de.koeven.meeterz.data.FriendRow
import de.koeven.meeterz.data.VehicleStore
import de.koeven.meeterz.live.LiveLocationHub
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
    lateinit var favorites: FavoritesStore
        private set

    /** Letzter eigener Standort (für Suche und Routenplanung) */
    @Volatile var lastLocation: android.location.Location? = null

    private val _friends = MutableStateFlow<List<FriendRow>>(emptyList())
    val friends: StateFlow<List<FriendRow>> = _friends
    val friendError = MutableStateFlow<String?>(null)

    private var session: Job? = null

    fun init(context: Context) { favorites = FavoritesStore(context) }

    /** Nach der Anmeldung: Senden starten, alle 30 s Freunde und Auto laden (wie refreshSocial auf iOS) */
    fun startSession(userId: String) {
        if (session?.isActive == true) return
        favorites.load(userId)
        session = scope.launch {
            hub.startPublishing(userId)
            while (isActive) {
                refreshFriends()
                // ponytail: Auto alle 30 s abfragen statt Live-Kanal wie auf iOS – reicht für die Anzeige
                vehicle.refresh(userId)
                delay(30_000)
            }
        }
    }

    fun endSession() { session?.cancel(); session = null }

    suspend fun refreshFriends() {
        runCatching { Backend.client.postgrest.rpc("my_friends").decodeList<FriendRow>() }
            .onSuccess { _friends.value = it; hub.sync(it) }
    }

    // Freunde verwalten (gleiche RPCs wie FriendsStore auf iOS)

    suspend fun sendFriendRequest(handle: String) = mutate {
        Backend.client.postgrest.rpc("send_friend_request", buildJsonObject { put("target_handle", handle.trim().lowercase()) })
    }

    suspend fun respond(row: FriendRow, accept: Boolean) = mutate {
        Backend.client.postgrest.rpc("respond_friend_request", buildJsonObject { put("request_id", row.friendshipId); put("accept", accept) })
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
