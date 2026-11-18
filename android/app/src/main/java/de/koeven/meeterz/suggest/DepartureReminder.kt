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
import kotlinx.serialization.encodeToString

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

    /** Selbst geplante Ankunft („Ankunft um …“ in der Routenvorschau) – nur auf dem Gerät */
    @kotlinx.serialization.Serializable
    data class PlannedArrival(val id: String, val name: String, val address: String? = null, val lat: Double, val lng: Double, val at: Long,
                              /** `at` ist die gewählte Abfahrt („Abfahrt ab …“) statt der Ankunft */
                              val leave: Boolean = false)

    private fun planned(c: Context): List<PlannedArrival> = runCatching {
        kotlinx.serialization.json.Json.decodeFromString<List<PlannedArrival>>(prefs(c).getString("depart.planned", "[]")!!)
    }.getOrDefault(emptyList())

    private fun savePlanned(c: Context, list: List<PlannedArrival>) =
        prefs(c).edit().putString("depart.planned", kotlinx.serialization.json.Json.encodeToString(list)).apply()

    /** „Ankunft um …“ bzw. „Abfahrt ab …“ (`leave`): Ziel merken und die Losfahren-Erinnerung planen (ersetzt eine frühere Planung zum selben Ziel) */
    suspend fun plan(c: Context, name: String, address: String?, lat: Double, lng: Double, at: Long, leave: Boolean) {
        val now = System.currentTimeMillis()
        savePlanned(c, planned(c).filter { it.at > now && de.koeven.meeterz.ev.ChargePlanner.distance(it.lat, it.lng, lat, lng) > 150 } +
            PlannedArrival(java.util.UUID.randomUUID().toString(), name, address, lat, lng, at, leave))
        lastRun = 0
        refresh(c)
    }

    /**
     * Fahrzeit für Ankunft um `at` mit der üblichen Verkehrslage (wie iOS): Die Abfahrt hängt vom Verkehr ab und der
     * Verkehr von der Abfahrt – mit einer Schätzung beginnen und für die so berechnete Abfahrt höchstens zweimal nachrechnen.
     */
    private suspend fun travelArriving(fromLat: Double, fromLng: Double, lat: Double, lng: Double, at: Long): Double? {
        var travel = Directions.duration(fromLat, fromLng, lat, lng, at - 30 * 60_000) ?: return null
        repeat(2) {
            val next = Directions.duration(fromLat, fromLng, lat, lng, at - (travel * 1000).toLong() - BUFFER) ?: return travel
            val settled = Math.abs(next - travel) < 60
            travel = next
            if (settled) return travel
        }
        return travel
    }

    /** Abfahrtszeit für „Ankunft um …“ (übliche Verkehrslage zu dieser Zeit, plus Puffer) */
    suspend fun departure(lat: Double, lng: Double, at: Long): Long? {
        val here = AppState.lastLocation ?: return null
        val travel = travelArriving(here.latitude, here.longitude, lat, lng, at) ?: return null
        return at - (travel * 1000).toLong() - BUFFER
    }

    /** Ankunftszeit für „Abfahrt ab …“ (übliche Verkehrslage zur gewählten Abfahrt) */
    suspend fun arrival(lat: Double, lng: Double, departAt: Long): Long? {
        val here = AppState.lastLocation ?: return null
        val travel = Directions.duration(here.latitude, here.longitude, lat, lng, departAt) ?: return null
        return departAt + (travel * 1000).toLong()
    }

    /** Was erinnert wird: Treffen mit Uhrzeit und selbst geplante Ankünfte */
    /** `leave`: `at` ist die Abfahrt; `body(minutes, other)` – other = berechnete Abfahrt bzw. bei `leave` die Ankunft */
    private data class Target(val id: String, val name: String, val lat: Double, val lng: Double, val at: Long,
                              val leave: Boolean = false, val body: (Long, Long) -> String)

    suspend fun refresh(context: Context) {
        val now = System.currentTimeMillis()
        val plans = planned(context).filter { it.at > now }
        savePlanned(context, plans)
        val meetups = AppState.meetups.accepted.filter { m -> m.meetAtSeconds?.let { it * 1000 in now..(now + 24 * 3_600_000) } == true }
        val upcoming = meetups.map { m ->
            Target(m.id, m.placeName, m.lat, m.lng, m.meetAtSeconds!! * 1000) { minutes, _ ->
                tr("Um %@ bei %@ (%@) · ca. %@ Min. Fahrt", meetupTime(m.meetAtSeconds!!), m.withText, m.placeName, minutes)
            }
        } + plans.filter { it.at < now + 24 * 3_600_000 }.map { p ->
            if (p.leave) Target(p.id, p.name, p.lat, p.lng, p.at, leave = true) { minutes, arrival ->
                tr("Abfahrt %@ nach %@ · Ankunft ca. %@ (%@ Min.)", meetupTime(p.at / 1000), p.name, DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(arrival)), minutes)
            }
            else Target(p.id, p.name, p.lat, p.lng, p.at) { minutes, _ -> tr("Ankunft um %@ in %@ · ca. %@ Min. Fahrt", meetupTime(p.at / 1000), p.name, minutes) }
        }
        val ids = upcoming.map { it.id }.toSet()
        val setChanged = ids != lastIds
        if (!setChanged && now - lastRun < 10 * 60_000) return
        lastRun = now; lastIds = ids
        // Abgesagte/vergangene Treffen: geplante Erinnerung entfernen
        (scheduled - ids).forEach { cancel(context, it) }
        val here = AppState.lastLocation ?: return
        val fired = prefs(context).getStringSet("depart.fired", emptySet()).orEmpty().toMutableSet()

        for (t in upcoming) {
            val at = t.at
            if (at - now > 4 * 3_600_000 && !setChanged && now - (lastCalc[t.id] ?: 0) < 3_600_000) continue
            // Schon unterwegs dorthin: keine Erinnerung
            NavigationController.guidance.value?.let { g ->
                if (de.koeven.meeterz.ev.ChargePlanner.distance(t.lat, t.lng, g.destination.lat, g.destination.lng) < 300) { cancel(context, t.id); return@let true } else null
            }?.let { continue }
            val travel = (if (t.leave) Directions.duration(here.latitude, here.longitude, t.lat, t.lng, at)
                          else travelArriving(here.latitude, here.longitude, t.lat, t.lng, at)) ?: continue
            lastCalc[t.id] = now
            val depart = if (t.leave) at else at - (travel * 1000).toLong() - BUFFER
            val fire = depart - LEAD
            val minutes = Math.round(travel / 60)
            val body = t.body(minutes, if (t.leave) at + (travel * 1000).toLong() else depart)
            if (fire > now + 30_000) {
                schedule(context, t.id, tr("In 10 Min. losfahren"), body, t.name, t.lat, t.lng, fire)
            } else if (t.id !in fired) {
                val late = if (now > depart) Math.round((now - depart) / 60_000.0) else 0
                show(context, t.id, if (late > 2) tr("Jetzt losfahren – ca. %lld Min. zu spät", late) else tr("Jetzt losfahren"), body, t.name, t.lat, t.lng)
                fired += t.id
            }
            Diag.log("Losfahren-Erinnerung ${t.name}: Abfahrt ${DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(depart))} ($minutes Min.)")
        }
        prefs(context).edit().putStringSet("depart.fired", fired.intersect(AppState.meetups.meetups.value.map { it.id }.toSet() + plans.map { it.id })).apply()
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
                .setSmallIcon(R.drawable.ic_notification)
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
