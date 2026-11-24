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
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.text.DateFormat
import java.util.Date

private fun clock(ms: Long) = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(ms))

/** Fahrzeit mit Verkehr (Mapbox Directions, driving-traffic) – ohne laufende Navigation nutzbar (Hintergrund, Erinnerungen) */
object Directions {
    private val http by lazy { HttpClient(OkHttp) }

    /**
     * Sekunden oder null. Mit `departAt` (ms) die für diese Abfahrtszeit übliche Verkehrslage (Mapbox `depart_at`,
     * Prognose aus historischen Daten) statt des aktuellen Verkehrs – nur für Zeiten mehr als 5 Min. in der Zukunft.
     */
    suspend fun duration(fromLat: Double, fromLng: Double, toLat: Double, toLng: Double, departAt: Long? = null): Double? = runCatching {
        val exclude = RoutePreferences.exclude?.let { "&exclude=$it" } ?: ""
        val depart = departAt?.takeIf { it > System.currentTimeMillis() + 5 * 60_000 }?.let {
            "&depart_at=" + java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mmXXX", java.util.Locale.US).format(java.util.Date(it))
                .replace("+", "%2B")
        } ?: ""
        val body = http.get("https://api.mapbox.com/directions/v5/mapbox/driving-traffic/$fromLng,$fromLat;$toLng,$toLat" +
            "?overview=false&alternatives=false$exclude$depart&access_token=${MapboxOptions.accessToken}").bodyAsText()
        Json.parseToJsonElement(body).jsonObject["routes"]?.jsonArray?.firstOrNull()?.jsonObject?.get("duration")?.jsonPrimitive?.double
    }.getOrNull()
}

/**
 * Fahrzeiten unter den Kacheln der Zielsuche (wie TileTravelTimes auf iOS): EINE Mapbox-Matrix-Anfrage von hier zu bis
 * zu 9 Zielen (driving-traffic erlaubt 10 Koordinaten). Neu gerechnet erst nach 500 m Weg oder 5 Minuten.
 */
object TileTravelTimes {
    private val http by lazy { HttpClient(OkHttp) }
    private var origin: Pair<Double, Double>? = null
    private var at = 0L
    private var times: Map<String, Double> = emptyMap()

    fun key(lat: Double, lng: Double) = String.format(java.util.Locale.US, "%.4f,%.4f", lat, lng)

    suspend fun get(lat: Double, lng: Double, targets: List<Pair<Double, Double>>): Map<String, Double> {
        val wanted = targets.filter { ChargePlanner.distance(lat, lng, it.first, it.second) >= 200 }.take(9)
        val fresh = origin?.let { ChargePlanner.distance(it.first, it.second, lat, lng) < 500 } == true &&
            System.currentTimeMillis() - at < 5 * 60_000
        if (fresh && wanted.all { key(it.first, it.second) in times }) return times
        if (wanted.isEmpty()) return times
        return runCatching {
            val coords = (listOf(lat to lng) + wanted).joinToString(";") { "${it.second},${it.first}" }
            val body = http.get("https://api.mapbox.com/directions-matrix/v1/mapbox/driving-traffic/$coords" +
                "?sources=0&annotations=duration&access_token=${MapboxOptions.accessToken}").bodyAsText()
            val row = Json.parseToJsonElement(body).jsonObject["durations"]!!.jsonArray[0].jsonArray
            val result = wanted.mapIndexedNotNull { i, t ->
                row.getOrNull(i + 1)?.jsonPrimitive?.doubleOrNull?.let { key(t.first, t.second) to it }
            }.toMap()
            origin = lat to lng; at = System.currentTimeMillis(); times = result
            result
        }.getOrDefault(times)
    }
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

    /** Ein Kalender des Geräts für die Auswahl in den Einstellungen */
    data class DeviceCalendar(val id: Long, val name: String, val account: String, val color: Int, val visible: Boolean)

    /** Alle Kalender des Geräts, nach Konto und Name sortiert */
    fun allCalendars(c: Context): List<DeviceCalendar> = if (!calendarAllowed(c)) emptyList() else runCatching {
        c.contentResolver.query(CalendarContract.Calendars.CONTENT_URI, arrayOf(CalendarContract.Calendars._ID,
            CalendarContract.Calendars.CALENDAR_DISPLAY_NAME, CalendarContract.Calendars.ACCOUNT_NAME,
            CalendarContract.Calendars.CALENDAR_COLOR, CalendarContract.Calendars.VISIBLE), null, null, null)?.use { cur ->
            buildList { while (cur.moveToNext()) add(DeviceCalendar(cur.getLong(0), cur.getString(1).orEmpty(),
                cur.getString(2).orEmpty(), cur.getInt(3), cur.getInt(4) == 1)) }
        }.orEmpty().sortedWith(compareBy({ it.account }, { it.name }))
    }.getOrDefault(emptyList())

    /** Selbst gewählte Kalender (IDs); null = Standard: in der Kalender-App eingeblendete (wie iOS chosenCalendars) */
    private var chosenCalendars: Set<Long>?
        get() = prefs()?.getStringSet("suggest.calendars", null)?.mapNotNull { it.toLongOrNull() }?.toSet()
        set(v) { prefs()?.edit()?.putStringSet("suggest.calendars", v?.map { it.toString() }?.toSet())?.apply() }

    fun isUsed(cal: DeviceCalendar) = chosenCalendars?.contains(cal.id) ?: cal.visible

    fun setUsed(c: Context, cal: DeviceCalendar, used: Boolean) {
        val chosen = (chosenCalendars ?: allCalendars(c).filter { isUsed(it) }.map { it.id }.toSet()).toMutableSet()
        if (used) chosen += cal.id else chosen -= cal.id
        chosenCalendars = chosen
        computedAt = 0L   // beim nächsten Mal neu berechnen
    }

    /** Vorschlag für jetzt (alle 5 Minuten neu, unterwegs alle 2 – Fahrzeit ab hier wie iOS; nicht während einer Führung) */
    suspend fun refresh(force: Boolean = false) {
        val moving = (AppState.lastLocation?.speed ?: 0f) > 3f
        if (!force && System.currentTimeMillis() - computedAt < (if (moving) 2 else 5) * 60_000) return
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

    /** Ohne Navigation am vorgeschlagenen Ziel angekommen: Vorschlag erledigt (wie iOS, 22.11.) */
    fun arrivedCheck(lat: Double, lng: Double, accuracy: Float) {
        val c = _current.value ?: return
        if (accuracy > 50 || de.koeven.meeterz.ev.ChargePlanner.distance(lat, lng, c.lat, c.lng) >= 150) return
        dismissed[c.id] = System.currentTimeMillis() + 3 * 3_600_000
        _current.value = null
        Diag.log("Am Vorschlagsziel angekommen: ${c.title}")
    }

    /** Fahrt gestartet: Vorschlag erledigt */
    /** Fahrt vorbei (Android Auto getrennt): abgelehnte Vorschläge dürfen bei der nächsten Fahrt wieder kommen (wie iOS) */
    fun newDrive() = dismissed.clear()

    fun clearCurrent() { _current.value = null; computedAt = System.currentTimeMillis() }

    private fun isDismissed(id: String) = (dismissed[id] ?: 0) > System.currentTimeMillis()

    private suspend fun compute(): Suggestion? {
        val here = AppState.lastLocation ?: return null
        if (calendarEnabled) calendar(here.latitude, here.longitude)?.let { return it }
        if (frequentEnabled) {
            val spot = FrequentPlaces.likely(System.currentTimeMillis(), here.latitude, here.longitude) ?: return null
            // Gelernter Ort = wo das Handy den Tag verbringt (bei der Arbeit am Schreibtisch im Gebäude). Ist es ein
            // Favorit (Zuhause, Arbeit …), dessen Adresse ansteuern – wie iOS (24.11.)
            val fav = AppState.favorites.items.value
                .minByOrNull { ChargePlanner.distance(it.lat, it.lng, spot.lat, spot.lng) }
                ?.takeIf { ChargePlanner.distance(it.lat, it.lng, spot.lat, spot.lng) < 300 }
            val id = fav?.let { "favorite-${it.id}" } ?: spot.id
            if (isDismissed(id)) return null
            val lat = fav?.lat ?: spot.lat
            val lng = fav?.lng ?: spot.lng
            val travel = Directions.duration(here.latitude, here.longitude, lat, lng) ?: return null
            return Suggestion(id, fav?.label ?: spot.name ?: tr("Häufiger Ort"), fav?.address, lat, lng, null, null, travel)
        }
        return null
    }

    fun calendarAllowed(c: Context) = ContextCompat.checkSelfPermission(c, Manifest.permission.READ_CALENDAR) == PackageManager.PERMISSION_GRANTED

    /** Termin mit Ort, zu dem man in spätestens 30 Minuten losfahren muss (Fahrzeit + 5 Min. Puffer) */
    private suspend fun calendar(lat: Double, lng: Double): Suggestion? {
        val c = AppState.appContextOrNull() ?: return null
        if (!calendarAllowed(c)) return null
        val now = System.currentTimeMillis()
        data class Event(val id: Long, val title: String, val location: String, val start: Long, val calendar: String)
        val events = withContext(Dispatchers.IO) {
            runCatching {
                val uri = CalendarContract.Instances.CONTENT_URI.buildUpon()
                    .appendPath((now - 10 * 60_000).toString()).appendPath((now + 6 * 3_600_000).toString()).build()
                c.contentResolver.query(uri, arrayOf(CalendarContract.Instances.EVENT_ID, CalendarContract.Instances.TITLE,
                    CalendarContract.Instances.EVENT_LOCATION, CalendarContract.Instances.BEGIN, CalendarContract.Instances.ALL_DAY,
                    CalendarContract.Instances.CALENDAR_DISPLAY_NAME),
                    // Nur gewählte Kalender (Standard: eingeblendete), keine abgelehnten oder offenen Einladungen (wie iOS)
                    "${CalendarContract.Instances.CALENDAR_ID} IN (${allCalendars(c).filter { isUsed(it) }.joinToString(",") { it.id.toString() }.ifEmpty { "-1" }})" +
                        " AND ${CalendarContract.Instances.SELF_ATTENDEE_STATUS} NOT IN " +
                        "(${CalendarContract.Attendees.ATTENDEE_STATUS_DECLINED}, ${CalendarContract.Attendees.ATTENDEE_STATUS_INVITED})",
                    null, CalendarContract.Instances.BEGIN + " ASC")?.use { cur ->
                    buildList {
                        while (cur.moveToNext()) {
                            if (cur.getInt(4) == 1) continue
                            val loc = cur.getString(2)?.trim().orEmpty()
                            if (loc.isEmpty()) continue
                            add(Event(cur.getLong(0), cur.getString(1).orEmpty(), loc, cur.getLong(3), cur.getString(5).orEmpty()))
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
            if (now + (travel * 1000).toLong() > e.start + 15 * 60_000) continue   // käme über 15 Min. zu spät – vorbei (wie iOS)
            val name = e.location.substringBefore("\n").substringBefore(",")
            de.koeven.meeterz.Diag.log("Termin-Vorschlag „${e.title}“ aus Kalender „${e.calendar}“")
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
