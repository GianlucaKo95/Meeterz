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

    /** Server nimmt höchstens 10 000 Punkte (set_active_route) */
    const val MAX_POINTS = 9_000

    /**
     * Stützpunkte ab der aktuellen Position als [lng, lat, eta_unix]: mindestens alle [spacing] Meter und jede Ecke,
     * an der die Strecke mehr als [tolerance] Meter von der Geraden abweicht (sonst schneidet die Route der Freunde
     * quer durch Häuser). Restzeit auf die Prognose skaliert. Wie RouteSampler.swift.
     */
    fun sharePoints(all: List<Sample>, traveled: Double, durationRemaining: Double, nowSeconds: Double,
                    spacing: Double = 300.0, tolerance: Double = 5.0): List<List<Double>> {
        val last = all.lastOrNull() ?: return emptyList()
        if (all.size < 2) return emptyList()
        val base = interpolatedTime(traveled, all)
        val raw = last.time - base
        val factor = if (raw > 1) durationRemaining / raw else 1.0
        val ahead = all.filter { it.distance >= traveled }
        if (ahead.size < 2) return emptyList()
        val keep = corners(ahead, tolerance).toMutableSet()
        var next = traveled
        ahead.forEachIndexed { i, s -> if (s.distance >= next) { keep += i; next = s.distance + spacing } }
        keep += ahead.lastIndex
        if (keep.size > MAX_POINTS && tolerance < 200) return sharePoints(all, traveled, durationRemaining, nowSeconds, spacing, tolerance * 2)
        return keep.sorted().map { i -> ahead[i].let { s -> listOf(s.lng, s.lat, nowSeconds + (s.time - base) * factor) } }
    }

    /** Ramer-Douglas-Peucker: Indizes der Punkte, ohne die die Linie um mehr als [tolerance] Meter abwiche */
    fun corners(s: List<Sample>, tolerance: Double): Set<Int> {
        if (s.size <= 2) return s.indices.toSet()
        val keep = mutableSetOf(0, s.lastIndex)
        val lat0 = Math.toRadians(s[0].lat)
        val xs = s.map { it.lng * 111_320 * kotlin.math.cos(lat0) }
        val ys = s.map { it.lat * 110_540 }
        val stack = ArrayDeque(listOf(0 to s.lastIndex))
        while (stack.isNotEmpty()) {
            val (a, b) = stack.removeLast()
            if (b <= a + 1) continue
            val dx = xs[b] - xs[a]; val dy = ys[b] - ys[a]
            val len2 = dx * dx + dy * dy
            var worst = 0.0; var worstIndex = a
            for (i in a + 1 until b) {
                val t = if (len2 > 0) (((xs[i] - xs[a]) * dx + (ys[i] - ys[a]) * dy) / len2).coerceIn(0.0, 1.0) else 0.0
                val ex = xs[a] + t * dx - xs[i]; val ey = ys[a] + t * dy - ys[i]
                val d = kotlin.math.sqrt(ex * ex + ey * ey)
                if (d > worst) { worst = d; worstIndex = i }
            }
            if (worst > tolerance) { keep += worstIndex; stack.addLast(a to worstIndex); stack.addLast(worstIndex to b) }
        }
        return keep
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
