package de.koeven.meeterz

import de.koeven.meeterz.data.LivePosition
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Test

/** Beide Apps teilen die Live-Kanäle: Android muss lesen, was iOS sendet (und umgekehrt). */
class WireFormatTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun readsPositionFromIos() {
        // So kodiert Swifts JSONEncoder LivePosition (UUID groß geschrieben, ts in Sekunden)
        val ios = """{"userId":"6F1C2D3E-0000-4000-8000-ABCDEF012345","lat":51.47,"lng":6.68,"heading":90.5,"speed":13.2,"ts":1762335600.5}"""
        val p = json.decodeFromString<LivePosition>(ios)
        assertEquals(51.47, p.lat, 0.0)
        assertEquals(1762335600.5, p.ts, 0.0)
        assertEquals("6f1c2d3e-0000-4000-8000-abcdef012345", p.userId.lowercase())
    }

    @Test
    fun writesSameKeysAsIos() {
        val p = LivePosition("id", 1.0, 2.0, null, null, 3.0)
        val text = json.encodeToString(LivePosition.serializer(), p)
        for (key in listOf("\"userId\"", "\"lat\"", "\"lng\"", "\"ts\"")) assert(text.contains(key)) { text }
    }
}
