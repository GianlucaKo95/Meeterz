package de.koeven.meeterz

import de.koeven.meeterz.nav.StandstillFilter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Gleiche Fälle wie StandstillFilterTests.swift */
class StandstillFilterTest {
    private fun fix(metersNorth: Double, speed: Double) = StandstillFilter.Fix(51.4 + metersNorth / 111_320, 6.7, speed, 0.0)

    @Test fun jitterWhileStandingDoesNotMovePosition() {
        val f = StandstillFilter()
        f.filter(fix(0.0, 8.0)); f.filter(fix(5.0, 0.3))
        val anchor = f.filter(fix(5.0, 0.2))
        assertTrue(f.frozen)
        for (jump in listOf(12.0, -6.0, 18.0, 3.0)) {
            val out = f.filter(fix(5 + jump, 0.4))
            assertEquals(anchor.lat, out.lat, 1e-9)
            assertEquals(0.0, out.speed, 0.0)
        }
    }

    @Test fun releasesAfterTwoMovingReports() {
        val f = StandstillFilter()
        f.filter(fix(0.0, 0.1)); f.filter(fix(0.0, 0.1))
        assertEquals(0.0, f.filter(fix(2.0, 2.5)).speed, 0.0)
        assertTrue(f.frozen)
        assertEquals(3.5, f.filter(fix(5.0, 3.5)).speed, 0.0)
        assertFalse(f.frozen)
    }

    @Test fun farAwayReleasesImmediately() {
        val f = StandstillFilter()
        f.filter(fix(0.0, 0.0)); f.filter(fix(0.0, 0.0))
        val out = f.filter(fix(200.0, -1.0))
        assertFalse(f.frozen)
        assertEquals(fix(200.0, 0.0).lat, out.lat, 1e-9)
    }

    @Test fun drivingPassesThrough() {
        val f = StandstillFilter()
        for (i in 0 until 5) assertEquals(fix(i * 14.0, 14.0), f.filter(fix(i * 14.0, 14.0)))
        assertFalse(f.frozen)
    }
}
