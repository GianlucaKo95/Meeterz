package de.koeven.meeterz.data

import de.koeven.meeterz.tr
import com.mapbox.common.MapboxOptions
import de.koeven.meeterz.ev.ChargePlanner
import de.koeven.meeterz.nav.PlaceSearch
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.request.get
import io.ktor.client.statement.bodyAsText
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Fairer Treffpunkt für eine Gruppe (wie FairMeetupFinder.swift): Orte rund um die Mitte aller Teilnehmer suchen,
 * mit der Mapbox Matrix API die Fahrzeit jedes Teilnehmers holen und nach der längsten Anfahrt sortieren.
 */
object FairMeetupFinder {
    data class Participant(val id: String, val name: String, val lat: Double, val lng: Double)
    data class Option(val place: PlaceSearch.Place, val durations: Map<String, Double>) {
        val longest get() = durations.values.maxOrNull() ?: 0.0
        val spread get() = longest - (durations.values.minOrNull() ?: 0.0)
    }
    class FinderException(message: String) : Exception(message)

    private val http by lazy { HttpClient(OkHttp) }

    suspend fun find(people: List<Participant>): List<Option> {
        if (people.size < 2) throw FinderException(tr("Wähle mindestens einen Freund mit sichtbarem Standort."))
        val lat = people.map { it.lat }.average()
        val lng = people.map { it.lng }.average()
        val candidates = mutableListOf<PlaceSearch.Place>()
        for (c in listOf(PlaceSearch.Category.COFFEE, PlaceSearch.Category.RESTAURANT, PlaceSearch.Category.REST_AREA)) {
            for (p in PlaceSearch.places(c, lat, lng, 4)) {
                if (candidates.none { ChargePlanner.distance(it.lat, it.lng, p.lat, p.lng) < 40 }) candidates += p
            }
        }
        val near = candidates.sortedBy { ChargePlanner.distance(it.lat, it.lng, lat, lng) }.take(10)
        if (near.isEmpty()) throw FinderException(tr("In der Mitte wurde kein passender Ort gefunden."))
        val matrix = matrix(people, near)
        val options = near.mapIndexedNotNull { j, place ->
            val per = people.mapIndexed { i, p -> p.id to (matrix.getOrNull(i)?.getOrNull(j) ?: return@mapIndexedNotNull null) }.toMap()
            Option(place, per)
        }
        if (options.isEmpty()) throw FinderException(tr("In der Mitte wurde kein passender Ort gefunden."))
        return options.sortedWith(compareBy({ it.longest }, { it.spread })).take(3)
    }

    /** Zeilen = Teilnehmer, Spalten = Orte (Sekunden, null = nicht erreichbar) */
    private suspend fun matrix(people: List<Participant>, places: List<PlaceSearch.Place>): List<List<Double?>> {
        val coords = (people.map { "${it.lng},${it.lat}" } + places.map { "${it.lng},${it.lat}" }).joinToString(";")
        val sources = people.indices.joinToString(";")
        val destinations = (people.size until people.size + places.size).joinToString(";")
        val body = runCatching {
            http.get("https://api.mapbox.com/directions-matrix/v1/mapbox/driving/$coords?sources=$sources&destinations=$destinations" +
                "&annotations=duration&access_token=${MapboxOptions.accessToken}").bodyAsText()
        }.getOrNull() ?: throw FinderException(tr("Die Fahrzeiten konnten gerade nicht berechnet werden."))
        val rows = Json.parseToJsonElement(body).jsonObject["durations"]?.jsonArray
            ?: throw FinderException(tr("Die Fahrzeiten konnten gerade nicht berechnet werden."))
        return rows.map { row -> row.jsonArray.map { if (it is JsonNull) null else it.jsonPrimitive.doubleOrNull } }
    }
}
