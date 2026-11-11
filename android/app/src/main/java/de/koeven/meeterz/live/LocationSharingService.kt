package de.koeven.meeterz.live

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import de.koeven.meeterz.AppState
import de.koeven.meeterz.R
import de.koeven.meeterz.auth.AuthRepository
import de.koeven.meeterz.ui.MainActivity
import kotlinx.coroutines.launch

/**
 * Standort auch bei geschlossener App an die Freunde senden (iOS: Hintergrund-Standort).
 * Android verlangt dafür einen Vordergrunddienst mit sichtbarer Benachrichtigung.
 */
class LocationSharingService : Service() {
    private var listener: LocationListener? = null

    override fun onBind(intent: Intent?): IBinder? = null

    @SuppressLint("MissingPermission")
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ServiceCompat.startForeground(
            this, NOTIFICATION_ID, notification(),
            if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION else 0,
        )
        if (listener == null) {
            val manager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
            val l = LocationListener { loc ->
                AppState.lastLocation = loc
                de.koeven.meeterz.suggest.FrequentPlaces.onLocation(loc)
                AppState.scope.launch {
                    de.koeven.meeterz.sound.SoundMoments.onLocation(loc)
                    AppState.meetups.checkArrival(loc)
                }
                val profile = (AppState.auth.state.value as? AuthRepository.State.Ready)?.profile ?: return@LocationListener
                AppState.scope.launch { AppState.hub.publish(loc, profile.id, profile.isSharingNow) }
            }
            // Wie iOS: genau genug fürs Teilen, aber nicht jede Sekunde (der Hub sendet in Fahrt alle ~5 s)
            for (provider in listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)) {
                if (manager.isProviderEnabled(provider)) manager.requestLocationUpdates(provider, 3_000L, 10f, l)
            }
            listener = l
        }
        return START_STICKY
    }

    override fun onDestroy() {
        listener?.let { (getSystemService(Context.LOCATION_SERVICE) as LocationManager).removeUpdates(it) }
        listener = null
        super.onDestroy()
    }

    private fun notification(): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26 && manager.getNotificationChannel(CHANNEL) == null) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "Standort teilen", NotificationManager.IMPORTANCE_LOW))
        }
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_launcher_foreground)
            .setContentTitle("Meeterz teilt deinen Standort")
            .setContentText("Deine Freunde sehen, wo du bist.")
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val CHANNEL = "sharing"
        private const val NOTIFICATION_ID = 1

        fun start(context: Context) = ContextCompat.startForegroundService(context, Intent(context, LocationSharingService::class.java))
        fun stop(context: Context) = context.stopService(Intent(context, LocationSharingService::class.java))
    }
}
