package de.koeven.meeterz.suggest

import de.koeven.meeterz.tr
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import de.koeven.meeterz.AppState
import de.koeven.meeterz.Diag
import de.koeven.meeterz.R
import de.koeven.meeterz.nav.NavigationController
import de.koeven.meeterz.ui.MainActivity
import de.koeven.meeterz.ui.meetupTime
import java.text.DateFormat
import java.util.Date

/**
 * „In 10 Min. losfahren“ (wie DepartureReminder.swift): Für angenommene Treffen mit Uhrzeit die Abfahrtszeit aus
 * Fahrzeit mit Verkehr berechnen und eine Mitteilung planen. Nachgerechnet wird bei jeder Aktualisierung der Treffen
 * (höchstens alle 10 Min.; weiter entfernte Treffen stündlich). Die Mitteilung stellt Android zu (AlarmManager).
 */
object DepartureReminder {
    private const val LEAD = 10 * 60_000L
    private const val BUFFER = 5 * 60_000L
    private var lastRun = 0L
    private var lastIds = emptySet<String>()
    private val lastCalc = mutableMapOf<String, Long>()
    private val scheduled = mutableSetOf<String>()

    private fun prefs(c: Context) = c.getSharedPreferences("app", 0)

    suspend fun refresh(context: Context) {
        val now = System.currentTimeMillis()
        val upcoming = AppState.meetups.accepted.filter { m -> m.meetAtSeconds?.let { it * 1000 in now..(now + 24 * 3_600_000) } == true }
        val ids = upcoming.map { it.id }.toSet()
        val setChanged = ids != lastIds
        if (!setChanged && now - lastRun < 10 * 60_000) return
        lastRun = now; lastIds = ids
        // Abgesagte/vergangene Treffen: geplante Erinnerung entfernen
        (scheduled - ids).forEach { cancel(context, it) }
        val here = AppState.lastLocation ?: return
        val fired = prefs(context).getStringSet("depart.fired", emptySet()).orEmpty().toMutableSet()

        for (m in upcoming) {
            val at = m.meetAtSeconds!! * 1000
            if (at - now > 4 * 3_600_000 && !setChanged && now - (lastCalc[m.id] ?: 0) < 3_600_000) continue
            // Schon unterwegs dorthin: keine Erinnerung
            NavigationController.guidance.value?.let { g ->
                if (m.distanceTo(g.destination.lat, g.destination.lng) < 300) { cancel(context, m.id); return@let true } else null
            }?.let { continue }
            val travel = Directions.duration(here.latitude, here.longitude, m.lat, m.lng) ?: continue
            lastCalc[m.id] = now
            val depart = at - (travel * 1000).toLong() - BUFFER
            val fire = depart - LEAD
            val minutes = Math.round(travel / 60)
            val body = tr("Um %@ bei %@ (%@) · ca. %@ Min. Fahrt", meetupTime(m.meetAtSeconds!!), m.withText, m.placeName, minutes)
            if (fire > now + 30_000) {
                schedule(context, m.id, tr("In 10 Min. losfahren"), body, m.placeName, m.lat, m.lng, fire)
            } else if (m.id !in fired) {
                val late = if (now > depart) Math.round((now - depart) / 60_000.0) else 0
                show(context, m.id, if (late > 2) tr("Jetzt losfahren – ca. %lld Min. zu spät", late) else tr("Jetzt losfahren"), body, m.placeName, m.lat, m.lng)
                fired += m.id
            }
            Diag.log("Losfahren-Erinnerung ${m.placeName}: Abfahrt ${DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(depart))} ($minutes Min.)")
        }
        prefs(context).edit().putStringSet("depart.fired", fired.intersect(AppState.meetups.meetups.value.map { it.id }.toSet())).apply()
    }

    private fun intent(c: Context, id: String, title: String, body: String, name: String, lat: Double, lng: Double) =
        Intent(c, DepartureReceiver::class.java).putExtra("id", id).putExtra("title", title).putExtra("body", body)
            .putExtra("name", name).putExtra("lat", lat).putExtra("lng", lng)

    private fun schedule(c: Context, id: String, title: String, body: String, name: String, lat: Double, lng: Double, at: Long) {
        val pi = PendingIntent.getBroadcast(c, id.hashCode(), intent(c, id, title, body, name, lat, lng),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        // ponytail: ungenauer Wecker (kann im Doze einige Minuten später kommen) – exakte Wecker bräuchten eine Sondererlaubnis
        c.getSystemService(AlarmManager::class.java).setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
        scheduled += id
    }

    private fun cancel(c: Context, id: String) {
        val pi = PendingIntent.getBroadcast(c, id.hashCode(), Intent(c, DepartureReceiver::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_NO_CREATE) ?: return
        c.getSystemService(AlarmManager::class.java).cancel(pi)
        scheduled -= id
    }

    /** Mitteilung; Tippen öffnet die Route zum Treffpunkt */
    fun show(c: Context, id: String, title: String, body: String, name: String, lat: Double, lng: Double) {
        val manager = c.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26 && manager.getNotificationChannel("depart") == null) {
            manager.createNotificationChannel(NotificationChannel("depart", tr("Losfahren"), NotificationManager.IMPORTANCE_HIGH))
        }
        val open = PendingIntent.getActivity(c, id.hashCode(), MainActivity.planIntent(c, name, lat, lng),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        runCatching {
            manager.notify(id.hashCode(), NotificationCompat.Builder(c, "depart")
                .setSmallIcon(R.drawable.ic_launcher_foreground)
                .setContentTitle(title).setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setCategory(NotificationCompat.CATEGORY_REMINDER)
                .setContentIntent(open).setAutoCancel(true).build())
        }
    }
}

class DepartureReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra("id") ?: return
        DepartureReminder.show(context, id, intent.getStringExtra("title") ?: tr("In 10 Min. losfahren"), intent.getStringExtra("body").orEmpty(),
            intent.getStringExtra("name").orEmpty(), intent.getDoubleExtra("lat", 0.0), intent.getDoubleExtra("lng", 0.0))
    }
}
