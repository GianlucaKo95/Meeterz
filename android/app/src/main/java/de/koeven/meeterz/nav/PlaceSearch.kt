package de.koeven.meeterz.nav

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

    suspend fun search(query: String, nearLat: Double?, nearLng: Double?): List<Place> {
        if (query.isBlank()) return emptyList()
        return runCatching {
            val body = http.get("https://api.mapbox.com/search/searchbox/v1/forward") {
                parameter("q", query)
                parameter("language", "de")
                parameter("limit", 8)
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
