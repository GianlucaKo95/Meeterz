package de.koeven.meeterz

import de.koeven.meeterz.nav.OsmPlaces
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class OsmHoursTest {
    @Test fun typischeWoche() {
        val h = OsmPlaces.parse("Mo,We-Sa 17:00-23:00; Tu off; Su 12:00-21:30; PH off")!!
        assertEquals(listOf(1020 until 1380), h[0])
        assertEquals(emptyList<IntRange>(), h[1])
        assertEquals(listOf(1020 until 1380), h[5])
        assertEquals(listOf(720 until 1290), h[6])
    }

    @Test fun mittagspauseUndMitternacht() {
        val h = OsmPlaces.parse("Mo-Fr 11:30-14:00,18:00-01:00")!!
        assertEquals(listOf(690 until 840, 1080 until 1500), h[4])
        assertEquals(emptyList<IntRange>(), h[5])
    }

    @Test fun rundUmDieUhrUndUnbekannt() {
        assertEquals(listOf(0 until 1440), OsmPlaces.parse("24/7")!![3])
        assertNull(OsmPlaces.parse("Jan-Mar Mo-Fr 10:00-12:00"))
    }
}
