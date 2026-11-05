package de.koeven.meeterz.nav

import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/*
 * Plattformneutrales Abbild der Mapbox-Route, gerade so viel, wie die Ansage-Regeln brauchen.
 * Die Regeln (Announcements.kt) sind damit reines Kotlin und wie auf iOS ohne Gerät testbar.
 * Gefüllt wird es aus Mapbox' LegStep/RouteProgress (MapboxRoute.kt).
 */

enum class ManeuverType {
    DEPART, ARRIVE, TURN, END_OF_ROAD, CONTINUE, NEW_NAME, MERGE, ON_RAMP, OFF_RAMP, FORK,
    ROUNDABOUT, ROTARY, ROUNDABOUT_TURN, EXIT_ROUNDABOUT, EXIT_ROTARY, USE_LANE, NOTIFICATION, OTHER;

    companion object {
        /** Mapbox-Typen („turn“, „end of road“, „off ramp“ …) */
        fun of(raw: String?): ManeuverType = when (raw) {
            "depart" -> DEPART; "arrive" -> ARRIVE; "turn" -> TURN; "end of road" -> END_OF_ROAD
            "continue" -> CONTINUE; "new name" -> NEW_NAME; "merge" -> MERGE; "on ramp" -> ON_RAMP
            "off ramp" -> OFF_RAMP; "fork" -> FORK; "roundabout" -> ROUNDABOUT; "rotary" -> ROTARY
            "roundabout turn" -> ROUNDABOUT_TURN; "exit roundabout" -> EXIT_ROUNDABOUT; "exit rotary" -> EXIT_ROTARY
            "use lane" -> USE_LANE; "notification" -> NOTIFICATION
            else -> OTHER
        }
    }
}

enum class Direction {
    UTURN, SHARP_RIGHT, RIGHT, SLIGHT_RIGHT, STRAIGHT, SLIGHT_LEFT, LEFT, SHARP_LEFT;

    companion object {
        fun of(raw: String?): Direction? = when (raw) {
            "uturn" -> UTURN; "sharp right" -> SHARP_RIGHT; "right" -> RIGHT; "slight right" -> SLIGHT_RIGHT
            "straight" -> STRAIGHT; "slight left" -> SLIGHT_LEFT; "left" -> LEFT; "sharp left" -> SHARP_LEFT
            else -> null
        }
    }
}

data class Junction(
    val lat: Double,
    val lng: Double,
    val trafficSignal: Boolean = false,
    val stopSign: Boolean = false,
    /** Richtungen aller Straßen an der Kreuzung (Grad) */
    val headings: List<Double> = emptyList(),
    /** Index der Straße, aus der man kommt */
    val approachIndex: Int? = null,
    /** Die Straße, auf der man die Kreuzung verlässt, ist eine Autobahn */
    val motorway: Boolean = false,
)

data class Voice(val distanceAlongStep: Double, val text: String)

data class Step(
    val type: ManeuverType,
    val direction: Direction? = null,
    val distance: Double = 0.0,
    val names: List<String> = emptyList(),
    val codes: List<String> = emptyList(),
    val destinations: List<String> = emptyList(),
    val destinationCodes: List<String> = emptyList(),
    val maneuverLat: Double = 0.0,
    val maneuverLng: Double = 0.0,
    val junctions: List<Junction> = emptyList(),
    val voice: List<Voice> = emptyList(),
) {
    val onMotorway get() = junctions.any { it.motorway }

    companion object {
        /** Mapbox-Schild „A 42: Kamp-Lintfort, Venlo“ → Nummern [A 42], Ziele [Kamp-Lintfort, Venlo] (wie iOS) */
        fun parseDestinations(raw: String?): Pair<List<String>, List<String>> {
            if (raw.isNullOrBlank()) return emptyList<String>() to emptyList()
            val colon = raw.indexOf(':')
            val codes = if (colon >= 0) raw.substring(0, colon).split(",").map { it.trim() }.filter { it.isNotEmpty() } else emptyList()
            val places = (if (colon >= 0) raw.substring(colon + 1) else raw).split(",").map { it.trim() }.filter { it.isNotEmpty() }
            return codes to places
        }
    }
}

/** Stand auf dem aktuellen Abschnitt der Etappe */
data class LegState(
    val steps: List<Step>,
    val stepIndex: Int,
    /** Meter bis zum Ende des aktuellen Abschnitts */
    val distanceRemaining: Double,
    /** Zuletzt passierte Kreuzung im aktuellen Abschnitt */
    val intersectionIndex: Int = 0,
) {
    val current get() = steps[stepIndex]
    val upcoming get() = steps.getOrNull(stepIndex + 1)
    val followOn get() = steps.getOrNull(stepIndex + 2)
    val prior get() = steps.getOrNull(stepIndex - 1)
}

fun meters(aLat: Double, aLng: Double, bLat: Double, bLng: Double): Double {
    val r = 6_371_000.0
    val dLat = Math.toRadians(bLat - aLat)
    val dLng = Math.toRadians(bLng - aLng)
    val h = sin(dLat / 2) * sin(dLat / 2) + cos(Math.toRadians(aLat)) * cos(Math.toRadians(bLat)) * sin(dLng / 2) * sin(dLng / 2)
    return 2 * r * atan2(sqrt(h), sqrt(1 - h))
}

internal fun angleDiff(a: Double, b: Double): Double {
    var d = abs(a - b) % 360
    if (d > 180) d = 360 - d
    return d
}
