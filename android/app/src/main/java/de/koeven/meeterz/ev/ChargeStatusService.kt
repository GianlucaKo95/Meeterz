package de.koeven.meeterz.ev

import android.content.Context
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.BufferedInputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.zip.GZIPInputStream
import de.koeven.meeterz.data.Backend
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject

/**
 * Live-Belegung der Ladesäulen (wie ChargeStatusService.swift): Schweiz (Bundesamt für Energie, ~1 Min. aktuell)
 * direkt, Deutschland über die Mobilithek (AFIR-Daten der Betreiber, auf unserem Server gesammelt).
 */
object ChargeStatusService {
    private const val SWISS_URL = "https://data.geo.admin.ch/ch.bfe.ladestellen-elektromobilitaet/status/oicp/ch.bfe.ladestellen-elektromobilitaet.json"
    private var swiss: Map<String, String> = emptyMap()   // EvseID → Available / Occupied / OutOfService …
    private var swissLoaded = 0L
    private val mutex = Mutex()

    /** Belegung der Standorte mit Ladepunkt-IDs entlang der Route (lädt höchstens alle 3 Minuten) */
    suspend fun availability(context: Context, points: List<ChargePlanner.RoutePoint>): Map<ChargeSite, ChargeAvailability> {
        val result = HashMap(germany(context, points))
        val inSwitzerland = points.any { it.lat > 45.8 && it.lat < 47.9 && it.lng > 5.9 && it.lng < 10.5 }
        if (!inSwitzerland) return result
        refreshSwiss()
        val status = swiss
        if (status.isEmpty()) return result
        for (site in EvData.sites(context)) {
            if (site.evseIds.isEmpty()) continue
            var free = 0; var occupied = 0; var out = 0
            for (id in site.evseIds) when (status[id]?.lowercase()) {
                "available" -> free++
                "occupied", "reserved" -> occupied++
                "outofservice", "out of service" -> out++
            }
            val a = ChargeAvailability(free, occupied, out)
            if (a.total > 0) result[site] = a
        }
        return result
    }

    @Serializable
    private data class Row(val lat: Double, val lng: Double, val free: Int, val occupied: Int,
                           @SerialName("out_of_service") val outOfService: Int, @SerialName("price_kwh") val priceKwh: Double? = null)

    /** Mobilithek-Standorte im Korridor der Route (RPC charge_availability), je dem nächsten eigenen Standort (bis 150 m) */
    private suspend fun germany(context: Context, points: List<ChargePlanner.RoutePoint>): Map<ChargeSite, ChargeAvailability> {
        if (points.isEmpty()) return emptyMap()
        val samples = RouteConditions.sample(points, 5_000.0).let { s -> s.filterIndexed { i, _ -> i % maxOf(1, s.size / 400) == 0 } }
        val rows = runCatching {
            Backend.client.postgrest.rpc("charge_availability", buildJsonObject {
                put("lats", JsonArray(samples.map { JsonPrimitive(it.lat) }))
                put("lngs", JsonArray(samples.map { JsonPrimitive(it.lng) }))
            }).decodeList<Row>()
        }.onFailure { Log.w("Meeterz", "Ladesäulen-Belegung DE: ${it.message}") }.getOrNull().orEmpty()
        if (rows.isEmpty()) return emptyMap()
        val minLat = rows.minOf { it.lat } - 0.01; val maxLat = rows.maxOf { it.lat } + 0.01
        val minLng = rows.minOf { it.lng } - 0.015; val maxLng = rows.maxOf { it.lng } + 0.015
        val nearby = EvData.sites(context).filter { it.lat in minLat..maxLat && it.lng in minLng..maxLng }
        val result = HashMap<ChargeSite, ChargeAvailability>()
        for (r in rows) {
            val site = nearby.minByOrNull { ChargePlanner.distance(it.lat, it.lng, r.lat, r.lng) } ?: continue
            if (ChargePlanner.distance(site.lat, site.lng, r.lat, r.lng) >= 150) continue
            val a = result[site] ?: ChargeAvailability()
            result[site] = ChargeAvailability(a.free + r.free, a.occupied + r.occupied, a.outOfService + r.outOfService,
                listOfNotNull(a.priceKwh, r.priceKwh).minOrNull())
        }
        Log.i("Meeterz", "Ladesäulen-Belegung DE: ${rows.size} Standorte gemeldet, ${result.size} zugeordnet")
        return result
    }

    private suspend fun refreshSwiss() = mutex.withLock {
        if (System.currentTimeMillis() - swissLoaded < 180_000) return@withLock
        val map = withContext(Dispatchers.IO) {
            runCatching {
                val c = URL(SWISS_URL).openConnection() as HttpURLConnection
                c.connectTimeout = 8_000; c.readTimeout = 20_000
                try {
                    // Die Datei kommt teils gzip-komprimiert ohne Content-Encoding
                    val raw = BufferedInputStream(c.inputStream).apply { mark(2) }
                    val b1 = raw.read(); val b2 = raw.read(); raw.reset()
                    val stream = if (b1 == 0x1f && b2 == 0x8b) GZIPInputStream(raw) else raw
                    val root = Json.parseToJsonElement(stream.bufferedReader().use { it.readText() }).jsonObject
                    buildMap {
                        for (block in root["EVSEStatuses"]?.jsonArray.orEmpty()) {
                            for (rec in block.jsonObject["EVSEStatusRecord"]?.jsonArray.orEmpty()) {
                                val o = rec.jsonObject
                                val id = o["EvseID"]?.jsonPrimitive?.content ?: continue
                                val st = o["EVSEStatus"]?.jsonPrimitive?.content ?: continue
                                put(id, st)
                            }
                        }
                    }
                } finally { c.disconnect() }
            }.onFailure { Log.w("Meeterz", "Ladesäulen-Belegung CH: nicht erreichbar") }.getOrNull()
        }
        if (!map.isNullOrEmpty()) {
            swiss = map; swissLoaded = System.currentTimeMillis()
            Log.i("Meeterz", "Ladesäulen-Belegung CH: ${map.size} Ladepunkte")
        }
    }
}
