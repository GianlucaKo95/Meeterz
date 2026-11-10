package de.koeven.meeterz.ev

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale

/** Höhenprofil und Wetter entlang der Route (wie RouteConditions.swift; Quelle Open-Meteo) */
class RouteConditions(
    val heights: List<Pair<Double, Double>> = emptyList(),   // (Strecke m, Höhe m)
    val weather: List<Weather> = emptyList(),
    val departure: Long = System.currentTimeMillis() / 1000,
) {
    class Weather(val dist: Double, val times: List<Double>, val temperature: List<Double>, val wind: List<Double>,
                  val windFrom: List<Double>, val rain: List<Double>)
    data class Sample(val temperature: Double, val wind: Double, val windFrom: Double, val rain: Double)

    fun height(d: Double): Double? {
        if (heights.isEmpty()) return null
        if (d <= heights.first().first) return heights.first().second
        if (d >= heights.last().first) return heights.last().second
        var lo = 0; var hi = heights.size - 1
        while (hi - lo > 1) { val mid = (lo + hi) / 2; if (heights[mid].first <= d) lo = mid else hi = mid }
        val (da, ha) = heights[lo]; val (db, hb) = heights[hi]
        return ha + (hb - ha) * (d - da) / maxOf(db - da, 0.01)
    }

    /** Wetter am nächsten Messpunkt zur Stunde, in der ich dort bin */
    fun weather(d: Double, afterSeconds: Double): Sample? {
        val w = weather.minByOrNull { kotlin.math.abs(it.dist - d) } ?: return null
        if (w.times.isEmpty()) return null
        val t = departure + afterSeconds
        val i = w.times.indexOfLast { it <= t }.coerceAtLeast(0)
        if (i >= w.temperature.size || i >= w.wind.size || i >= w.windFrom.size || i >= w.rain.size) return null
        return Sample(w.temperature[i], w.wind[i], w.windFrom[i], w.rain[i])
    }

    companion object {
        private val cache = HashMap<String, Pair<RouteConditions, Long>>()

        /** Laden oder aus dem Speicher (eine Stunde gültig); ohne Netz null – dann ohne Höhe und Wetter */
        suspend fun load(key: String, points: List<ChargePlanner.RoutePoint>): RouteConditions? {
            synchronized(cache) { cache[key]?.takeIf { System.currentTimeMillis() - it.second < 3_600_000 }?.let { return it.first } }
            val total = points.lastOrNull()?.dist ?: return null
            if (points.size < 2 || total <= 0) return null
            val result = coroutineScope {
                val h = async { heights(points, total) }
                val w = async { weather(points, total) }
                val (hh, ww) = h.await() to w.await()
                if (hh == null && ww == null) null else RouteConditions(hh ?: emptyList(), ww ?: emptyList())
            } ?: return null
            synchronized(cache) { if (cache.size > 20) cache.clear(); cache[key] = result to System.currentTimeMillis() }
            Log.i("Meeterz", "Routenbedingungen: ${result.heights.size} Höhenpunkte, ${result.weather.size} Wetterpunkte für ${(total / 1000).toInt()} km")
            return result
        }

        fun sample(points: List<ChargePlanner.RoutePoint>, every: Double): List<ChargePlanner.RoutePoint> {
            val out = mutableListOf<ChargePlanner.RoutePoint>()
            var next = 0.0
            for (p in points) if (p.dist >= next) { out += p; next = p.dist + every }
            points.lastOrNull()?.let { if (out.last().dist != it.dist) out += it }
            return out
        }

        private fun query(ps: List<ChargePlanner.RoutePoint>) =
            "latitude=" + ps.joinToString(",") { String.format(Locale.US, "%.4f", it.lat) } +
                "&longitude=" + ps.joinToString(",") { String.format(Locale.US, "%.4f", it.lng) }

        private suspend fun get(url: String): JsonElement? = withContext(Dispatchers.IO) {
            runCatching {
                val c = URL(url).openConnection() as HttpURLConnection
                c.connectTimeout = 8_000; c.readTimeout = 12_000
                try {
                    if (c.responseCode != 200) null else Json.parseToJsonElement(c.inputStream.bufferedReader().use { it.readText() })
                } finally { c.disconnect() }
            }.getOrNull()
        }

        /** Höhen alle ~1 km (höchstens 1000 Punkte, je Anfrage 100) */
        private suspend fun heights(points: List<ChargePlanner.RoutePoint>, total: Double): List<Pair<Double, Double>>? {
            val ps = sample(points, maxOf(1_000.0, total / 1_000))
            val out = mutableListOf<Pair<Double, Double>>()
            for (chunk in ps.chunked(100)) {
                val values = get("https://api.open-meteo.com/v1/elevation?" + query(chunk))
                    ?.jsonObject?.get("elevation")?.jsonArray?.map { it.jsonPrimitive.doubleOrNull ?: 0.0 }
                if (values == null || values.size != chunk.size) { Log.w("Meeterz", "Höhenprofil nicht geladen"); return null }
                out += chunk.zip(values).map { (p, h) -> p.dist to h }
            }
            return out
        }

        /** Wetter alle ~20 km (höchstens 50 Punkte), stündlich für 2 Tage */
        private suspend fun weather(points: List<ChargePlanner.RoutePoint>, total: Double): List<Weather>? {
            val ps = sample(points, maxOf(20_000.0, total / 50))
            val body = get("https://api.open-meteo.com/v1/forecast?" + query(ps) +
                "&hourly=temperature_2m,wind_speed_10m,wind_direction_10m,precipitation&wind_speed_unit=ms&timeformat=unixtime&forecast_days=2&timezone=GMT")
            val locations: List<JsonObject> = when (body) {
                is JsonArray -> body.map { it.jsonObject }
                is JsonObject -> listOf(body)
                else -> { Log.w("Meeterz", "Wetter entlang der Route nicht geladen"); return null }
            }
            if (locations.size != ps.size) return null
            return ps.zip(locations).map { (p, l) ->
                val h = l["hourly"]!!.jsonObject
                fun list(name: String, fallback: Double) = h[name]?.jsonArray?.map { it.jsonPrimitive.doubleOrNull ?: fallback } ?: emptyList()
                Weather(p.dist, list("time", 0.0), list("temperature_2m", 10.0), list("wind_speed_10m", 0.0),
                    list("wind_direction_10m", 0.0), list("precipitation", 0.0))
            }
        }
    }
}
