package de.koeven.meeterz.nav

import de.koeven.meeterz.tr
import com.mapbox.api.directions.v5.models.DirectionsRoute
import com.mapbox.navigation.base.route.NavigationRoute
import de.koeven.meeterz.AppState
import de.koeven.meeterz.Diag
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Routenoptionen (wie RoutePreferences.swift): Maut, Autobahnen, Fähren meiden. Gilt für jede Routenberechnung
 * und für Neuberechnungen unterwegs (Mapbox übernimmt die Optionen der laufenden Route).
 */
object RoutePreferences {
    enum class Option(val key: String, val title: String, val shortTitle: String, val exclude: String) {
        TOLLS("tolls", tr("Maut meiden"), tr("ohne Maut"), "toll"),
        MOTORWAYS("motorways", tr("Autobahnen meiden"), tr("ohne Autobahn"), "motorway"),
        FERRIES("ferries", tr("Fähren meiden"), tr("ohne Fähre"), "ferry"),
    }

    private fun prefs() = AppState.appContextOrNull()?.getSharedPreferences("app", 0)
    fun isOn(o: Option) = prefs()?.getBoolean("route.avoid.${o.key}", false) == true
    fun set(o: Option, on: Boolean) {
        prefs()?.edit()?.putBoolean("route.avoid.${o.key}", on)?.apply()
        Diag.log("Routenoption: ${o.title} ${if (on) "an" else "aus"}")
    }
    val active get() = Option.entries.filter(::isOn)
    /** Für RouteOptions.exclude – null = nichts meiden */
    val exclude get() = active.takeIf { it.isNotEmpty() }?.joinToString(",") { it.exclude }
    /** „ohne Maut, ohne Fähre“ */
    val summary get() = active.takeIf { it.isNotEmpty() }?.joinToString(", ") { it.shortTitle }
}

/**
 * Bis zu drei Routen zur Wahl nach festen Kriterien (wie RouteVariety.swift): Schnellste, Kürzeste, Ohne Autobahn.
 * Mapbox liefert oft nur eine Alternative – darum eine zweite Anfrage ohne Autobahnen, aus allen Kandidaten werden drei gewählt.
 */
object RouteVariety {
    enum class Kind(val label: String) { FASTEST(tr("Schnellste")), SHORTEST(tr("Kürzeste")), NO_MOTORWAY(tr("Ohne Autobahn")), OTHER(tr("Alternative")) }

    /** Bis zu dieser Länge der schnellsten Route wird „Ohne Autobahn“ angefragt */
    const val MAX_DISTANCE_NO_MOTORWAY = 150_000.0

    fun shouldWiden(fastest: DirectionsRoute) =
        RoutePreferences.Option.MOTORWAYS !in RoutePreferences.active && usesMotorway(fastest) && fastest.distance() <= MAX_DISTANCE_NO_MOTORWAY

    /** Schnellste + bis zu zwei weitere aus Mapbox' Alternativen und der Route ohne Autobahn */
    fun pick(routes: List<NavigationRoute>, extra: NavigationRoute?): List<NavigationRoute> {
        val fastest = routes.firstOrNull() ?: return routes
        val f = fastest.directionsRoute
        val candidates = (routes.drop(1) + listOfNotNull(extra))
            .filter { !same(it.directionsRoute, f) && reasonable(it.directionsRoute, f) }
            .fold(mutableListOf<NavigationRoute>()) { acc, c -> if (acc.none { same(it.directionsRoute, c.directionsRoute) }) acc += c; acc }
        val picked = mutableListOf<NavigationRoute>()
        candidates.minByOrNull { it.directionsRoute.distance() }?.takeIf { it.directionsRoute.distance() < f.distance() * 0.97 }?.let { picked += it }
        if (extra != null && extra in candidates && extra !in picked) picked += extra
        for (c in candidates.sortedBy { it.directionsRoute.duration() }) if (picked.size < 2 && c !in picked) picked += c
        val all = listOf(fastest) + picked
        Diag.log("Routenauswahl: ${all.size} Routen (${all.indices.joinToString { label(it, all) }})")
        return all
    }

    fun kind(index: Int, all: List<NavigationRoute>): Kind {
        if (index <= 0 || index >= all.size) return Kind.FASTEST
        val first = all[0].directionsRoute
        val route = all[index].directionsRoute
        val shortest = (1 until all.size).minByOrNull { all[it].directionsRoute.distance() }
        if (shortest == index && route.distance() < first.distance() * 0.97) return Kind.SHORTEST
        // Mapbox meidet Autobahnen nur weitgehend – höchstens 5 % der Strecke zählt als „ohne“
        if (motorwayShare(first) > 0.2 && motorwayShare(route) <= 0.05) return Kind.NO_MOTORWAY
        return Kind.OTHER
    }

    fun label(index: Int, all: List<NavigationRoute>) = kind(index, all).let { if (it == Kind.OTHER) tr("Alternative %lld", index) else it.label }

    /** Höchstens 25 % länger unterwegs, mindestens aber 15 Min. Spielraum */
    private fun reasonable(r: DirectionsRoute, fastest: DirectionsRoute) = r.duration() <= max(fastest.duration() * 1.25, fastest.duration() + 900)

    private fun motorwayOf(r: DirectionsRoute) = r.legs().orEmpty().flatMap { it.steps().orEmpty() }
        .filter { s -> s.intersections().orEmpty().any { it.classes()?.contains("motorway") == true } }

    fun usesMotorway(r: DirectionsRoute) = motorwayOf(r).isNotEmpty()
    fun motorwayShare(r: DirectionsRoute) = if (r.distance() <= 0) 0.0 else min(motorwayOf(r).sumOf { it.distance() } / r.distance(), 1.0)

    /** Praktisch dieselbe Strecke (Länge und Fahrzeit je höchstens 2 % auseinander) */
    private fun same(a: DirectionsRoute, b: DirectionsRoute) =
        abs(a.distance() - b.distance()) <= max(a.distance(), b.distance()) * 0.02 &&
            abs(a.duration() - b.duration()) <= max(a.duration(), b.duration()) * 0.02
}
