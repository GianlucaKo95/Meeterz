package de.koeven.meeterz.nav

import de.koeven.meeterz.tr
import com.mapbox.common.MapboxOptions
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.request.get
import io.ktor.client.request.parameter
import io.ktor.client.statement.bodyAsText
import kotlinx.coroutines.async
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.double
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** Orte und Adressen suchen (iOS: MKLocalSearch) – hier über Mapbox' Search Box API */
object PlaceSearch {
    /** `hours`: Öffnungszeiten je Tag (0 = Montag), falls bekannt (OpenStreetMap, für Listen im Auto) */
    data class Place(val name: String, val address: String?, val lat: Double, val lng: Double,
                     val hours: List<List<IntRange>>? = null)

    /** Öffnungszeiten aus OpenStreetMap an die Orte hängen – eine Abfrage für die ganze Liste */
    suspend fun withHours(places: List<Place>): List<Place> {
        val hours = OsmPlaces.hours(places)
        return places.mapIndexed { i, p -> hours[i]?.let { p.copy(hours = it) } ?: p }
    }

    private val http by lazy { HttpClient(OkHttp) }
    private val json = Json { ignoreUnknownKeys = true }

    /** Treffpunkt-Kategorien (wie SearchService.Category auf iOS) */
    enum class Category(val title: String, val path: String, val query: String? = null) {
        REST_AREA(tr("Raststätte"), "forward", tr("Raststätte")),
        COFFEE(tr("Café"), "category/coffee"),
        RESTAURANT(tr("Essen"), "category/restaurant"),
        GAS(tr("Tanken"), "category/gas_station"),
        PARK(tr("Park"), "category/park"),
        CHARGING(tr("Laden"), "category/charging_station"),
        PARKING(tr("Parken"), "category/parking_lot");

        companion object {
            /** Raststätte/Tankstelle nur, wenn alle mit dem Auto kommen; sonst Parks */
            /** Für unterwegs (wie SearchService.Stopover auf iOS) */
            val stopovers = listOf(GAS, CHARGING, PARKING, RESTAURANT, COFFEE)
            fun available(allByCar: Boolean) = if (allByCar) listOf(REST_AREA, COFFEE, RESTAURANT, GAS) else listOf(COFFEE, RESTAURANT, PARK)
        }
    }

    /**
     * Ortssuche: Mapbox und der Geocoder des Geräts gleichzeitig, zusammengeführt und nach Passung und Nähe sortiert
     * (wie iOS mit Apple-Orten). Nur Mapbox lieferte ab und an völlig falsche Treffer (unscharfe Suche, 22.11.).
     */
    suspend fun search(query: String, nearLat: Double?, nearLng: Double?): List<Place> = kotlinx.coroutines.coroutineScope {
        if (query.isBlank()) return@coroutineScope emptyList()
        val device = async(kotlinx.coroutines.Dispatchers.IO) { geocoder(query, nearLat, nearLng) }
        val mapbox = request("forward", query, nearLat, nearLng, 10)
        SearchRanking.merge(device.await(), mapbox, query, nearLat, nearLng)
    }

    @Suppress("DEPRECATION")
    private fun geocoder(query: String, lat: Double?, lng: Double?): List<Place> = runCatching {
        val context = de.koeven.meeterz.AppState.appContextOrNull() ?: return emptyList()
        if (!android.location.Geocoder.isPresent()) return emptyList()
        val g = android.location.Geocoder(context, java.util.Locale.getDefault())
        val found = if (lat != null && lng != null) g.getFromLocationName(query, 8, lat - 0.5, lng - 0.8, lat + 0.5, lng + 0.8)
                    else g.getFromLocationName(query, 8)
        found.orEmpty().mapNotNull { a ->
            val line = a.getAddressLine(0)
            val name = a.featureName?.takeIf { it != a.subThoroughfare && it.any(Char::isLetter) }
                ?: listOfNotNull(a.thoroughfare, a.subThoroughfare).joinToString(" ").ifBlank { null } ?: a.locality ?: return@mapNotNull null
            Place(name, line, a.latitude, a.longitude)
        }
    }.getOrDefault(emptyList())

    suspend fun places(category: Category, nearLat: Double, nearLng: Double, limit: Int = 6): List<Place> {
        val found = request(category.path, category.query, nearLat, nearLng, limit)
        return if (category == Category.REST_AREA) found.filter { distance(it.lat, it.lng, nearLat, nearLng) < 8_000 } else found
    }

    /** Details eines Karten-POI (Ortskarte wie Apples): Kategorie, Telefon, Website, Bewertung, Öffnungszeiten */
    data class Details(
        val category: String?, val address: String?, val phone: String?, val website: String?,
        val rating: Double?, val reviews: Int?,
        /** Öffnungszeiten je Tag (0 = Montag … 6 = Sonntag) als Minuten-Spannen; null = unbekannt */
        val hours: List<List<IntRange>>?,
        /** OSM-Öffnungszeiten, die sich nicht in Spannen übersetzen ließen – dann als Text zeigen */
        val hoursText: String? = null,
        /** Angaben (auch) aus OpenStreetMap – Hinweis „© OpenStreetMap“ zeigen */
        val osm: Boolean = false,
    ) {
        /** true/false = jetzt geöffnet/geschlossen, null = unbekannt */
        fun openNow(now: java.util.Calendar = java.util.Calendar.getInstance()): Boolean? {
            val h = hours ?: return null
            val day = (now.get(java.util.Calendar.DAY_OF_WEEK) + 5) % 7
            val min = now.get(java.util.Calendar.HOUR_OF_DAY) * 60 + now.get(java.util.Calendar.MINUTE)
            // Spannen über Mitternacht sind am Folgetag als > 1440 eingetragen
            return h[day].any { min in it } || h[(day + 6) % 7].any { min + 1440 in it }
        }
    }

    /**
     * Details zum angetippten POI: Mapbox, und was dort fehlt (Website, Telefon, Öffnungszeiten), aus OpenStreetMap.
     * Mapbox hat in Deutschland zu vielen kleineren Orten nur Name und Adresse (18.11., z. B. Restaurant in Duisburg).
     */
    suspend fun details(name: String, lat: Double, lng: Double): Details? = kotlinx.coroutines.coroutineScope {
        val mapbox = async { mapboxDetails(name, lat, lng) }
        val osm = async { OsmPlaces.info(name, lat, lng) }
        val m = mapbox.await(); val o = osm.await()
        if (o == null) return@coroutineScope m
        val osmHours = o.openingHours?.let { OsmPlaces.parse(it) }
        val base = m ?: Details(null, null, null, null, null, null, null)
        val merged = base.copy(
            phone = base.phone ?: o.phone, website = base.website ?: o.website,
            hours = base.hours ?: osmHours,
            hoursText = if (base.hours == null && osmHours == null) o.openingHours else null,
        )
        merged.copy(osm = merged != base)
    }

    /**
     * Wie [details], aber bei einem Termin, dessen Ort nur eine Adresse ist („Friedrichstraße 2“), zuerst nach dem
     * Termintitel dort suchen („Reformer Balance“) – das ist meist das Geschäft (wie iOS, 22.11.).
     */
    suspend fun detailsForDestination(name: String, lat: Double, lng: Double): Details? {
        val s = de.koeven.meeterz.suggest.RouteSuggestions.current.value
        val title = s?.calendarTitle?.takeIf { it.isNotBlank() && distance(s.lat, s.lng, lat, lng) < 150 }
        val byTitle = title?.let { details(it, lat, lng) }
        if (byTitle != null && (byTitle.hours != null || byTitle.hoursText != null || byTitle.phone != null)) return byTitle
        return details(name, lat, lng) ?: byTitle
    }

    /** Mapbox-Treffer zum angetippten POI: gleicher Name in der Nähe (≤ 150 m). Ein Forward-Request, keine Session. */
    private suspend fun mapboxDetails(name: String, lat: Double, lng: Double): Details? = runCatching {
        val body = http.get("https://api.mapbox.com/search/searchbox/v1/forward") {
            parameter("q", name); parameter("language", "de"); parameter("limit", 5); parameter("types", "poi")
            parameter("proximity", "$lng,$lat"); parameter("access_token", MapboxOptions.accessToken)
        }.bodyAsText()
        val props = json.parseToJsonElement(body).jsonObject["features"]?.jsonArray.orEmpty()
            .mapNotNull { it.jsonObject["properties"] as? JsonObject }
            .mapNotNull { p ->
                val c = p["coordinates"] as? JsonObject ?: return@mapNotNull null
                val d = distance(lat, lng, c["latitude"]!!.jsonPrimitive.double, c["longitude"]!!.jsonPrimitive.double)
                if (d < 150) p to d else null
            }.minByOrNull { it.second }?.first ?: return@runCatching null
        val meta = props["metadata"] as? JsonObject
        fun str(o: JsonObject?, k: String) = o?.get(k)?.jsonPrimitive?.contentOrNull?.takeIf { it.isNotBlank() }
        val periods = (meta?.get("open_hours") as? JsonObject)?.get("periods")?.jsonArray
        if (periods != null) de.koeven.meeterz.Diag.log("POI-Öffnungszeiten $name: $periods")
        val hours = periods?.let { list ->
            val days = List(7) { mutableListOf<IntRange>() }
            for (e in list) {
                val o = e.jsonObject["open"] as? JsonObject ?: continue
                val c = e.jsonObject["close"] as? JsonObject
                val od = o["day"]!!.jsonPrimitive.int; val ot = minutes(o["time"]!!.jsonPrimitive.content)
                // ohne „close“ = rund um die Uhr
                val end = c?.let { ((it["day"]!!.jsonPrimitive.int - od + 7) % 7) * 1440 + minutes(it["time"]!!.jsonPrimitive.content) } ?: 1440
                // Mapbox zählt ab Sonntag (0 = So), wir ab Montag (wie iOS)
                days[(od + 6) % 7] += ot until maxOf(end, ot + 1)
            }
            days
        }
        Details(
            category = (props["poi_category"] as? kotlinx.serialization.json.JsonArray)?.firstOrNull()?.jsonPrimitive?.contentOrNull
                ?.replaceFirstChar { it.uppercase() },
            address = str(props, "full_address") ?: str(props, "address"),
            phone = str(meta, "phone"), website = str(meta, "website"),
            rating = meta?.get("rating")?.jsonPrimitive?.doubleOrNull, reviews = meta?.get("review_count")?.jsonPrimitive?.intOrNull,
            hours = hours,
        )
    }.onFailure { de.koeven.meeterz.Diag.log("POI-Details: ${it.message}") }.getOrNull()

    private fun minutes(hhmm: String) = hhmm.take(2).toInt() * 60 + hhmm.drop(2).toInt()

    /** Ort für einen Zwischenstopp: `ahead` = Strecke entlang der Route (nur während der Fahrt), `price` = Spritpreise */
    data class Stopover(val place: Place, val ahead: Double?, val price: de.koeven.meeterz.data.FuelPrices.Price? = null) {
        /** „nach 12 km“, unter 200 m „Direkt hier“ (statt „nach 0 m“) */
        val aheadText: String? get() = ahead?.let { if (it < 200) tr("Direkt hier") else tr("nach %@", de.koeven.meeterz.ui.km(it)) }
    }

    /** Wie weit voraus gesucht wird (wie iOS): Treffer in 400 km nützen beim Tanken nichts */
    private const val HORIZON = 80_000.0

    /**
     * Orte einer Kategorie für unterwegs (wie NavigationCoordinator.stopovers auf iOS): während der Fahrt entlang der
     * restlichen Route (Mapbox „Search along route“, höchstens 5 Min. Umweg) in Reihenfolge auf der Strecke, sonst in der Nähe.
     */
    suspend fun stopovers(category: Category, lat: Double, lng: Double): List<Stopover> {
        val full = NavigationController.routeAhead(lat, lng)
        // Nur die nächsten 80 km; findet sich dort nichts, die ganze restliche Strecke
        return stopovers(category, lat, lng, full?.let { cut(it, HORIZON) }).ifEmpty {
            if (full != null) stopovers(category, lat, lng, full) else emptyList()
        }
    }

    private fun cut(route: List<com.mapbox.geojson.Point>, meters: Double): List<com.mapbox.geojson.Point> {
        var sum = 0.0
        for (i in 1 until route.size) {
            sum += distance(route[i - 1].latitude(), route[i - 1].longitude(), route[i].latitude(), route[i].longitude())
            if (sum > meters) return route.subList(0, maxOf(2, i))
        }
        return route
    }

    private suspend fun stopovers(category: Category, lat: Double, lng: Double, ahead: List<com.mapbox.geojson.Point>?): List<Stopover> {
        val along = ahead?.let { r -> r.indices.runningFold(0.0) { acc, i -> if (i == 0) acc else acc + distance(r[i - 1].latitude(), r[i - 1].longitude(), r[i].latitude(), r[i].longitude()) }.drop(1) }
        var found = request(category.path, category.query, lat, lng, 10) {
            if (ahead != null && category.path.startsWith("category/")) {
                parameter("sar_type", "isochrone")
                parameter("route", com.mapbox.geojson.utils.PolylineUtils.encode(ahead, 5))
                parameter("route_geometry", "polyline")
                parameter("time_deviation", 5)
            }
        }
        if (found.isEmpty()) found = search(category.title, lat, lng)   // unbekannte Kategorie o. Ä.
        var result = if (ahead != null && along != null) {
            found.mapNotNull { p ->
                val i = ahead.indices.minBy { distance(ahead[it].latitude(), ahead[it].longitude(), p.lat, p.lng) }
                if (distance(ahead[i].latitude(), ahead[i].longitude(), p.lat, p.lng) < 3_000) Triple(p, along[i], i) else null
            }.sortedBy { it.third }.map { Stopover(it.first, it.second) }
        } else found.sortedBy { distance(it.lat, it.lng, lat, lng) }.map { Stopover(it, null) }
        if (category == Category.GAS) {
            val prices = de.koeven.meeterz.data.FuelPrices.prices(result.take(10).map { it.place.lat to it.place.lng })
            result = result.mapIndexed { i, s -> if (i < prices.size) s.copy(price = prices[i]) else s }
        }
        return result
    }

    private fun distance(a: Double, b: Double, c: Double, d: Double) = de.koeven.meeterz.ev.ChargePlanner.distance(a, b, c, d)

    /** Geschäft, Fitnessstudio … direkt am Punkt (≤ 80 m), für gelernte Orte (wie iOS MKLocalPointsOfInterestRequest) */
    suspend fun poiNear(lat: Double, lng: Double): Place? =
        request("reverse", null, null, null, 5) { parameter("longitude", lng); parameter("latitude", lat); parameter("types", "poi") }
            .filter { distance(lat, lng, it.lat, it.lng) <= 80 }
            .minByOrNull { distance(lat, lng, it.lat, it.lng) }

    private suspend fun request(path: String, query: String?, nearLat: Double?, nearLng: Double?, limit: Int,
                                extra: io.ktor.client.request.HttpRequestBuilder.() -> Unit = {}): List<Place> {
        return runCatching {
            val body = http.get("https://api.mapbox.com/search/searchbox/v1/$path") {
                if (query != null) parameter("q", query)
                parameter("language", java.util.Locale.getDefault().language)   // wie iOS: Sprache der App
                parameter("limit", limit)
                if (nearLat != null && nearLng != null) parameter("proximity", "$nearLng,$nearLat")
                parameter("access_token", MapboxOptions.accessToken)
                extra()
            }.bodyAsText()
            json.parseToJsonElement(body).jsonObject["features"]?.jsonArray.orEmpty().mapNotNull { f ->
                val props = f.jsonObject["properties"] as? JsonObject ?: return@mapNotNull null
                val coords = props["coordinates"] as? JsonObject ?: return@mapNotNull null
                Place(
                    name = props["name"]?.jsonPrimitive?.content ?: return@mapNotNull null,
                    address = (props["full_address"] ?: props["place_formatted"])?.jsonPrimitive?.content,
                    lat = coords["latitude"]?.jsonPrimitive?.double ?: return@mapNotNull null,
                    lng = coords["longitude"]?.jsonPrimitive?.double ?: return@mapNotNull null,
                )
            }
        }.getOrDefault(emptyList())
    }
}

/** Treffer zusammenführen und sortieren (wie iOS SearchRanking) */
object SearchRanking {
    private fun fold(s: String) = java.text.Normalizer.normalize(s.lowercase(), java.text.Normalizer.Form.NFD).replace(Regex("\\p{M}"), "")
    private fun words(s: String) = s.split(Regex("[^\\p{L}\\p{N}]+")).filter { it.isNotEmpty() }

    /** Wie gut passt der Treffer zur Eingabe? 0 = gar nicht (kein Wort der Eingabe kommt in Name/Adresse vor) */
    fun match(name: String, address: String?, query: String): Double {
        val n = fold(name); val q = fold(query).trim()
        val ws = words(q)
        if (ws.isEmpty()) return 0.0
        if (n == q) return 3.0
        if (n.startsWith(q)) return 2.5
        if (n.contains(q)) return 2.0
        val tokens = words(n + " " + fold(address ?: ""))
        val hits = ws.count { w -> tokens.any { it.startsWith(w) } }
        return if (hits == 0) 0.0 else hits.toDouble() / ws.size * 1.5
    }

    fun merge(device: List<PlaceSearch.Place>, mapbox: List<PlaceSearch.Place>, query: String, lat: Double?, lng: Double?): List<PlaceSearch.Place> {
        val out = mutableListOf<PlaceSearch.Place>()
        for (p in device + mapbox) {
            if (out.any { de.koeven.meeterz.ev.ChargePlanner.distance(it.lat, it.lng, p.lat, p.lng) < 150 && match(it.name, null, p.name) >= 2 }) continue
            out += p
        }
        fun score(p: PlaceSearch.Place): Double {
            val m = match(p.name, p.address, query)
            if (lat == null || lng == null) return m
            val km = de.koeven.meeterz.ev.ChargePlanner.distance(p.lat, p.lng, lat, lng) / 1000
            return m - kotlin.math.log10(1 + km) * 0.6
        }
        val anyMatch = out.any { match(it.name, it.address, query) > 0 }
        return out.filter { !anyMatch || match(it.name, it.address, query) > 0 }.sortedByDescending { score(it) }.take(10)
    }
}
