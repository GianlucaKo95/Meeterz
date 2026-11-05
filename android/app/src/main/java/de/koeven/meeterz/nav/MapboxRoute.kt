package de.koeven.meeterz.nav

import com.mapbox.api.directions.v5.models.LegStep
import com.mapbox.navigation.base.trip.model.RouteProgress

/** Mapbox' Routenfortschritt → plattformneutrales Modell für die Ansage-Regeln */
object MapboxRoute {
    fun legState(progress: RouteProgress): LegState? {
        val legProgress = progress.currentLegProgress ?: return null
        val stepProgress = legProgress.currentStepProgress ?: return null
        val leg = legProgress.routeLeg ?: progress.navigationRoute.directionsRoute.legs()?.getOrNull(legProgress.legIndex) ?: return null
        val steps = leg.steps()?.map(::step) ?: return null
        if (stepProgress.stepIndex !in steps.indices) return null
        return LegState(steps, stepProgress.stepIndex, stepProgress.distanceRemaining.toDouble(), stepProgress.intersectionIndex)
    }

    fun step(s: LegStep): Step {
        val (codes, places) = Step.parseDestinations(s.destinations())
        val maneuver = s.maneuver()
        return Step(
            type = ManeuverType.of(maneuver.type()),
            direction = Direction.of(maneuver.modifier()),
            distance = s.distance(),
            names = listOfNotNull(s.name()?.takeIf { it.isNotBlank() }),
            codes = s.ref()?.split(";")?.map { it.trim() }?.filter { it.isNotEmpty() } ?: emptyList(),
            destinations = places,
            destinationCodes = codes,
            maneuverLat = maneuver.location().latitude(),
            maneuverLng = maneuver.location().longitude(),
            junctions = s.intersections().orEmpty().map { x ->
                Junction(
                    lat = x.location().latitude(),
                    lng = x.location().longitude(),
                    trafficSignal = x.trafficSignal() == true,
                    stopSign = x.stopSign() == true,
                    headings = x.bearings().orEmpty().map { it.toDouble() },
                    approachIndex = x.`in`(),
                    motorway = x.classes()?.contains("motorway") == true,
                )
            },
            voice = s.voiceInstructions().orEmpty().mapNotNull { v ->
                val text = v.announcement() ?: return@mapNotNull null
                Voice(v.distanceAlongGeometry() ?: 0.0, text)
            },
        )
    }
}
