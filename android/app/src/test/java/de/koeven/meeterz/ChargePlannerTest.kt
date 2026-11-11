package de.koeven.meeterz

import de.koeven.meeterz.ev.ChargePlanner
import de.koeven.meeterz.ev.ChargeSite
import de.koeven.meeterz.ev.EvVehicle
import de.koeven.meeterz.ev.RouteConditions
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Gleiche Fälle wie ChargePlannerTests.swift: gerade Strecke nach Süden bei 120 km/h */
class ChargePlannerTest {
    private val vehicle = EvVehicle("t", "Test", "EV", battery = 60.0, consumption = 18.0, dcMax = 100.0,
        curve = listOf(listOf(0.0, 100.0), listOf(50.0, 100.0), listOf(80.0, 60.0), listOf(100.0, 15.0)))

    private fun points(km: Int) = (0..km).map { ChargePlanner.RoutePoint(52 - it / 111.32, 8.0, it * 1000.0, it * 30.0, 120.0) }
    private fun sites(every: Int, upTo: Int) = (every until upTo step every).map {
        ChargeSite(52 - it / 111.32, 8.002, 150.0, 4, "Säule $it", "Test", "")
    }
    private fun energy(c: RouteConditions?) =
        ChargePlanner.profile(points(100), vehicle, ChargePlanner.Settings(temperature = 20.0, conditions = c)).energy.last()

    private fun weather(windFrom: Double, wind: Double = 10.0, temp: Double = 20.0, rain: Double = 0.0): RouteConditions {
        val now = System.currentTimeMillis() / 1000.0 - 60
        val t = listOf(now, now + 3600, now + 7200)
        return RouteConditions(weather = listOf(RouteConditions.Weather(0.0, t, t.map { temp }, t.map { wind }, t.map { windFrom }, t.map { rain })))
    }

    @Test fun directWhenEnoughCharge() {
        val o = ChargePlanner.plan(ChargePlanner.profile(points(100), vehicle, ChargePlanner.Settings()), vehicle, 90.0, ChargePlanner.Settings(), emptyList())
        assertTrue(o is ChargePlanner.Outcome.Planned && o.plan.direct)
    }

    @Test fun longTripNeedsStopsAndArrivesWithTarget() {
        val s = ChargePlanner.Settings()
        val o = ChargePlanner.plan(ChargePlanner.profile(points(600), vehicle, s), vehicle, 90.0, s, sites(50, 600))
        val plan = (o as ChargePlanner.Outcome.Planned).plan
        assertTrue(plan.stops.isNotEmpty())
        assertTrue(plan.arrivalPercent >= 20 - 1)
        plan.stops.forEach { assertTrue(it.arrivalPercent >= 10 - 1) }
    }

    private fun fixed(km: Int, charger: Boolean) = ChargePlanner.Candidate(
        ChargeSite(52 - km / 111.32, 8.002, if (charger) 150.0 else 0.0, 4, "Pause", "Test", ""), km * 1000.0, 0.0, fixed = true, canCharge = charger)

    @Test fun fixedChargerStopIsUsed() {
        val s = ChargePlanner.Settings(fixed = listOf(fixed(120, true)))
        val plan = (ChargePlanner.plan(ChargePlanner.profile(points(300), vehicle, s), vehicle, 90.0, s, sites(50, 300)) as ChargePlanner.Outcome.Planned).plan
        val atPause = plan.stops.first { it.fixed }
        assertEquals(120_000.0, atPause.distanceFromStart, 1.0)
        assertTrue(atPause.chargeTime > 0)
    }

    @Test fun fixedChargerWithoutNeedChargesNothing() {
        val s = ChargePlanner.Settings(fixed = listOf(fixed(50, true)))
        val o = ChargePlanner.plan(ChargePlanner.profile(points(100), vehicle, s), vehicle, 90.0, s, emptyList())
        assertTrue(o is ChargePlanner.Outcome.Planned && o.plan.direct)
    }

    @Test fun fixedStopWithoutChargerGetsStopBefore() {
        val s = ChargePlanner.Settings(fixed = listOf(fixed(100, false)))
        val plan = (ChargePlanner.plan(ChargePlanner.profile(points(300), vehicle, s), vehicle, 50.0, s, sites(50, 300)) as ChargePlanner.Outcome.Planned).plan
        assertTrue(plan.stops.first().distanceFromStart < 100_000)
        assertTrue(plan.stops.none { it.fixed })
    }

    @Test fun unreachableWithoutChargers() {
        val s = ChargePlanner.Settings()
        assertTrue(ChargePlanner.plan(ChargePlanner.profile(points(600), vehicle, s), vehicle, 80.0, s, emptyList()) is ChargePlanner.Outcome.Unreachable)
    }

    @Test fun climbCostsAndDescentPartlyReturns() {
        val flat = energy(null)
        val up = energy(RouteConditions(heights = listOf(0.0 to 0.0, 100_000.0 to 500.0)))
        assertEquals(ChargePlanner.mass(vehicle) * 9.81 * 500 / 3_600_000 / 0.9, up - flat, 0.05)
        assertTrue(energy(RouteConditions(heights = listOf(0.0 to 500.0, 100_000.0 to 0.0))) < flat)
        assertTrue(energy(RouteConditions(heights = listOf(0.0 to 0.0, 50_000.0 to 500.0, 100_000.0 to 0.0))) > flat)
    }

    @Test fun headwindCostsTailwindSaves() {
        val flat = energy(null)
        assertTrue(energy(weather(180.0)) > flat * 1.05)
        assertTrue(energy(weather(0.0)) < flat * 0.95)
        assertEquals(flat, energy(weather(90.0)), 0.05)
    }

    @Test fun coldAndRainRaiseConsumption() {
        val flat = energy(null)
        assertTrue(energy(weather(90.0, wind = 0.0, temp = 0.0)) > flat * 1.1)
        assertTrue(energy(weather(90.0, wind = 0.0, rain = 3.0)) > flat * 1.05)
    }

    @Test fun suffixStartsAtZero() {
        val p = ChargePlanner.profile(points(100), vehicle, ChargePlanner.Settings())
        val rest = p.suffix(40_500.0)
        assertEquals(0.0, rest.dist[0], 1e-9)
        assertEquals(p.energy(40_500.0, 100_000.0), rest.energy.last(), 1e-6)
    }
}
