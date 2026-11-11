package de.koeven.meeterz.suggest

import de.koeven.meeterz.tr
import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.provider.CalendarContract
import androidx.core.content.ContextCompat
import com.mapbox.common.MapboxOptions
import de.koeven.meeterz.AppState
import de.koeven.meeterz.Diag
import de.koeven.meeterz.ev.ChargePlanner
import de.koeven.meeterz.nav.RoutePreferences
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.request.get
import io.ktor.client.statement.bodyAsText
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.text.DateFormat
import java.util.Date

private fun clock(ms: Long) = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(ms))

/** Fahrzeit mit Verkehr (Mapbox Directions, driving-traffic) – ohne laufende Navigation nutzbar (Hintergrund, Erinnerungen) */
object Directions {
    private val http by lazy { HttpClient(OkHttp) }

    /** Sekunden oder null */
    suspend fun duration(fromLat: Double, fromLng: Double, toLat: Double, toLng: Double): Double? = runCatching {
        val exclude = RoutePreferences.exclude?.let { "&exclude=$it" } ?: ""
        val body = http.get("https://api.mapbox.com/directions/v5/mapbox/driving-traffic/$fromLng,$fromLat;$toLng,$toLat" +
            "?overview=false&alternatives=false$exclude&access_token=${MapboxOptions.accessToken}").bodyAsText()
        Json.parseToJsonElement(body).jsonObject["routes"]?.jsonArray?.firstOrNull()?.jsonObject?.get("duration")?.jsonPrimitive?.double
    }.getOrNull()
}

/**
 * Routenvorschlag wie RouteSuggestions.swift: EIN wahrscheinliches Ziel – ein Kalendertermin mit Ort, zu dem man bald
 * losfahren muss, sonst ein Ort, den man um diese Zeit an diesem Wochentag oft ansteuert.
 */
object RouteSuggestions {
    data class Suggestion(val id: String, val name: String, val address: String?, val lat: Double, val lng: Double,
                          val calendarTitle: String?, val calendarStart: Long?, val travelSeconds: Double) {
        val arrival get() = System.currentTimeMillis() + (travelSeconds * 1000).toLong()
        val minutes get() = maxOf(1, Math.round(travelSeconds / 60).toInt())
        /** „Arbeit“ bzw. Termintitel */
        val title get() = calendarTitle ?: name
        /** Wohin: beim Termin der Ort, sonst die Adresse */
        val destinationText: String get() = if (calendarTitle != null) {
            val a = address?.replace("\n", ", ")
            when {
                name.isEmpty() || name == title -> a.orEmpty()
                a != null && !a.startsWith(name) -> "$name · $a"
                else -> a ?: name
            }
        } else address?.replace("\n", ", ").orEmpty()
        /** „Termin 09:00 · 24 Min. · Ankunft 08:41“ bzw. „Oft um diese Zeit · …“ */
        val detailText get() = listOf(calendarStart?.let { tr("Termin %@", clock(it)) } ?: tr("Oft um diese Zeit"), tr("%@ Min.", minutes), tr("Ankunft %@", clock(arrival))).joinToString(" · ")
        /** „24 Min. · Termin 09:00“ bzw. „24 Min. · Ankunft 08:12“ */
        val subtitle get() = tr("%@ Min. · ", minutes) + (calendarStart?.let { tr("Termin %@", clock(it)) } ?: tr("Ankunft %@", clock(arrival)))
    }

    private val _current = MutableStateFlow<Suggestion?>(null)
    val current: StateFlow<Suggestion?> = _current
    private val dismissed = mutableMapOf<String, Long>()
    private var computedAt = 0L
    private val geocoded = mutableMapOf<String, Pair<Double, Double>?>()

    private fun prefs() = AppState.appContextOrNull()?.getSharedPreferences("app", 0)
    var frequentEnabled: Boolean
        get() = prefs()?.getBoolean("suggest.frequent", true) != false
        set(v) { prefs()?.edit()?.putBoolean("suggest.frequent", v)?.apply() }
    var calendarEnabled: Boolean
        get() = prefs()?.getBoolean("suggest.calendar", false) == true
        set(v) { prefs()?.edit()?.putBoolean("suggest.calendar", v)?.apply() }

    /** Vorschlag für jetzt (höchstens alle 5 Minuten neu; nicht während einer Führung) */
    suspend fun refresh(force: Boolean = false) {
        if (!force && System.currentTimeMillis() - computedAt < 5 * 60_000) return
        computedAt = System.currentTimeMillis()
        val result = if (de.koeven.meeterz.nav.NavigationController.guidance.value != null) null else compute()
        if (result?.id != _current.value?.id || (result != null && result.minutes != _current.value?.minutes)) {
            Diag.log(result?.let { "Routenvorschlag: ${it.title} – ${it.subtitle}" } ?: "Routenvorschlag: keiner")
            _current.value = result
        }
    }

    /** „Nein“: weg und dasselbe Ziel 3 Stunden nicht mehr vorschlagen */
    fun dismissCurrent() {
        val c = _current.value ?: return
        dismissed[c.id] = System.currentTimeMillis() + 3 * 3_600_000
        _current.value = null
        Diag.log("Routenvorschlag abgelehnt: ${c.title}")
    }

    /** Fahrt gestartet: Vorschlag erledigt */
    fun clearCurrent() { _current.value = null; computedAt = System.currentTimeMillis() }

    private fun isDismissed(id: String) = (dismissed[id] ?: 0) > System.currentTimeMillis()

    private suspend fun compute(): Suggestion? {
        val here = AppState.lastLocation ?: return null
        if (calendarEnabled) calendar(here.latitude, here.longitude)?.let { return it }
        if (frequentEnabled) {
            val spot = FrequentPlaces.likely(System.currentTimeMillis(), here.latitude, here.longitude) ?: return null
            if (isDismissed(spot.id)) return null
            val travel = Directions.duration(here.latitude, here.longitude, spot.lat, spot.lng) ?: return null
            return Suggestion(spot.id, spot.name ?: tr("Häufiger Ort"), null, spot.lat, spot.lng, null, null, travel)
        }
        return null
    }

    fun calendarAllowed(c: Context) = ContextCompat.checkSelfPermission(c, Manifest.permission.READ_CALENDAR) == PackageManager.PERMISSION_GRANTED

    /** Termin mit Ort, zu dem man in spätestens 30 Minuten losfahren muss (Fahrzeit + 5 Min. Puffer) */
    private suspend fun calendar(lat: Double, lng: Double): Suggestion? {
        val c = AppState.appContextOrNull() ?: return null
        if (!calendarAllowed(c)) return null
        val now = System.currentTimeMillis()
        data class Event(val id: Long, val title: String, val location: String, val start: Long)
        val events = withContext(Dispatchers.IO) {
            runCatching {
                val uri = CalendarContract.Instances.CONTENT_URI.buildUpon()
                    .appendPath((now - 10 * 60_000).toString()).appendPath((now + 6 * 3_600_000).toString()).build()
                c.contentResolver.query(uri, arrayOf(CalendarContract.Instances.EVENT_ID, CalendarContract.Instances.TITLE,
                    CalendarContract.Instances.EVENT_LOCATION, CalendarContract.Instances.BEGIN, CalendarContract.Instances.ALL_DAY),
                    null, null, CalendarContract.Instances.BEGIN + " ASC")?.use { cur ->
                    buildList {
                        while (cur.moveToNext()) {
                            if (cur.getInt(4) == 1) continue
                            val loc = cur.getString(2)?.trim().orEmpty()
                            if (loc.isEmpty()) continue
                            add(Event(cur.getLong(0), cur.getString(1).orEmpty(), loc, cur.getLong(3)))
                        }
                    }
                }.orEmpty()
            }.getOrDefault(emptyList())
        }
        for (e in events.filter { it.start > now - 10 * 60_000 }.take(5)) {
            val (eLat, eLng) = geocode(c, e.location) ?: continue
            val air = ChargePlanner.distance(lat, lng, eLat, eLng)
            if (air <= 300) continue
            if (e.start - now - air / (40 / 3.6) * 1000 >= 3 * 3_600_000) continue   // grob: 40 km/h Luftlinie
            val id = "event-${e.id}-${e.start}"
            if (isDismissed(id)) continue
            val travel = Directions.duration(lat, lng, eLat, eLng) ?: continue
            val leave = e.start - (travel * 1000).toLong() - 5 * 60_000
            if (leave - now > 30 * 60_000) continue   // noch zu früh
            val name = e.location.substringBefore("\n").substringBefore(",")
            return Suggestion(id, name, e.location, eLat, eLng, e.title.ifEmpty { name }, e.start, travel)
        }
        return null
    }

    private suspend fun geocode(c: Context, text: String): Pair<Double, Double>? {
        if (text in geocoded) return geocoded[text]
        // Online-Termine haben oft nur einen Link als Ort
        val lower = text.lowercase()
        if ("http" in lower || "teams" in lower || "zoom" in lower) return null
        val r = withContext(Dispatchers.IO) {
            @Suppress("DEPRECATION")
            runCatching { android.location.Geocoder(c, java.util.Locale.GERMANY).getFromLocationName(text, 1)?.firstOrNull() }.getOrNull()
        }?.let { it.latitude to it.longitude }
        geocoded[text] = r
        return r
    }
}
