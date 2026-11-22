package de.koeven.meeterz

import de.koeven.meeterz.nav.PlaceSearch.Place
import de.koeven.meeterz.nav.SearchRanking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class SearchRankingTest {
    @Test fun passendesNahesVorFalschemFernem() {
        val out = SearchRanking.merge(emptyList(), listOf(
            Place("Bodensee-Therme", null, 47.6, 9.4),
            Place("Boda Borg Stockholm", null, 59.3, 18.0),
            Place("Boda Borg Duisburg", null, 51.44, 6.78)), "Boda Borg", 51.43, 6.76)
        assertEquals("Boda Borg Duisburg", out.first().name)
        assertFalse(out.any { it.name == "Bodensee-Therme" })
    }

    @Test fun doppelterOrtNurEinmal() {
        val out = SearchRanking.merge(listOf(Place("Boda Borg", "Gerät", 51.4400, 6.7800)),
            listOf(Place("Boda Borg", "Mapbox", 51.4401, 6.7801)), "boda", 51.43, 6.76)
        assertEquals(listOf("Gerät"), out.map { it.address })
    }
}
