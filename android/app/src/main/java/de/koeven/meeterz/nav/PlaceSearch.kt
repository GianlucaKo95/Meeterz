package de.koeven.meeterz.nav

import de.koeven.meeterz.tr
import com.mapbox.common.MapboxOptions
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.request.get
import io.ktor.client.request.parameter
import io.ktor.client.statement.bodyAsText
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
    data class Place(val name: String, val address: String?, val lat: Double, val lng: Double)

    private val http by lazy { HttpClient(OkHttp) }
    private val json = Json { ignoreUnknownKeys = true }

    /** Treffpunkt-Kategorien (wie SearchService.Category auf iOS) */
    enum class Category(val title: String, val path: String, val query: String? = null) {
        REST_AREA(tr("Raststätte"), "forward", tr("Raststätte")),
        COFFEE(tr("Café"), "category/coffee"),
        RESTAURANT(tr("Essen"), "category/restaurant"),
        GAS(tr("Tanken"), "category/gas_station"),
        PARK(tr("Park"), "category/park");

        companion object {
            /** Raststätte/Tankstelle nur, wenn alle mit dem Auto kommen; sonst Parks */
            fun available(allByCar: Boolean) = if (allByCar) listOf(REST_AREA, COFFEE, RESTAURANT, GAS) else listOf(COFFEE, RESTAURANT, PARK)
        }
    }

    suspend fun search(query: String, nearLat: Double?, nearLng: Double?): List<Place> {
        if (query.isBlank()) return emptyList()
        return request("forward", query, nearLat, nearLng, 8)
    }

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

    /** Mapbox-Treffer zum angetippten POI: gleicher Name in der Nähe (≤ 150 m). Ein Forward-Request, keine Session. */
    suspend fun details(name: String, lat: Double, lng: Double): Details? = runCatching {
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
                days[od % 7] += ot until maxOf(end, ot + 1)
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

    private fun distance(a: Double, b: Double, c: Double, d: Double) = de.koeven.meeterz.ev.ChargePlanner.distance(a, b, c, d)

    private suspend fun request(path: String, query: String?, nearLat: Double?, nearLng: Double?, limit: Int): List<Place> {
        return runCatching {
            val body = http.get("https://api.mapbox.com/search/searchbox/v1/$path") {
                if (query != null) parameter("q", query)
                parameter("language", "de")
                parameter("limit", limit)
                if (nearLat != null && nearLng != null) parameter("proximity", "$nearLng,$nearLat")
                parameter("access_token", MapboxOptions.accessToken)
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
