package de.koeven.meeterz.nav

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import de.koeven.meeterz.AppState
import de.koeven.meeterz.R
import de.koeven.meeterz.ev.ChargeMonitor
import de.koeven.meeterz.ui.MainActivity
import de.koeven.meeterz.ui.km
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Date

/**
 * Laufende Führung als dauerhafte Benachrichtigung (Gegenstück zur Live-Aktivität auf iOS): nächste Abbiegung mit
 * Entfernung, Ankunft, Akku am Ziel – auf dem Sperrbildschirm und in der Statusleiste. Endet mit der Führung.
 */
object NavigationNotification {
    private const val CHANNEL = "navigation"
    private const val ID = 7
    private var lastText = ""
    private var lastPost = 0L

    fun start(context: Context) {
        val app = context.applicationContext
        val manager = app.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26 && manager.getNotificationChannel(CHANNEL) == null) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "Navigation", NotificationManager.IMPORTANCE_LOW).apply {
                lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
                setShowBadge(false)
            })
        }
        AppState.scope.launch {
            combine(NavigationController.guidance, ChargeMonitor.forecast) { g, f -> g to f }.collect { (g, f) ->
                if (g == null) { manager.cancel(ID); lastText = ""; return@collect }
                val title = "${km(g.distanceToTurn)} · ${g.instruction.ifEmpty { g.destination.name }}"
                val now = System.currentTimeMillis()
                // Abbiegung neu: sofort; sonst höchstens alle 5 s (Entfernung zählt herunter)
                val turnChanged = g.instruction != lastText
                if (!turnChanged && now - lastPost < 5_000) return@collect
                lastText = g.instruction; lastPost = now
                val arrival = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(now + (g.remainingSeconds * 1000).toLong()))
                val text = listOfNotNull("Ankunft $arrival", km(g.remainingDistance), f?.text).joinToString(" · ")
                val open = PendingIntent.getActivity(app, 0, Intent(app, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
                val notification = NotificationCompat.Builder(app, CHANNEL)
                    .setSmallIcon(R.drawable.ic_launcher_foreground)
                    .setContentTitle(title)
                    .setContentText(text)
                    .setSubText(g.destination.name)
                    .setContentIntent(open)
                    .setOngoing(true)
                    .setOnlyAlertOnce(true)
                    .setSilent(true)
                    .setCategory(NotificationCompat.CATEGORY_NAVIGATION)
                    .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                    .setColor(0xFF6FF3DA.toInt())
                    .build()
                runCatching { manager.notify(ID, notification) }   // ohne Erlaubnis für Benachrichtigungen: nichts
            }
        }
    }
}
