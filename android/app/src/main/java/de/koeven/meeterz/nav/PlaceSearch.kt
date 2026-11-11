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
import kotlinx.serialization.json.double
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
