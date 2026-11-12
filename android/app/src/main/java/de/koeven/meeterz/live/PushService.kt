package de.koeven.meeterz.live

import de.koeven.meeterz.tr
import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.location.LocationManager
import android.os.Build
import androidx.core.app.NotificationCompat
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import de.koeven.meeterz.AppState
import de.koeven.meeterz.R
import de.koeven.meeterz.auth.AuthRepository
import de.koeven.meeterz.data.Backend
import de.koeven.meeterz.ui.MainActivity
import io.github.jan.supabase.functions.functions
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** Push über Firebase (iOS: APNs). Sichtbare Mitteilungen und der stille „Standort senden“-Push. */
class PushService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        AppState.scope.launch { register(token) }
    }

    override fun onMessageReceived(message: RemoteMessage) {
        when (message.data["kind"]) {
            // Freund hat die Karte offen und möchte meine aktuelle Position
            "locate" -> sendLocationOnce(this)
            else -> message.notification?.let { show(this, it.title ?: tr("Meeterz"), it.body ?: "") }
        }
        // Neue Anfrage, Nachricht o. Ä.: gleich aktualisieren
        AppState.scope.launch {
            AppState.refreshFriends(); AppState.messages.refresh()
            if (message.data["kind"]?.startsWith("meetup") == true) AppState.meetups.refresh()
        }
    }

    companion object {
        private const val CHANNEL = "meeterz"

        fun available(context: Context) = FirebaseApp.getApps(context).isNotEmpty()

        /** Nach der Anmeldung: Token holen und am Server hinterlegen */
        suspend fun registerCurrent(context: Context) {
            if (!available(context)) return
            runCatching { register(FirebaseMessaging.getInstance().token.await()) }
        }

        private suspend fun register(token: String) {
            if (AppState.auth.state.value !is AuthRepository.State.Ready) return
            runCatching {
                Backend.client.postgrest.rpc("register_device", buildJsonObject {
                    put("device_token", token); put("env", "production"); put("platform", "android")
                })
            }
        }

        /** Anderen Nutzer benachrichtigen (wie PushService.notify auf iOS) – Fehler sind egal */
        fun notify(kind: String, target: String, meetupId: String? = null, messageId: String? = null) {
            AppState.scope.launch {
                runCatching {
                    Backend.client.functions.invoke("notify", buildJsonObject {
                        put("kind", kind); put("target", target)
                        meetupId?.let { put("meetup_id", it) }; messageId?.let { put("message_id", it) }
                    })
                }
            }
        }

        /** Freunde bitten, kurz ihren Standort zu senden (stiller Push) */
        fun requestLocations(users: List<String>) {
            if (users.isEmpty()) return
            AppState.scope.launch {
                runCatching { Backend.client.functions.invoke("request_location", buildJsonObject { put("targets", JsonArray(users.map { JsonPrimitive(it) })) }) }
            }
        }

        @SuppressLint("MissingPermission")
        private fun sendLocationOnce(context: Context) {
            val profile = (AppState.auth.state.value as? AuthRepository.State.Ready)?.profile ?: return
            val manager = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
            val loc = runCatching {
                listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER).mapNotNull { manager.getLastKnownLocation(it) }.maxByOrNull { it.time }
            }.getOrNull() ?: return
            AppState.lastLocation = loc
            AppState.scope.launch {
                AppState.hub.startPublishing(profile.id)
                AppState.hub.publish(loc, profile.id, profile.sharingEnabled, force = true)
            }
        }

        fun show(context: Context, title: String, body: String) {
            val manager = context.getSystemService(NotificationManager::class.java)
            if (Build.VERSION.SDK_INT >= 26 && manager.getNotificationChannel(CHANNEL) == null) {
                manager.createNotificationChannel(NotificationChannel(CHANNEL, tr("Freunde und Treffen"), NotificationManager.IMPORTANCE_HIGH))
            }
            val open = PendingIntent.getActivity(context, 0, Intent(context, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
            manager.notify(System.currentTimeMillis().toInt(), NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(title)
                .setContentText(body)
                .setContentIntent(open)
                .setAutoCancel(true)
                .build())
        }
    }
}
