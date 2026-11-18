package de.koeven.meeterz.nav

import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.parameter
import io.ktor.client.statement.bodyAsText
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Ortsangaben aus OpenStreetMap (Overpass API, ODbL – Hinweis „© OpenStreetMap“): Website, Telefon, Öffnungszeiten
 * für POIs, zu denen Mapbox nichts hat (wie OsmPlaces.swift). Ein Request je Tipp, gleicher Name im Umkreis von 80 m.
 */
object OsmPlaces {
    data class Info(val website: String?, val phone: String?, val openingHours: String?)

    private val http by lazy { HttpClient(OkHttp) }
    private val json = Json { ignoreUnknownKeys = true }

    suspend fun info(name: String, lat: Double, lng: Double): Info? = runCatching {
        // Regex-Sonderzeichen und Anführungszeichen weglassen – der Name wird als Teilstring gesucht
        val clean = name.replace(Regex("""[\\^$.|?*+()\[\]{}"]"""), "").trim()
        if (clean.isEmpty()) return null
        val query = """[out:json][timeout:8];nwr(around:80,$lat,$lng)["name"~"$clean",i];out tags 5;"""
        val body = http.get("https://overpass-api.de/api/interpreter") {
            parameter("data", query)
            header("User-Agent", "Meeterz/1.0 (Android)")
        }.bodyAsText()
        val tags = json.parseToJsonElement(body).jsonObject["elements"]?.jsonArray.orEmpty()
            .mapNotNull { it.jsonObject["tags"] as? JsonObject }
        fun JsonObject.s(vararg keys: String) = keys.firstNotNullOfOrNull { this[it]?.jsonPrimitive?.contentOrNull?.takeIf(String::isNotBlank) }
        val t = tags.firstOrNull { it.s("website", "contact:website", "phone", "contact:phone", "opening_hours") != null } ?: return null
        Info(t.s("website", "contact:website", "url"), t.s("phone", "contact:phone"), t.s("opening_hours"))
    }.onFailure { de.koeven.meeterz.Diag.log("OSM-Details: ${it.message}") }.getOrNull()

    /**
     * Öffnungszeiten für mehrere Orte mit EINER Abfrage (Listen in Android Auto): je Ort derselbe Name im Umkreis
     * von 80 m. Ergebnis je Index der Liste; fehlt etwas, bleibt der Eintrag weg.
     */
    suspend fun hours(places: List<PlaceSearch.Place>): Map<Int, List<List<IntRange>>> = runCatching {
        val parts = places.mapIndexedNotNull { i, p ->
            val clean = p.name.replace(Regex("""[\\^$.|?*+()\[\]{}"]"""), "").trim()
            if (clean.isEmpty()) null else """nwr(around:80,${p.lat},${p.lng})["name"~"$clean",i]["opening_hours"];"""
        }
        if (parts.isEmpty()) return emptyMap()
        val body = http.get("https://overpass-api.de/api/interpreter") {
            parameter("data", "[out:json][timeout:8];(${parts.joinToString("")});out tags center;")
            header("User-Agent", "Meeterz/1.0 (Android)")
        }.bodyAsText()
        val elements = json.parseToJsonElement(body).jsonObject["elements"]?.jsonArray.orEmpty().map { it.jsonObject }
        val result = mutableMapOf<Int, List<List<IntRange>>>()
        places.forEachIndexed { i, p ->
            val hit = elements.firstOrNull { e ->
                val c = (e["center"] as? JsonObject) ?: e
                val lat = c["lat"]?.jsonPrimitive?.contentOrNull?.toDoubleOrNull() ?: return@firstOrNull false
                val lng = c["lon"]?.jsonPrimitive?.contentOrNull?.toDoubleOrNull() ?: return@firstOrNull false
                val name = (e["tags"] as? JsonObject)?.get("name")?.jsonPrimitive?.contentOrNull.orEmpty()
                de.koeven.meeterz.ev.ChargePlanner.distance(lat, lng, p.lat, p.lng) < 150 &&
                    (name.contains(p.name, true) || p.name.contains(name, true))
            } ?: return@forEachIndexed
            val text = (hit["tags"] as? JsonObject)?.get("opening_hours")?.jsonPrimitive?.contentOrNull ?: return@forEachIndexed
            parse(text)?.let { result[i] = it }
        }
        result
    }.onFailure { de.koeven.meeterz.Diag.log("OSM-Öffnungszeiten: ${it.message}") }.getOrDefault(emptyMap())

    /** „Geöffnet bis 23:00“, „Geschlossen · öffnet 17:00“, „Geschlossen“ bzw. „24 Stunden geöffnet“ – für Listen im Auto */
    fun status(hours: List<List<IntRange>>, now: java.util.Calendar = java.util.Calendar.getInstance()): String {
        val day = (now.get(java.util.Calendar.DAY_OF_WEEK) + 5) % 7
        val min = now.get(java.util.Calendar.HOUR_OF_DAY) * 60 + now.get(java.util.Calendar.MINUTE)
        fun hhmm(m: Int) = "%02d:%02d".format((m / 60) % 24, m % 60)
        if (hours[day].any { it.first == 0 && it.last >= 1439 }) return de.koeven.meeterz.tr("24 Stunden geöffnet")
        // offen seit gestern (über Mitternacht) oder jetzt
        hours[(day + 6) % 7].firstOrNull { min + 1440 in it }?.let { return de.koeven.meeterz.tr("Geöffnet bis %@", hhmm(it.last + 1)) }
        hours[day].firstOrNull { min in it }?.let { return de.koeven.meeterz.tr("Geöffnet bis %@", hhmm(it.last + 1)) }
        hours[day].filter { it.first > min }.minByOrNull { it.first }?.let { return de.koeven.meeterz.tr("Geschlossen · öffnet %@", hhmm(it.first)) }
        return de.koeven.meeterz.tr("Geschlossen")
    }

    private val dayNames = listOf("Mo", "Tu", "We", "Th", "Fr", "Sa", "Su")
    private val dayRegex = Regex("""^((?:Mo|Tu|We|Th|Fr|Sa|Su)(?:-(?:Mo|Tu|We|Th|Fr|Sa|Su))?(?:,(?:Mo|Tu|We|Th|Fr|Sa|Su)(?:-(?:Mo|Tu|We|Th|Fr|Sa|Su))?)*)?\s*(.*)$""")
    private val spanRegex = Regex("""^(\d{1,2}):(\d{2})-(\d{1,2}):(\d{2})\+?$""")

    /**
     * OSM-`opening_hours` in Minuten-Spannen je Tag (0 = Montag) wie PlaceSearch.Details.hours. Versteht den üblichen
     * Teil („Mo-Fr 09:00-18:00; Sa 10:00-14:00; Su off“, „24/7“, mehrere Zeiten, über Mitternacht); Feiertagsregeln
     * („PH off“) werden übersprungen. Alles andere (Monate, Wochen, Kommentare) → null, dann wird der Text gezeigt.
     */
    fun parse(text: String): List<List<IntRange>>? {
        val s = text.trim()
        if (s == "24/7") return List(7) { listOf(0 until 1440) }
        val days = List(7) { mutableListOf<IntRange>() }
        var any = false
        for (raw in s.split(';')) {
            // Feiertage/Schulferien aus der Tagesliste nehmen; eine reine Feiertagsregel fällt damit weg
            val holiday = Regex("""\b(PH|SH)\b""").containsMatchIn(raw)
            val rule = raw.replace(Regex("""\s*,?\s*\b(PH|SH)\b\s*,?"""), " ").trim()
            if (rule.isEmpty() || (holiday && !Regex("""^(Mo|Tu|We|Th|Fr|Sa|Su)""").containsMatchIn(rule))) continue
            val m = dayRegex.find(rule) ?: return null
            val set = m.groupValues[1].takeIf { it.isNotEmpty() }?.split(',')?.flatMap { part ->
                val ends = part.split('-')
                val a = ends[0]; val b = ends.getOrElse(1) { a }
                val from = dayNames.indexOf(a); val to = dayNames.indexOf(b)
                (0..((to - from + 7) % 7)).map { (from + it) % 7 }
            } ?: (0..6).toList()
            val rest = m.groupValues[2].trim()
            val spans = if (rest == "off" || rest == "closed") emptyList() else rest.split(',').map { t ->
                val g = spanRegex.find(t.trim())?.groupValues ?: return null
                val start = g[1].toInt() * 60 + g[2].toInt()
                var end = g[3].toInt() * 60 + g[4].toInt()
                if (end <= start) end += 1440   // über Mitternacht
                start until end
            }
            for (d in set) { days[d].clear(); days[d] += spans }
            any = true
        }
        return if (any) days else null
    }
}
