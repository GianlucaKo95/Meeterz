package de.koeven.meeterz.ev

import de.koeven.meeterz.tr
import android.content.Context
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Fahrzeugprofil (wie EVVehicle auf iOS). Katalog aus Open EV Data (MIT mit Namensnennung) – dieselbe Datei
 * wie in der iOS-App (Meeterz/Resources/ev-vehicles.json, beim Bauen in die Assets kopiert).
 */
@Serializable
data class EvVehicle(
    val id: String,
    val brand: String,
    val model: String,
    val variant: String = "",
    val year: Int? = null,
    /** Nutzbare Batterie in kWh */
    val battery: Double,
    /** Durchschnittsverbrauch in kWh/100 km */
    val consumption: Double,
    val dcMax: Double? = null,
    /** Ladekurve: [Prozent, kW] */
    val curve: List<List<Double>> = emptyList(),
    val ports: List<String> = emptyList(),
    val estimated: Boolean = false,
) {
    val name get() = listOf(model, variant).filter { it.isNotEmpty() }.joinToString(" ")
    val fullName get() = "$brand $name" + (year?.let { " ($it)" } ?: "")

    /** Ladeleistung (kW) bei einem Akkustand, linear zwischen den Punkten der Ladekurve */
    fun chargingPower(percent: Double): Double {
        val points = curve.filter { it.size == 2 }.sortedBy { it[0] }
        val first = points.firstOrNull() ?: return dcMax ?: 50.0
        if (percent <= first[0]) return first[1]
        for ((a, b) in points.zipWithNext()) {
            if (percent <= b[0]) return a[1] + (b[1] - a[1]) * (percent - a[0]) / maxOf(b[0] - a[0], 0.001)
        }
        return points.last()[1]
    }
}

/** Schnellladestandort (BNetzA, IRVE, BFE, OSM – gebündelt wie auf iOS) */
data class ChargeSite(
    val lat: Double,
    val lng: Double,
    val maxKW: Double,
    val points: Int,
    val name: String,
    val operatorName: String,
    val city: String,
    val country: String = "DE",
    /** Ladepunkt-IDs für die Live-Belegung (bisher Schweiz) */
    val evseIds: List<String> = emptyList(),
) {
    val powerKnown get() = maxKW > 0
    val plannedKW get() = if (powerKnown) maxKW else 50.0
    val title get() = if (name == operatorName || name.isEmpty()) "${short(operatorName)} $city" else name

    companion object {
        /** „EnBW mobility+ AG und Co.KG“ → „EnBW mobility+“ */
        fun short(name: String): String {
            var n = name
            for (suffix in listOf(" GmbH & Co. KG", " GmbH & Co.KG", " AG und Co.KG", " AG & Co. KG", " GmbH", " AG", " SE", " mbH", " KG", " e.V.")) {
                val i = n.indexOf(suffix)
                if (i >= 0) n = n.substring(0, i)
            }
            return n.trim()
        }
    }
}

/** Live-Belegung eines Standorts */
data class ChargeAvailability(val free: Int = 0, val occupied: Int = 0, val outOfService: Int = 0,
                              /** Ad-hoc-Preis inkl. MwSt. (€/kWh, Mobilithek) */
                              val priceKwh: Double? = null) {
    /** „0,59 €/kWh“ */
    val priceText get() = priceKwh?.let { String.format(java.util.Locale.GERMANY, "%.2f €/kWh", it) }
    val total get() = free + occupied + outOfService
    val full get() = total > 0 && free == 0 && occupied > 0
    val allOutOfService get() = total > 0 && outOfService == total
    /** „2 von 4 frei“ */
    val text get() = if (allOutOfService) tr("außer Betrieb") else tr("%lld von %lld frei", free, total)
}

object EvData {
    const val ATTRIBUTION = "Ladesäulen: Bundesnetzagentur.de (CC BY 4.0), data.gouv.fr IRVE, Bundesamt für Energie, " +
        tr("Open Charge Map (CC BY 4.0), © OpenStreetMap-Mitwirkende (ODbL) · Höhen und Wetter: Open-Meteo.com (CC BY 4.0)")

    private val json = Json { ignoreUnknownKeys = true }
    @Volatile private var vehicles: List<EvVehicle>? = null
    @Volatile private var sites: List<ChargeSite>? = null

    fun vehicles(context: Context): List<EvVehicle> = vehicles ?: runCatching {
        val text = context.assets.open("ev-vehicles.json").bufferedReader().use { it.readText() }
        json.decodeFromString<List<EvVehicle>>(json.parseToJsonElement(text).jsonObject["vehicles"].toString())
    }.getOrDefault(emptyList()).also { vehicles = it }

    /** Säulen aus Deutschland und Nachbarländern (≈ 30 000 Standorte; einmal laden, dann im Speicher) */
    fun sites(context: Context): List<ChargeSite> = sites ?: (load(context, "chargers-de.json") + load(context, "chargers-eu.json")).also { sites = it }

    private fun load(context: Context, file: String): List<ChargeSite> = runCatching {
        val text = context.assets.open(file).bufferedReader().use { it.readText() }
        json.parseToJsonElement(text).jsonObject["sites"]!!.jsonArray.mapNotNull { row ->
            val r = row as? JsonArray ?: return@mapNotNull null
            if (r.size < 7) return@mapNotNull null
            fun d(i: Int) = (r[i] as? JsonPrimitive)?.doubleOrNull ?: 0.0
            fun s(i: Int) = (r[i] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: ""
            val evse = (r.getOrNull(8) as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.content } ?: emptyList()
            ChargeSite(d(0), d(1), d(2), d(3).toInt(), s(4), s(5), s(6), if (r.size > 7) s(7) else "DE", evse)
        }
    }.getOrDefault(emptyList())
}
