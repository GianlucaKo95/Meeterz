package de.koeven.meeterz

import de.koeven.meeterz.auth.AuthRepository
import de.koeven.meeterz.data.Backend
import de.koeven.meeterz.data.FriendRow
import de.koeven.meeterz.live.LiveLocationHub
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

/** Gegenstück zu AppModel auf iOS: hält Anmeldung, Freunde und Live-Positionen für App und Android Auto */
object AppState {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    val auth = AuthRepository(scope).also { it.start() }
    val hub = LiveLocationHub(scope)

    /** Letzter eigener Standort (für Suche und Routenplanung) */
    @Volatile var lastLocation: android.location.Location? = null

    private val _friends = MutableStateFlow<List<FriendRow>>(emptyList())
    val friends: StateFlow<List<FriendRow>> = _friends

    private var session: Job? = null

    /** Nach der Anmeldung: Senden starten, alle 30 s Freunde laden (wie refreshSocial auf iOS) */
    fun startSession(userId: String) {
        if (session?.isActive == true) return
        session = scope.launch {
            hub.startPublishing(userId)
            while (isActive) {
                refreshFriends()
                delay(30_000)
            }
        }
    }

    fun endSession() { session?.cancel(); session = null }

    suspend fun refreshFriends() {
        runCatching { Backend.client.postgrest.rpc("my_friends").decodeList<FriendRow>() }
            .onSuccess { _friends.value = it; hub.sync(it) }
    }
}
