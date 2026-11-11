package de.koeven.meeterz.suggest

import de.koeven.meeterz.tr
import android.content.Context
import android.location.Location
import de.koeven.meeterz.AppState
import de.koeven.meeterz.Diag
import de.koeven.meeterz.data.VehicleStatus
import de.koeven.meeterz.ev.ChargePlanner
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

private val json = Json { ignoreUnknownKeys = true }
private fun prefs(): android.content.SharedPreferences? = AppState.appContextOrNull()?.getSharedPreferences("app", 0)

/** Zuletzt angefahrene Ziele (nur auf dem Gerät, je Konto getrennt) – wie RecentsStore.swift */
object Recents {
    @Serializable data class Entry(val name: String, val address: String? = null, val lat: Double, val lng: Double)
    private val _items = MutableStateFlow<List<Entry>>(emptyList())
    val items: StateFlow<List<Entry>> = _items
    private var userId: String? = null

    fun load(userId: String) {
        this.userId = userId
        _items.value = prefs()?.getString("recents.$userId", null)?.let { runCatching { json.decodeFromString<List<Entry>>(it) }.getOrNull() }.orEmpty()
    }

    fun reset() { _items.value = emptyList(); userId = null }

    /** Neustes Ziel nach oben; derselbe Ort (≈ 50 m) wird nicht doppelt geführt */
    fun record(name: String, address: String?, lat: Double, lng: Double) {
        val id = userId ?: return
        _items.value = (listOf(Entry(name, address, lat, lng)) + _items.value.filter { ChargePlanner.distance(it.lat, it.lng, lat, lng) >= 50 }).take(8)
        prefs()?.edit()?.putString("recents.$id", json.encodeToString(_items.value))?.apply()
    }
}

/**
 * Parkplatz merken (wie ParkingStore/ParkingDetector.swift): beim Trennen von Android Auto und wenn das Auto „geparkt“
 * meldet. Nur auf dem Gerät, Einstellung standardmäßig aus.
 */
object Parking {
    @Serializable data class Spot(val lat: Double, val lng: Double, val at: Long)
    private val _spot = MutableStateFlow<Spot?>(null)
    val spot: StateFlow<Spot?> = _spot
    private var wasParked: Boolean? = null

    var enabled: Boolean
        get() = prefs()?.getBoolean("parking.enabled", false) == true
        set(v) { prefs()?.edit()?.putBoolean("parking.enabled", v)?.apply(); if (!v) clear() }

    fun load() {
        _spot.value = if (!enabled) null else prefs()?.getString("parking.spot", null)?.let { runCatching { json.decodeFromString<Spot>(it) }.getOrNull() }
    }

    /** Nur speichern, wenn eingeschaltet und der Standort frisch und genau genug ist */
    fun save(loc: Location?, source: String) {
        if (!enabled || loc == null) return
        val now = System.currentTimeMillis()
        _spot.value?.let { if (now - it.at < 600_000 && ChargePlanner.distance(it.lat, it.lng, loc.latitude, loc.longitude) < 150 && source != tr("Auto")) return }
        if (now - loc.time > 5 * 60_000 || (loc.hasAccuracy() && loc.accuracy >= 100)) { Diag.log("Parkplatz nicht gemerkt: Standort zu alt oder ungenau"); return }
        _spot.value = Spot(loc.latitude, loc.longitude, now)
        prefs()?.edit()?.putString("parking.spot", json.encodeToString(_spot.value))?.apply()
        Diag.log("Parkplatz gemerkt ($source)")
    }

    fun clear() { _spot.value = null; prefs()?.edit()?.remove("parking.spot")?.apply() }

    /** Live-Daten vom Auto: Wechsel auf „geparkt“ mit Position */
    fun vehicleUpdate(status: VehicleStatus) {
        val parked = status.parked ?: return
        val before = wasParked
        wasParked = parked
        if (!enabled || !parked || before != false || status.ageSeconds > 15 * 60) return
        val lat = status.lat ?: return; val lng = status.lng ?: return
        Diag.log("Parken erkannt (Auto meldet „geparkt“)")
        save(Location("vehicle").apply { latitude = lat; longitude = lng; accuracy = 10f; time = status.measuredAt * 1000 }, tr("Auto"))
    }
}

/**
 * Selbst gelernte häufige Ziele (wie FrequentPlaces.swift): Aufenthalte werden zu Orten zusammengefasst, je Ort mit
 * den Ankunftszeiten. Android hat kein CLVisit – ein Aufenthalt ist hier: ≥ 5 Min. innerhalb von 150 m.
 * Alles bleibt auf dem Gerät.
 */
object FrequentPlaces {
    @Serializable data class Spot(val id: String, val lat: Double, val lng: Double, var name: String? = null, val arrivals: MutableList<Long> = mutableListOf())
    private const val RADIUS = 150.0
    private var spots: MutableList<Spot> = mutableListOf()
    private var loaded = false
    // Aufenthalt in Arbeit: erster Punkt und seit wann
    private var stayLat = 0.0; private var stayLng = 0.0; private var staySince = 0L; private var stayRecorded = false

    private fun file(c: Context) = java.io.File(c.filesDir, "frequent-places.json")

    private fun ensure() {
        if (loaded) return
        val c = AppState.appContextOrNull() ?: return
        loaded = true
        spots = runCatching { json.decodeFromString<MutableList<Spot>>(file(c).readText()) }.getOrDefault(mutableListOf())
    }

    private fun save() { val c = AppState.appContextOrNull() ?: return; runCatching { file(c).writeText(json.encodeToString(spots)) } }

    /** Jeder neue Standort */
    fun onLocation(loc: Location) {
        if (!RouteSuggestions.frequentEnabled || (loc.hasAccuracy() && loc.accuracy > 250)) return
        if (staySince == 0L || ChargePlanner.distance(stayLat, stayLng, loc.latitude, loc.longitude) > RADIUS) {
            stayLat = loc.latitude; stayLng = loc.longitude; staySince = loc.time; stayRecorded = false
            return
        }
        if (!stayRecorded && loc.time - staySince >= 5 * 60_000) {
            stayRecorded = true
            val (lat, lng, at) = Triple(stayLat, stayLng, staySince)
            AppState.scope.launch(Dispatchers.IO) { record(lat, lng, at) }   // Geocoder fragt im Netz nach
        }
    }

    private fun record(lat: Double, lng: Double, arrival: Long) {
        ensure()
        val existing = spots.firstOrNull { ChargePlanner.distance(it.lat, it.lng, lat, lng) < RADIUS }
        val spot = if (existing != null) {
            if (existing.arrivals.any { kotlin.math.abs(it - arrival) < 600_000 }) return
            existing.arrivals += arrival
            while (existing.arrivals.size > 80) existing.arrivals.removeAt(0)
            existing
        } else Spot(java.util.UUID.randomUUID().toString(), lat, lng, arrivals = mutableListOf(arrival)).also {
            spots += it
            if (spots.size > 150) { spots.sortByDescending { s -> s.arrivals.lastOrNull() ?: 0 }; spots = spots.take(150).toMutableList() }
        }
        if (spot.name == null) spot.name = name(lat, lng)
        Diag.log("Aufenthalt gemerkt: ${spot.name ?: "Ort"}")
        save()
    }

    /** Name: Favorit in der Nähe, sonst Ort aus dem Geocoder */
    private fun name(lat: Double, lng: Double): String? {
        AppState.favorites.items.value.firstOrNull { ChargePlanner.distance(it.lat, it.lng, lat, lng) < RADIUS }?.let { return it.label }
        val c = AppState.appContextOrNull() ?: return null
        @Suppress("DEPRECATION")
        val a = runCatching { android.location.Geocoder(c, java.util.Locale.GERMANY).getFromLocation(lat, lng, 1)?.firstOrNull() }.getOrNull() ?: return null
        return a.featureName?.takeIf { !it.matches(Regex("\\d+.*")) } ?: listOfNotNull(a.thoroughfare, a.subThoroughfare).joinToString(" ").ifEmpty { a.locality }
    }

    fun clear() { spots = mutableListOf(); loaded = true; save(); Diag.log("Gelernte Orte gelöscht") }

    /**
     * Wahrscheinlichstes Ziel jetzt: Ankünfte der letzten 8 Wochen im Fenster „jetzt -15 bis +90 Min.“, gleicher
     * Wochentag zählt voll, gleiche Art Tag (Werktag/Wochenende) halb. Mindestens 3 solche Ankünfte, Punkte ≥ 1,5.
     */
    fun likely(nowMillis: Long, lat: Double, lng: Double): Spot? {
        ensure()
        return likely(spots, nowMillis, lat, lng)
    }

    fun likely(spots: List<Spot>, nowMillis: Long, lat: Double, lng: Double): Spot? {
        fun cal(t: Long) = java.util.Calendar.getInstance().apply { timeInMillis = t }
        fun weekend(c: java.util.Calendar) = c.get(java.util.Calendar.DAY_OF_WEEK).let { it == java.util.Calendar.SATURDAY || it == java.util.Calendar.SUNDAY }
        fun minutes(c: java.util.Calendar) = c.get(java.util.Calendar.HOUR_OF_DAY) * 60 + c.get(java.util.Calendar.MINUTE)
        val now = cal(nowMillis)
        var best: Pair<Spot, Double>? = null
        for (spot in spots) {
            if (ChargePlanner.distance(spot.lat, spot.lng, lat, lng) <= 500) continue
            var score = 0.0; var count = 0
            for (arrival in spot.arrivals) {
                val age = nowMillis - arrival
                if (age <= 0 || age >= 56L * 86_400_000) continue
                val a = cal(arrival)
                var delta = minutes(a) - minutes(now)
                if (delta < -12 * 60) delta += 24 * 60
                if (delta < -15 || delta > 90) continue
                val sameDay = a.get(java.util.Calendar.DAY_OF_WEEK) == now.get(java.util.Calendar.DAY_OF_WEEK)
                if (!sameDay && weekend(a) != weekend(now)) continue
                score += (if (sameDay) 1.0 else 0.5) * Math.exp(-age / (30.0 * 86_400_000))
                count++
            }
            if (count >= 3 && score >= 1.5 && score > (best?.second ?: 0.0)) best = spot to score
        }
        return best?.first
    }
}
