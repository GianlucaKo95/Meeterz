package de.koeven.meeterz

import android.content.Context
import androidx.core.os.LocaleListCompat
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Übersetzungen aus demselben Katalog wie iOS (Shared/Localizable.xcstrings, 7 Sprachen) plus Android-eigene Texte
 * (android/l10n/Android.xcstrings). Schlüssel = deutscher Text mit %@/%lld wie auf iOS; fehlt eine Übersetzung, bleibt Deutsch.
 */
object L10n {
    val supported = listOf("de", "en", "fr", "es", "it", "pt", "tr")
    /** Sprache der App: erste unterstützte aus den Geräteeinstellungen, sonst Deutsch (wie iOS: developmentLanguage) */
    val language: String by lazy {
        val list = LocaleListCompat.getDefault()
        (0 until list.size()).mapNotNull { list[it]?.language }.firstOrNull { it in supported } ?: "de"
    }
    private var table: Map<String, JsonObject> = emptyMap()

    fun init(context: Context) {
        if (language == "de") return   // Schlüssel sind schon deutsch
        val merged = HashMap<String, JsonObject>()
        for (file in listOf("Localizable.xcstrings", "Android.xcstrings")) {
            runCatching {
                val root = Json.parseToJsonElement(context.assets.open(file).bufferedReader().use { it.readText() }).jsonObject
                root["strings"]?.jsonObject?.forEach { (k, v) -> v.jsonObject["localizations"]?.jsonObject?.get(language)?.jsonObject?.let { merged[k] = it } }
            }
        }
        table = merged
    }

    fun lookup(key: String, args: Array<out Any?>): String {
        val loc = table[key] ?: return format(key, args)
        val unit = loc["stringUnit"]?.jsonObject
            ?: loc["variations"]?.jsonObject?.get("plural")?.jsonObject?.let { plural ->
                val n = args.firstOrNull { it is Number } as? Number
                (plural[if (n?.toLong() == 1L) "one" else "other"] ?: plural["other"])?.jsonObject?.get("stringUnit")?.jsonObject
            }
        val value = unit?.get("value")?.jsonPrimitive?.content ?: key
        return format(value, args)
    }

    private val spec = Regex("""%(?:(\d+)\$)?(@|lld|ld|d|f|\.\d+f|%)""")

    /** %@ / %lld / %1$@ … durch die Werte ersetzen (Reihenfolge wie auf iOS) */
    fun format(text: String, args: Array<out Any?>): String {
        if (args.isEmpty()) return text.replace("%%", "%")
        var next = 0
        return spec.replace(text) { m ->
            if (m.groupValues[2] == "%") return@replace "%"
            val index = m.groupValues[1].toIntOrNull()?.minus(1) ?: next++
            val v = args.getOrNull(index)
            when {
                m.groupValues[2].endsWith("f") && v is Number -> String.format(java.util.Locale.getDefault(), "%" + m.groupValues[2], v.toDouble())
                else -> v?.toString() ?: ""
            }
        }
    }
}

/** Übersetzter Text (Schlüssel = deutscher Text wie auf iOS) */
fun tr(key: String, vararg args: Any?): String = L10n.lookup(key, args)
