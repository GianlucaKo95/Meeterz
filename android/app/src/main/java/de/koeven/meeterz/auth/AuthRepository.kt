package de.koeven.meeterz.auth

import android.content.Context
import androidx.credentials.CredentialManager
import androidx.credentials.GetCredentialRequest
import com.google.android.libraries.identity.googleid.GetGoogleIdOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import de.koeven.meeterz.BuildConfig
import de.koeven.meeterz.data.Backend
import de.koeven.meeterz.data.Profile
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.auth.providers.Google
import io.github.jan.supabase.auth.providers.builtin.IDToken
import io.github.jan.supabase.auth.status.SessionStatus
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Columns
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import java.security.MessageDigest
import java.util.UUID

/** Wie AuthStore auf iOS: angemeldet? Profil vorhanden? */
class AuthRepository(private val scope: CoroutineScope) {
    sealed interface State {
        data object Loading : State
        data object SignedOut : State
        data class NeedsProfile(val userId: String, val suggestedName: String?) : State
        data class Ready(val profile: Profile) : State
    }

    private val client = Backend.client
    private val _state = MutableStateFlow<State>(State.Loading)
    val state: StateFlow<State> = _state
    val error = MutableStateFlow<String?>(null)
    private var suggestedName: String? = null

    fun start() {
        scope.launch {
            client.auth.sessionStatus.collect { status ->
                when (status) {
                    is SessionStatus.Authenticated -> load(status.session.user?.id)
                    is SessionStatus.NotAuthenticated -> { _state.value = State.SignedOut; cache(null); loadedOnline = false }
                    // Abgelaufen und kein Netz: Supabase versucht selbst weiter; bis dahin mit dem gespeicherten Profil (wie iOS)
                    is SessionStatus.RefreshFailure -> useCachedIfOffline(null)
                    else -> Unit
                }
            }
        }
    }

    private suspend fun load(userId: String?) {
        if (userId == null) { _state.value = State.SignedOut; return }
        runCatching {
            client.from("profiles")
                .select(Columns.raw("id, handle, display_name, sharing_enabled, sharing_until, incognito_until, hide_routes, avatar_version")) {
                    filter { eq("id", userId) }
                }.decodeList<Profile>()
        }.onSuccess { rows ->
            _state.value = rows.firstOrNull()?.let { State.Ready(it) } ?: State.NeedsProfile(userId, suggestedName)
            rows.firstOrNull()?.let { cache(it) }
            loadedOnline = true
        }.onFailure {
            if (it is java.io.IOException || it.cause is java.io.IOException ||
                it is io.github.jan.supabase.exceptions.HttpRequestException) {
                // Kein Netz: mit dem gespeicherten Profil öffnen und in 10 s neu versuchen (wie iOS)
                useCachedIfOffline(userId)
                scope.launch { kotlinx.coroutines.delay(10_000); if (!loadedOnline) load(userId) }
            } else error.value = it.message
        }
    }

    // Letztes Profil auf dem Gerät: ohne Netz öffnet die App damit die Karte (Offline-Karten, Navigation, Favoriten)
    // statt endlos zu laden. Beim Abmelden vergessen. (21.11., wie iOS AuthStore)
    private var loadedOnline = false
    private fun prefs() = de.koeven.meeterz.AppState.appContextOrNull()?.getSharedPreferences("auth", 0)
    private fun cache(profile: Profile?) {
        prefs()?.edit()?.apply {
            if (profile == null) remove("lastProfile")
            else putString("lastProfile", kotlinx.serialization.json.Json.encodeToString(Profile.serializer(), profile))
        }?.apply()
    }
    private fun useCachedIfOffline(userId: String?) {
        if (_state.value != State.Loading) return
        val cached = prefs()?.getString("lastProfile", null)?.let {
            runCatching { kotlinx.serialization.json.Json { ignoreUnknownKeys = true }.decodeFromString(Profile.serializer(), it) }.getOrNull()
        } ?: return
        if (userId != null && cached.id != userId) return
        de.koeven.meeterz.Diag.log("Ohne Netz: App startet mit gespeichertem Profil")
        _state.value = State.Ready(cached)
    }

    /** Mit Google anmelden (Credential Manager → ID-Token → Supabase) */
    suspend fun signInWithGoogle(context: Context) {
        error.value = null
        runCatching {
            val rawNonce = UUID.randomUUID().toString()
            val hashedNonce = MessageDigest.getInstance("SHA-256").digest(rawNonce.toByteArray())
                .joinToString("") { "%02x".format(it) }
            val option = GetGoogleIdOption.Builder()
                .setServerClientId(BuildConfig.GOOGLE_WEB_CLIENT_ID)
                .setFilterByAuthorizedAccounts(false)
                .setNonce(hashedNonce)
                .build()
            val request = GetCredentialRequest.Builder().addCredentialOption(option).build()
            val result = CredentialManager.create(context).getCredential(context, request)
            val google = GoogleIdTokenCredential.createFrom(result.credential.data)
            suggestedName = google.displayName
            client.auth.signInWith(IDToken) {
                idToken = google.idToken
                provider = Google
                nonce = rawNonce
            }
        }.onFailure { error.value = it.message }
    }

    suspend fun createProfile(userId: String, handle: String, displayName: String) {
        @Serializable data class NewProfile(val id: String, val handle: String, val display_name: String)
        runCatching {
            client.from("profiles").insert(NewProfile(userId, handle.trim().lowercase(), displayName.trim()))
            load(userId)
        }.onFailure { error.value = it.message }
    }

    /** Profil neu laden (z. B. nach Änderung am Teilen) */
    suspend fun reload() = load((state.value as? State.Ready)?.profile?.id)

    suspend fun signOut() { runCatching { client.auth.signOut() } }

    /** Gleicher serverseitiger Löschvorgang wie in der iOS-App. */
    suspend fun deleteAccount() {
        runCatching {
            client.postgrest.rpc("delete_account")
            client.auth.signOut()
        }.onFailure { error.value = it.message }
    }
}
