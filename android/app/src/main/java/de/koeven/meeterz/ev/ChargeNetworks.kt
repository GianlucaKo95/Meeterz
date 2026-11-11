package de.koeven.meeterz.ev

import android.content.Context
import de.koeven.meeterz.AppState
import de.koeven.meeterz.Diag
import de.koeven.meeterz.tr

/**
 * Bevorzugte und gemiedene Ladenetze (wie ChargeNetworks.swift / ABRP). Ein Netz = Betreiber, zusammengefasst über
 * die erste Namenshälfte („EnBW mobility+ AG“ und „EnBW“ → „enbw“). Nur auf dem Gerät gespeichert.
 */
object ChargeNetworks {
    data class Network(val id: String, val name: String, val sites: Int)

    private val clean = Regex("[^a-z0-9äöüéèčß. ]")

    /** Schlüssel eines Betreibers: erstes Wort (bei sehr kurzen Wörtern die ersten zwei), klein, ohne Satzzeichen */
    fun key(operatorName: String): String {
        val words = operatorName.lowercase().replace(clean, " ").split(" ").filter { it.isNotEmpty() }
        val first = words.firstOrNull() ?: return ""
        return if (first.length <= 2 && first !in setOf("bp", "ok") && words.size > 1) "$first ${words[1]}" else first
    }

    @Volatile private var cached: List<Network>? = null

    /** Die größten Netze in den gebündelten Daten (für die Auswahl) */
    fun all(context: Context): List<Network> = cached ?: run {
        val counts = HashMap<String, Int>()
        val names = HashMap<String, HashMap<String, Int>>()
        for (s in EvData.sites(context)) {
            if (s.operatorName.isEmpty()) continue
            val k = key(s.operatorName).ifEmpty { continue }
            counts[k] = (counts[k] ?: 0) + 1
            val n = names.getOrPut(k) { HashMap() }
            val short = ChargeSite.short(s.operatorName)
            n[short] = (n[short] ?: 0) + 1
        }
        counts.filter { it.value >= 20 }.map { (k, n) ->
            // Kürzester häufiger Name: „EnBW“ statt „EnBW mobility+“
            val name = names[k].orEmpty().filter { it.value * 5 >= n }.keys.minByOrNull { it.length } ?: k
            Network(k, name, n)
        }.sortedByDescending { it.sites }.also { cached = it }
    }

    private fun prefs() = AppState.appContextOrNull()?.getSharedPreferences("app", 0)
    val preferred: Set<String> get() = prefs()?.getStringSet("ev.networks.preferred", emptySet()).orEmpty()
    val avoided: Set<String> get() = prefs()?.getStringSet("ev.networks.avoided", emptySet()).orEmpty()

    /** "preferred", "avoided" oder null */
    fun preference(key: String) = when (key) { in preferred -> "preferred"; in avoided -> "avoided"; else -> null }

    fun set(key: String, preference: String?) {
        val pre = preferred - key + (if (preference == "preferred") setOf(key) else emptySet())
        val avo = avoided - key + (if (preference == "avoided") setOf(key) else emptySet())
        prefs()?.edit()?.putStringSet("ev.networks.preferred", pre)?.putStringSet("ev.networks.avoided", avo)?.apply()
        Diag.log("Ladenetz $key: ${preference ?: "egal"}")
    }

    /** „2 bevorzugt · 1 gemieden“ */
    val summary: String get() {
        val p = preferred.size; val a = avoided.size
        if (p == 0 && a == 0) return tr("Alle gleich")
        return listOfNotNull(if (p > 0) tr("%lld bevorzugt", p) else null, if (a > 0) tr("%lld gemieden", a) else null).joinToString(" · ")
    }
}
