package de.koeven.meeterz.data

import android.widget.Toast
import com.mapbox.navigation.base.trip.model.RouteProgress
import de.koeven.meeterz.AppState
import de.koeven.meeterz.Diag
import de.koeven.meeterz.ev.ChargePlanner
import de.koeven.meeterz.nav.IncidentWatcher
import de.koeven.meeterz.nav.NavigationController
import de.koeven.meeterz.tr
import io.github.jan.supabase.functions.functions
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import io.ktor.client.statement.bodyAsText
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.addJsonObject

private suspend fun toast(text: String) = withContext(Dispatchers.Main) {
    AppState.appContextOrNull()?.let { Toast.makeText(it, text, Toast.LENGTH_SHORT).show() }
}

// ─── Spritpreise ─────────────────────────────────────────────

/** Spritpreise der Markttransparenzstelle über Tankerkönig (wie FuelPrices.swift): Edge Function „fuel-prices“, 5 Min. Cache je Ort */
object FuelPrices {
    @Serializable
    data class Price(val e5: Double? = null, val e10: Double? = null, val diesel: Double? = null, val open: Boolean? = null, val brand: String? = null) {
        val text: String get() = listOf("E5" to e5, "E10" to e10, "Diesel" to diesel)
            .mapNotNull { (n, v) -> v?.let { "$n " + String.format(java.util.Locale.getDefault(), "%.3f", it) } }.joinToString(" · ")
    }
    @Serializable private data class Response(val prices: List<Price?> = emptyList())

    const val ATTRIBUTION = "Preise: MTS-K via Tankerkönig"
    private val json = Json { ignoreUnknownKeys = true }
    private val cache = mutableMapOf<String, Pair<Long, Price?>>()
    private fun key(lat: Double, lng: Double) = String.format(java.util.Locale.US, "%.4f,%.4f", lat, lng)

    fun isGasStation(category: String?, name: String): Boolean {
        val s = "${category.orEmpty()} $name".lowercase()
        return listOf("tankstelle", "gas station", "fuel", "gas_station", "aral", "shell", "esso", "jet ", "total").any { it in s }
    }

    /** Preise je Ort in derselben Reihenfolge (null = unbekannt) */
    suspend fun prices(points: List<Pair<Double, Double>>): List<Price?> {
        val now = System.currentTimeMillis()
        val missing = points.filter { (a, b) -> cache[key(a, b)]?.let { now - it.first > 300_000 } ?: true }.take(10)
        if (missing.isNotEmpty()) runCatching {
            val body = Backend.client.functions.invoke("fuel-prices", buildJsonObject {
                putJsonArray("points") { missing.forEach { (a, b) -> addJsonObject { put("lat", a); put("lng", b) } } }
            }).bodyAsText()
            json.decodeFromString<Response>(body).prices.zip(missing).forEach { (p, pt) -> cache[key(pt.first, pt.second)] = now to p }
        }.onFailure { Diag.log("Spritpreise: ${it.message}") }
        return points.map { (a, b) -> cache[key(a, b)]?.second }
    }
}

// ─── Gefahren melden ─────────────────────────────────────────

/** Von Meeterz-Fahrern gemeldete Gefahren (wie HazardStore.swift): eine Stunde gültig, auf der Route voraus angesagt */
object HazardStore {
    enum class Kind(val key: String, val title: String) {
        ACCIDENT("accident", tr("Unfall")), JAM("jam", tr("Stau")), OBJECT("object", tr("Gegenstand auf der Fahrbahn")),
        BREAKDOWN("breakdown", tr("Pannenfahrzeug")), ICE("ice", tr("Glätte"));
    }

    @Serializable
    data class Hazard(val id: String, val kind: String, val lat: Double, val lng: Double, val heading: Double? = null,
                      @SerialName("by_friend") val byFriend: Boolean = false)

    /** Meldung an den Konvoi (Live-Kanal, Ereignis „hazard“; wie iOS HazardStore.Shared). Feldnamen nur gemeinsam ändern. */
    @Serializable
    data class Shared(val id: String, val from: String, val kind: String, val lat: Double, val lng: Double, val heading: Double? = null)

    private var items = emptyList<Hazard>()
    private var loadedAt = 0L
    private var loading = false
    private val announced = mutableSetOf<String>()
    /** Letzter Fortschritt der Navigation – um eine Konvoi-Meldung sofort einzuordnen */
    private var lastProgress: RouteProgress? = null

    fun reset() { items = emptyList(); loadedAt = 0; lastCheck = 0; announced.clear(); lastProgress = null }

    suspend fun report(kind: Kind) {
        val loc = AppState.lastLocation ?: run { toast(tr("Standort unbekannt")); return }
        val heading = if (loc.hasBearing()) loc.bearing.toDouble() else null
        runCatching {
            Backend.client.postgrest.rpc("report_hazard", buildJsonObject {
                put("kind", kind.key); put("lat", loc.latitude); put("lng", loc.longitude); put("heading", heading)
            }).decodeAs<String>()
        }.onSuccess { id ->
            Diag.log("Gefahr gemeldet: ${kind.key}")
            // Im Konvoi sofort an die anderen – wer noch daran vorbei muss, wird gleich gewarnt (wie iOS)
            val me = AppState.myId
            if (me != null && de.koeven.meeterz.social.Convoy.members().isNotEmpty()) {
                AppState.hub.broadcast("hazard", Json.encodeToJsonElement(Shared.serializer(),
                    Shared(id, me.lowercase(), kind.key, loc.latitude, loc.longitude, heading)).let { it as kotlinx.serialization.json.JsonObject })
            }
            toast(tr("Danke! %@ gemeldet.", kind.title))
        }.onFailure {
            Diag.log("Gefahr melden fehlgeschlagen: ${it.message}")
            toast(tr("Meldung nicht möglich – höchstens eine pro Minute."))
        }
    }

    /** Je Fortschritt der Navigation: Meldungen auf der Route voraus ansagen, einmal je Meldung */
    private var lastCheck = 0L

    fun check(progress: RouteProgress) {
        lastProgress = progress
        if (System.currentTimeMillis() - lastCheck < 5_000) return   // wie iOS: alle 5 s genügt
        lastCheck = System.currentTimeMillis()
        val coords = coords(progress) ?: return
        if (System.currentTimeMillis() - loadedAt > 300_000 && !loading) {
            loading = true
            CoroutineScope(Dispatchers.IO).launch { load(coords); loading = false }
        }
        for (h in items) {
            if (h.id in announced) continue
            val kind = Kind.entries.firstOrNull { it.key == h.kind } ?: continue
            val ahead = ahead(h, coords, progress) ?: continue
            if (ahead <= 150 || ahead >= 2_000) { if (ahead <= 150) announced += h.id; continue }
            announced += h.id
            IncidentWatcher.announceReported(kind.title, if (h.byFriend) tr("von einem Freund gemeldet") else tr("von Meeterz-Fahrern gemeldet"), ahead)
            return
        }
    }

    private fun coords(progress: RouteProgress) = progress.navigationRoute.directionsRoute.geometry()
        ?.let { com.mapbox.geojson.LineString.fromPolyline(it, 6).coordinates() }?.takeIf { it.size > 1 }

    /** Strecke bis zur Meldung auf der eigenen Route; null = nicht auf der Route oder Gegenrichtung. Negativ = vorbei. */
    private fun ahead(h: Hazard, coords: List<com.mapbox.geojson.Point>, progress: RouteProgress): Double? {
        val i = coords.indices.minBy { ChargePlanner.distance(coords[it].latitude(), coords[it].longitude(), h.lat, h.lng) }
        // ponytail: Abstand zum nächsten Routenpunkt statt zur Strecke – Punkte liegen in Polyline6 dicht genug
        if (ChargePlanner.distance(coords[i].latitude(), coords[i].longitude(), h.lat, h.lng) > 60) return null
        // Gegenrichtung? Fahrtrichtung der Meldung mit der Richtung der Route vergleichen
        if (h.heading != null && i + 1 < coords.size) {
            val bearing = com.mapbox.turf.TurfMeasurement.bearing(coords[i], coords[i + 1])
            if (Math.abs(((bearing - h.heading + 540) % 360) - 180) > 60) return null
        }
        var along = 0.0
        for (j in 0 until i) along += ChargePlanner.distance(coords[j].latitude(), coords[j].longitude(), coords[j + 1].latitude(), coords[j + 1].longitude())
        return along - progress.distanceTraveled.toDouble()
    }

    /**
     * Meldung eines Mitfahrenden aus dem Live-Kanal (wie iOS): liegt sie auf meiner Route noch vor mir, sofort
     * Bescheid sagen („Unfall in 3,2 km – Luca hat es eben gemeldet“); bei 2 km kommt die übliche Warnung noch einmal.
     */
    fun received(shared: Shared) {
        if (NavigationController.guidance.value == null || items.any { it.id == shared.id }) return
        val h = Hazard(shared.id, shared.kind, shared.lat, shared.lng, shared.heading, byFriend = true)
        items = items + h
        val kind = Kind.entries.firstOrNull { it.key == h.kind } ?: return
        val progress = lastProgress ?: return
        val ahead = coords(progress)?.let { ahead(h, it, progress) }?.takeIf { it > 150 } ?: return
        val name = AppState.friends.value.firstOrNull { it.friendId.equals(shared.from, true) }?.displayName ?: tr("Ein Mitfahrer")
        Diag.log("Konvoi-Gefahr von $name: ${shared.kind} in ${ahead.toInt()} m")
        IncidentWatcher.announceReported(kind.title, tr("%@ hat es eben gemeldet", name), ahead)
        if (ahead < 2_000) announced += h.id
    }

    private suspend fun load(coords: List<com.mapbox.geojson.Point>) {
        val pad = 0.01
        runCatching {
            Backend.client.postgrest.rpc("hazards_in", buildJsonObject {
                put("min_lat", coords.minOf { it.latitude() } - pad); put("min_lng", coords.minOf { it.longitude() } - pad)
                put("max_lat", coords.maxOf { it.latitude() } + pad); put("max_lng", coords.maxOf { it.longitude() } + pad)
            }).decodeList<Hazard>()
        }.onSuccess { rows ->
            // Live erhaltene Konvoi-Meldungen behalten, bis sie auch geladen sind
            items = rows + items.filter { h -> h.byFriend && rows.none { it.id == h.id } }
            loadedAt = System.currentTimeMillis()
        }
    }
}

// ─── Gespeicherte Listen ─────────────────────────────────────

/** Eigene Ortslisten, optional mit Freunden geteilt (wie PlaceListsStore.swift). Geladen nur beim Öffnen. */
object PlaceLists {
    @Serializable
    data class Item(val id: String, @SerialName("list_id") val listId: String, val name: String, val address: String? = null,
                    val lat: Double, val lng: Double)

    @Serializable
    data class PlaceList(val id: String, val owner: String, val name: String, val shared: Boolean = false,
                         @SerialName("place_list_items") val items: List<Item> = emptyList())

    private val _lists = MutableStateFlow<List<PlaceList>>(emptyList())
    val lists: StateFlow<List<PlaceList>> = _lists
    var loaded = false; private set

    suspend fun refresh() {
        runCatching {
            Backend.client.from("place_lists").select(Columns.raw("id, owner, name, shared, place_list_items(id, list_id, name, address, lat, lng)")) {
                order("created_at", Order.ASCENDING)
            }.decodeList<PlaceList>()
        }.onSuccess { _lists.value = it; loaded = true }
            .onFailure { Diag.log("Listen laden: ${it.message}") }
    }

    suspend fun create(name: String, shared: Boolean): PlaceList? = runCatching {
        Backend.client.from("place_lists").insert(buildJsonObject { put("name", name); put("shared", shared) }) { select() }.decodeSingle<PlaceList>()
    }.getOrNull()?.also { _lists.value = _lists.value + it }

    suspend fun add(name: String, address: String?, lat: Double, lng: Double, list: PlaceList) {
        runCatching {
            Backend.client.from("place_list_items").insert(buildJsonObject {
                put("list_id", list.id); put("name", name); put("address", address); put("lat", lat); put("lng", lng)
            })
        }.onSuccess { toast(tr("In „%@“ gespeichert.", list.name)); refresh() }
            .onFailure { toast(tr("Speichern fehlgeschlagen.")) }
    }

    suspend fun remove(item: Item) {
        runCatching { Backend.client.from("place_list_items").delete { filter { eq("id", item.id) } } }
        refresh()
    }

    suspend fun delete(list: PlaceList) {
        runCatching { Backend.client.from("place_lists").delete { filter { eq("id", list.id) } } }
        _lists.value = _lists.value.filter { it.id != list.id }
    }

    suspend fun setShared(list: PlaceList, shared: Boolean) {
        runCatching { Backend.client.from("place_lists").update(buildJsonObject { put("shared", shared) }) { filter { eq("id", list.id) } } }
        refresh()
    }
}
