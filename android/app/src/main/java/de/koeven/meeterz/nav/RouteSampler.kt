package de.koeven.meeterz.nav

import com.mapbox.api.directions.v5.models.DirectionsRoute
import com.mapbox.core.constants.Constants
import com.mapbox.geojson.LineString

/** Route in Stützpunkte mit Ankunftszeit umrechnen, zum Teilen mit Freunden (wie RouteSampler.swift) */
object RouteSampler {
    data class Sample(val lng: Double, val lat: Double, val distance: Double, val time: Double)
    /** Ein Abschnitt: Koordinaten [lng, lat] und Fahrzeit laut Route */
    data class Piece(val coords: List<Pair<Double, Double>>, val duration: Double)

    fun samples(pieces: List<Piece>): List<Sample> {
        val out = mutableListOf<Sample>()
        var dist = 0.0
        var time = 0.0
        for (p in pieces) {
            if (p.coords.isEmpty()) { time += p.duration; continue }
            val segments = (1 until p.coords.size).map { i ->
                meters(p.coords[i - 1].second, p.coords[i - 1].first, p.coords[i].second, p.coords[i].first)
            }
            val length = maxOf(segments.sum(), 0.1)
            if (out.isEmpty()) out += Sample(p.coords[0].first, p.coords[0].second, 0.0, 0.0)
            segments.forEachIndexed { i, seg ->
                dist += seg
                time += p.duration * seg / length
                out += Sample(p.coords[i + 1].first, p.coords[i + 1].second, dist, time)
            }
            if (segments.isEmpty()) time += p.duration
        }
        return out
    }

    fun pieces(route: DirectionsRoute): List<Piece> = route.legs().orEmpty().flatMap { it.steps().orEmpty() }.map { s ->
        val coords = s.geometry()?.let { LineString.fromPolyline(it, Constants.PRECISION_6).coordinates().map { c -> c.longitude() to c.latitude() } }
        Piece(coords.orEmpty(), s.duration())
    }

    /** Stützpunkte ab der aktuellen Position, ca. alle [spacing] Meter, als [lng, lat, eta_unix]; Restzeit auf die Prognose skaliert */
    fun sharePoints(all: List<Sample>, traveled: Double, durationRemaining: Double, nowSeconds: Double, spacing: Double = 300.0): List<List<Double>> {
        val last = all.lastOrNull() ?: return emptyList()
        if (all.size < 2) return emptyList()
        val base = interpolatedTime(traveled, all)
        val raw = last.time - base
        val factor = if (raw > 1) durationRemaining / raw else 1.0
        val points = mutableListOf<List<Double>>()
        var next = traveled
        for (s in all) {
            if (s.distance < traveled) continue
            if (s.distance >= next || s.distance == last.distance) {
                points += listOf(s.lng, s.lat, nowSeconds + (s.time - base) * factor)
                next = s.distance + spacing
            }
        }
        return points
    }

    private fun interpolatedTime(distance: Double, samples: List<Sample>): Double {
        val idx = samples.indexOfFirst { it.distance >= distance }
        if (idx < 0) return samples.last().time
        if (idx == 0) return samples[0].time
        val a = samples[idx - 1]; val b = samples[idx]
        val span = b.distance - a.distance
        val t = if (span > 0) (distance - a.distance) / span else 0.0
        return a.time + (b.time - a.time) * t
    }
}
