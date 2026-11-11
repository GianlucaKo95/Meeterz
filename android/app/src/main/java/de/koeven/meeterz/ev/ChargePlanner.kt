package de.koeven.meeterz.ev

import de.koeven.meeterz.tr
import java.util.PriorityQueue
import kotlin.math.PI
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Ladeplanung wie bei ABRP – 1:1 wie ChargePlanner.swift: Ankunft mit Ziel-Akkustand, Stopps so gewählt, dass
 * Fahr- plus Ladezeit minimal ist. Energiemodell: Fahrzeugverbrauch nach Tempo (Luftwiderstand quadratisch,
 * Gegenwind zählt mit), Kälte und Regen erhöhen ihn, Steigungen kosten, Gefälle wird teils rekuperiert.
 */
object ChargePlanner {
    data class Settings(
        val arrivalPercent: Double = 20.0,
        val minAtChargerPercent: Double = 10.0,
        val maxChargePercent: Double = 100.0,
        /** Feste Zeit je Stopp (Abfahrt, Anschließen, Bezahlen), s */
        val stopOverhead: Double = 4 * 60.0,
        val temperature: Double? = null,
        /** Gelernte Korrektur je Tempobereich (Stadt < 60, Land 60–100, Autobahn > 100 km/h) */
        val factors: List<Double> = listOf(1.0, 1.0, 1.0),
        val conditions: RouteConditions? = null,
        /** Live-Belegung (wo verfügbar): defekte Säulen meiden, voll belegte mit Wartezeit */
        val availability: Map<ChargeSite, ChargeAvailability> = emptyMap(),
        /** Feste Halte (Konvoi-Pause, Treffpunkt): werden angefahren; mit Ladesäule nach Bedarf laden, ohne nicht (wie iOS) */
        val fixed: List<Candidate> = emptyList(),
    )

    data class Stop(val site: ChargeSite, val distanceFromStart: Double, val arrivalPercent: Double,
                    val departurePercent: Double, val chargeTime: Double, val availability: ChargeAvailability? = null,
                    /** Fester Halt (Konvoi-Pause mit Ladesäule) – bleibt beim Übernehmen eines neuen Plans */
                    val fixed: Boolean = false)

    data class Plan(val stops: List<Stop>, val arrivalPercent: Double, val startPercent: Double,
                    val totalChargeTime: Double, val driveTime: Double, val belowTarget: Boolean = false) {
        val direct get() = stops.isEmpty()
        /** „2 Ladestopps · 35 Min. laden · Ankunft mit 21 %“ (Texte wie iOS) */
        val summary: String get() {
            val arrival = Math.round(arrivalPercent)
            if (direct && belowTarget) return tr("Ankunft mit %@ % · kein Ladestopp auf der Strecke", arrival)
            if (direct) return tr("Kein Ladestopp nötig · Ankunft mit %@ %", arrival)
            val n = if (stops.size == 1) tr("1 Ladestopp") else tr("%lld Ladestopps", stops.size)
            return tr("%@ · %@ Min. laden · Ankunft mit %@ %", n, Math.round(totalChargeTime / 60), arrival)
        }
    }

    sealed class Outcome {
        data class Planned(val plan: Plan) : Outcome()
        data class Unreachable(val reachKm: Double) : Outcome()
    }

    // Route aufbereiten

    /** Punkt entlang der Route: Strecke (m) und Fahrzeit (s) ab Start, Tempo des Abschnitts */
    data class RoutePoint(val lat: Double, val lng: Double, val dist: Double, val time: Double, val kmh: Double)

    /** Punkte mit aufsummierter Strecke (m), Zeit (s) und Energie (kWh) */
    class Profile(val lat: DoubleArray, val lng: DoubleArray, val dist: DoubleArray, val energy: DoubleArray, val time: DoubleArray) {
        fun energy(a: Double, b: Double) = value(energy, b) - value(energy, a)
        fun time(a: Double, b: Double) = value(time, b) - value(time, a)
        val total get() = dist.lastOrNull() ?: 0.0

        /** Restliche Strecke ab `d` Metern (für Neuplanung unterwegs) */
        fun suffix(d: Double): Profile {
            if (d <= 0) return this
            val i = dist.indexOfFirst { it >= d }.takeIf { it >= 0 } ?: return this
            val e0 = value(energy, d); val t0 = value(time, d)
            val idx = (if (dist[i] > d) listOf(maxOf(0, i - 1)) else emptyList()) + (i until dist.size)
            val start = dist[i] > d
            return Profile(
                DoubleArray(idx.size) { lat[idx[it]] }, DoubleArray(idx.size) { lng[idx[it]] },
                DoubleArray(idx.size) { if (start && it == 0) 0.0 else dist[idx[it]] - d },
                DoubleArray(idx.size) { if (start && it == 0) 0.0 else energy[idx[it]] - e0 },
                DoubleArray(idx.size) { if (start && it == 0) 0.0 else time[idx[it]] - t0 },
            )
        }

        private fun value(arr: DoubleArray, d: Double): Double {
            if (dist.isEmpty()) return 0.0
            if (d <= 0) return arr[0]
            if (d >= dist.last()) return arr.last()
            var lo = 0; var hi = dist.size - 1
            while (hi - lo > 1) { val mid = (lo + hi) / 2; if (dist[mid] <= d) lo = mid else hi = mid }
            val t = (d - dist[lo]) / maxOf(dist[hi] - dist[lo], 0.01)
            return arr[lo] + (arr[hi] - arr[lo]) * t
        }
    }

    /** Verbrauch (kWh/km) auf ebener Strecke; Gegenwind in km/h (negativ = Rückenwind), Regen in mm/h */
    fun consumption(kmh: Double, base: Double, temperature: Double?, headwind: Double = 0.0, rain: Double = 0.0): Double {
        val v = min(max(kmh, 15.0), 200.0)
        val air = max(0.0, v + headwind)
        var c = base / 100 * (0.72 + 0.28 * (air / 75).pow(2))
        if (temperature != null && temperature < 15) c *= 1 + min(0.3, (15 - temperature) * 0.012)
        if (rain >= 0.3) c *= if (rain >= 2) 1.08 else 1.04
        return c
    }

    /** Fahrzeugmasse (kg) inkl. Fahrer, aus der Batteriegröße geschätzt */
    fun mass(vehicle: EvVehicle) = 1_100 + 9 * vehicle.battery + 80

    /** Energie (kWh) eines Stücks: eben plus Höhenunterschied; bergab erst rollen, nur der Überschuss wird rekuperiert (65 %) */
    fun segmentEnergy(meters: Double, flatPerMeter: Double, climb: Double, mass: Double): Double {
        val flat = meters * flatPerMeter
        val lift = mass * 9.81 * climb / 3_600_000
        val net = flat + if (climb > 0) lift / 0.9 else lift
        return if (net < 0) net * 0.65 else net
    }

    fun band(kmh: Double) = if (kmh < 60) 0 else if (kmh <= 100) 1 else 2

    fun profile(points: List<RoutePoint>, vehicle: EvVehicle, settings: Settings): Profile {
        val n = points.size
        val lat = DoubleArray(n); val lng = DoubleArray(n); val dist = DoubleArray(n); val energy = DoubleArray(n); val time = DoubleArray(n)
        if (n == 0) return Profile(lat, lng, dist, energy, time)
        val m = mass(vehicle)
        val c = settings.conditions
        var e = 0.0
        points.forEachIndexed { i, b ->
            lat[i] = b.lat; lng[i] = b.lng; dist[i] = b.dist; time[i] = b.time
            if (i > 0) {
                val a = points[i - 1]
                val meters = b.dist - a.dist
                if (meters > 0) {
                    val w = c?.weather((a.dist + b.dist) / 2, (a.time + b.time) / 2)
                    val headwind = w?.let { it.wind * 0.7 * 3.6 * cos((it.windFrom - bearing(a.lat, a.lng, b.lat, b.lng)) * PI / 180) } ?: 0.0
                    val flat = consumption(b.kmh, vehicle.consumption, w?.temperature ?: settings.temperature, headwind, w?.rain ?: 0.0) / 1000 *
                        settings.factors[band(b.kmh)]
                    val climb = c?.let { cc -> cc.height(b.dist)?.let { hb -> cc.height(a.dist)?.let { hb - it } } } ?: 0.0
                    e += segmentEnergy(meters, flat, climb, m)
                }
            }
            energy[i] = e
        }
        return Profile(lat, lng, dist, energy, time)
    }

    // Säulen entlang der Route

    data class Candidate(val site: ChargeSite, val along: Double, val offset: Double,
                         /** Fester Halt: darf nicht übersprungen werden */ val fixed: Boolean = false,
                         /** Am festen Halt laden möglich? */ val canCharge: Boolean = true)

    fun candidates(p: Profile, sites: List<ChargeSite>, corridor: Double = 2_500.0): List<Candidate> {
        if (p.lat.size < 2) return emptyList()
        val cell = 0.02
        fun key(la: Double, ln: Double) = floor(la / cell).toLong() to floor(ln / cell).toLong()
        val grid = HashMap<Pair<Long, Long>, MutableList<Int>>()
        for (i in p.lat.indices) grid.getOrPut(key(p.lat[i], p.lng[i])) { mutableListOf() }.add(i)
        val minLat = p.lat.min() - 0.05; val maxLat = p.lat.max() + 0.05
        val minLng = p.lng.min() - 0.07; val maxLng = p.lng.max() + 0.07
        val result = mutableListOf<Candidate>()
        for (s in sites) {
            if (s.lat <= minLat || s.lat >= maxLat || s.lng <= minLng || s.lng >= maxLng) continue
            val (ky, kx) = key(s.lat, s.lng)
            var bestI = -1; var bestD = Double.MAX_VALUE
            for (dy in -1..1) for (dx in -1..1) for (i in grid[(ky + dy) to (kx + dx)] ?: emptyList()) {
                val d = distance(p.lat[i], p.lng[i], s.lat, s.lng)
                if (d < bestD) { bestD = d; bestI = i }
            }
            if (bestI >= 0 && bestD <= corridor) result += Candidate(s, p.dist[bestI], bestD)
        }
        // Je 5 km die zwei besten (stärkste Leistung, wenig Umweg)
        return result.groupBy { (it.along / 5_000).toInt() }.values
            .flatMap { g -> g.sortedByDescending { it.site.plannedKW - it.offset / 50 }.take(2) }
            .sortedBy { it.along }
    }

    /** Sekunden, um von `from` auf `to` Prozent zu laden (Ladekurve, Säulenleistung, 92 % Wirkungsgrad) */
    fun chargeTime(vehicle: EvVehicle, from: Double, to: Double, siteKW: Double): Double {
        if (to <= from) return 0.0
        var seconds = 0.0
        var p = from
        val kwhPerPercent = vehicle.battery / 100
        while (p < to) {
            val step = min(1.0, to - p)
            val power = max(3.0, minOf(vehicle.chargingPower(p + step / 2), siteKW, vehicle.dcMax ?: siteKW))
            seconds += kwhPerPercent * step / (power * 0.92) * 3600
            p += step
        }
        return seconds
    }

    /** Darunter gilt das Ziel als nicht erreichbar */
    const val HARD_MINIMUM_PERCENT = 3.0

    private data class State(val node: Int, val soc: Int)
    private data class Link(val from: State, val depart: Double, val charge: Double)

    fun plan(p: Profile, vehicle: EvVehicle, startPercent: Double, settings: Settings, sites: List<ChargeSite>): Outcome {
        val total = p.total
        if (total <= 0) return Outcome.Unreachable(0.0)
        fun pct(kwh: Double) = kwh / vehicle.battery * 100
        val cands = (candidates(p, sites).filter { settings.availability[it.site]?.allOutOfService != true } +
            settings.fixed.filter { it.along > 0 && it.along < total }).sortedBy { it.along }

        val directArrival = startPercent - pct(p.energy(0.0, total))
        if (directArrival >= settings.arrivalPercent) {
            return Outcome.Planned(Plan(emptyList(), directArrival, startPercent, 0.0, p.time(0.0, total)))
        }

        val n = cands.size
        val destination = n + 1
        fun along(i: Int) = if (i == 0) 0.0 else if (i == destination) total else cands[i - 1].along
        fun detourEnergy(i: Int) = if (i == 0 || i == destination) 0.0 else pct(cands[i - 1].offset * 2 / 1000 * vehicle.consumption / 100)
        fun detourTime(i: Int) = if (i == 0 || i == destination) 0.0 else cands[i - 1].offset * 2 / 1000 / 40 * 3600
        fun isFixed(i: Int) = i in 1 until destination && cands[i - 1].fixed
        // Nächster fester Halt nach Knoten i (darf nicht übersprungen werden)
        val nextFixed = IntArray(destination + 1) { destination }
        for (i in destination - 1 downTo 0) nextFixed[i] = if (isFixed(i + 1)) i + 1 else nextFixed[i + 1]

        val best = HashMap<State, Double>()
        val previous = HashMap<State, Link>()
        val queue = PriorityQueue<Pair<Double, State>>(compareBy { it.first })
        fun push(s: State, cost: Double, link: Link?) {
            if (cost >= (best[s] ?: Double.MAX_VALUE)) return
            best[s] = cost
            if (link != null) previous[s] = link
            queue.add(cost to s)
        }
        push(State(0, floor(startPercent).toInt()), 0.0, null)
        var goal: State? = null

        while (queue.isNotEmpty()) {
            val (cost, s) = queue.poll()!!
            if (cost > (best[s] ?: Double.MAX_VALUE)) continue
            if (s.node == destination) { goal = s; break }
            val arrival = if (s.node == 0) startPercent else s.soc.toDouble()
            val here = along(s.node)
            val siteKW = if (s.node == 0) 0.0 else cands[s.node - 1].site.plannedKW
            val fixedHere = isFixed(s.node)
            for (j in (s.node + 1)..minOf(destination, nextFixed[s.node])) {
                val there = along(j)
                if (there <= here + (if (j == destination || isFixed(j)) 0.0 else 5_000.0)) continue
                val need = pct(p.energy(here, there)) + detourEnergy(s.node) / 2 + detourEnergy(j) / 2
                val minArrival = if (j == destination) settings.arrivalPercent else settings.minAtChargerPercent
                val requiredDeparture = need + minArrival
                if (requiredDeparture > settings.maxChargePercent) {
                    if (pct(p.energy(here, there)) + minArrival > settings.maxChargePercent) break
                    continue
                }
                var depart = arrival
                var charge = 0.0
                if (s.node == 0 || (fixedHere && !cands[s.node - 1].canCharge)) {
                    if (arrival < requiredDeparture) continue                  // am Start / Halt ohne Säule kein Laden
                } else if (fixedHere) {
                    // Pause an der Ladesäule: nur so viel laden wie nötig (gar nicht, wenn es reicht)
                    depart = maxOf(arrival, requiredDeparture)
                    if (depart > arrival) charge = chargeTime(vehicle, arrival, depart, siteKW) +
                        if (settings.availability[cands[s.node - 1].site]?.full == true) 10 * 60.0 else 0.0
                } else {
                    if (requiredDeparture <= arrival) continue
                    depart = requiredDeparture
                    charge = chargeTime(vehicle, arrival, depart, siteKW) + settings.stopOverhead +
                        if (settings.availability[cands[s.node - 1].site]?.full == true) 10 * 60.0 else 0.0   // alles belegt: warten
                }
                val drive = p.time(here, there) + detourTime(s.node) / 2 + detourTime(j) / 2
                push(State(j, floor(depart - need).toInt()), cost + drive + charge, Link(s, depart, charge))
            }
        }

        val g = goal ?: run {
            if (directArrival >= HARD_MINIMUM_PERCENT) {
                return Outcome.Planned(Plan(emptyList(), directArrival, startPercent, 0.0, p.time(0.0, total), belowTarget = true))
            }
            val reach = (startPercent - settings.minAtChargerPercent) / 100 * vehicle.battery / max(p.energy(0.0, total) / total * 1000, 0.05)
            return Outcome.Unreachable(reach)
        }
        val stops = mutableListOf<Stop>()
        var s: State = g
        var totalCharge = 0.0
        while (true) {
            val link = previous[s] ?: break
            if (link.from.node != 0 && !(cands[link.from.node - 1].fixed && link.charge == 0.0)) {
                val c = cands[link.from.node - 1]
                val availability = settings.availability[c.site]
                val wait = if (availability?.full == true) 10 * 60.0 else 0.0
                val overhead = if (c.fixed) 0.0 else settings.stopOverhead   // die Pause macht man ohnehin
                stops.add(0, Stop(c.site, c.along, link.from.soc.toDouble(), link.depart, link.charge - overhead - wait, availability, c.fixed))
                totalCharge += link.charge - overhead - wait
            }
            s = link.from
        }
        return Outcome.Planned(Plan(stops, g.soc.toDouble(), startPercent, totalCharge, p.time(0.0, total)))
    }

    // Geometrie (ohne Android-Klassen, damit es auch in Unit-Tests läuft)

    fun distance(lat1: Double, lng1: Double, lat2: Double, lng2: Double): Double {
        val r = 6_371_000.0
        val dLat = (lat2 - lat1) * PI / 180; val dLng = (lng2 - lng1) * PI / 180
        val a = sin(dLat / 2).pow(2) + cos(lat1 * PI / 180) * cos(lat2 * PI / 180) * sin(dLng / 2).pow(2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }

    /** Richtung in Grad (0 = Nord, 90 = Ost) */
    fun bearing(lat1: Double, lng1: Double, lat2: Double, lng2: Double): Double {
        val f1 = lat1 * PI / 180; val f2 = lat2 * PI / 180; val dl = (lng2 - lng1) * PI / 180
        val y = sin(dl) * cos(f2)
        val x = cos(f1) * sin(f2) - sin(f1) * cos(f2) * cos(dl)
        return (atan2(y, x) * 180 / PI + 360) % 360
    }
}
