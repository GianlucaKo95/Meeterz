package de.koeven.meeterz.nav

import java.text.Normalizer

/*
 * Ansage-Regeln – 1:1 aus der iOS-App (LandmarkInstructions.swift, MeeterzSpeechSynthesizer.swift).
 * Änderungen hier immer auch dort nachziehen (und umgekehrt).
 */

private val THEN = Regex("""[,.]?\s+dann[\s,]""", RegexOption.IGNORE_CASE)
private val THEN_TAIL = Regex("""[,.]?\s+dann[\s,].*$""", RegexOption.IGNORE_CASE)
private val TURN_DIRECTIONS = setOf(Direction.LEFT, Direction.RIGHT, Direction.SHARP_LEFT, Direction.SHARP_RIGHT)

/** „An der nächsten Ampel rechts abbiegen“, „Am Ende der Straße rechts abbiegen“ (wie Apple Karten) */
object LandmarkInstructions {
    enum class Landmark { TRAFFIC_LIGHT, STOP_SIGN }

    const val JUNCTION_RADIUS = 50.0
    /** Bis hierhin gehören zwei Knoten zur selben Kreuzung (z. B. getrennte Fahrbahnen) */
    const val SAME_JUNCTION = 20.0

    fun rewrite(instruction: Voice, leg: LegState, maxDistance: Double = 800.0): String? {
        val upcoming = leg.upcoming ?: return null
        if (upcoming.type != ManeuverType.TURN && upcoming.type != ManeuverType.END_OF_ROAD) return null
        val direction = directionText(upcoming.direction) ?: return null
        if (instruction.distanceAlongStep <= 60 || leg.distanceRemaining >= maxDistance) return null
        if (instruction.text.contains("ampel", ignoreCase = true)) return null

        // Kreuzungen vom aktuellen Standort bis einschließlich der Abbiegung
        val all = leg.current.junctions + upcoming.junctions.take(1)
        val maneuver = all.lastOrNull() ?: return null
        val ahead = all.dropLast(1).drop(minOf(leg.intersectionIndex + 1, maxOf(all.size - 1, 0)))

        fun mark(x: Junction) = if (x.trafficSignal) Landmark.TRAFFIC_LIGHT else if (x.stopSign) Landmark.STOP_SIGN else null
        fun dist(a: Junction, b: Junction) = meters(a.lat, a.lng, b.lat, b.lng)

        var found = mark(maneuver)
        var afterIt = false
        if (found == null) {
            val index = ahead.indexOfLast { mark(it) != null && dist(it, maneuver) <= JUNCTION_RADIUS }
            if (index >= 0) {
                val node = ahead[index]
                found = mark(node)
                val between = ahead.drop(index + 1)
                val isJunction = { x: Junction -> x.headings.size >= 3 }
                afterIt = dist(node, maneuver) > SAME_JUNCTION &&
                    (isJunction(node) || between.any { isJunction(it) && dist(it, maneuver) > SAME_JUNCTION })
            }
        }
        val road = upcoming.names.firstOrNull { it.isNotEmpty() }
        val onRoad = road?.let { " auf $it" } ?: ""
        val landmark = found ?: run {
            // Keine Ampel, kein Stoppschild, aber die Straße endet an der Abbiegung
            if (upcoming.direction !in TURN_DIRECTIONS || !roadEnds(maneuver) || instruction.text.contains("Ende", ignoreCase = true)) return null
            return "Am Ende der Straße $direction abbiegen$onRoad"
        }

        // Ampeln davor zählen – mehrere markierte Knoten derselben Kreuzung (≤ 50 m auseinander) als eine
        var before = 0
        var last: Junction? = null
        for (x in ahead) {
            if (dist(x, maneuver) <= JUNCTION_RADIUS) continue
            val marked = if (landmark == Landmark.TRAFFIC_LIGHT) x.trafficSignal else x.stopSign
            if (!marked) continue
            if (last != null && dist(last, x) <= JUNCTION_RADIUS) continue
            before++
            last = x
        }
        if (afterIt) {
            if (before != 0) return null
            val place = if (landmark == Landmark.TRAFFIC_LIGHT) "Direkt nach der Ampel" else "Direkt nach dem Stoppschild"
            return "$place $direction abbiegen$onRoad"
        }
        return phrase(landmark, before + 1, direction, road)
    }

    /** Endet die Straße hier? Ja, wenn keine Straße in Fahrtrichtung weitergeht (höchstens 35° Abweichung) */
    fun roadEnds(x: Junction): Boolean {
        val approach = x.approachIndex ?: return false
        if (approach !in x.headings.indices) return false
        val travel = (x.headings[approach] + 180) % 360
        x.headings.forEachIndexed { i, h -> if (i != approach && angleDiff(h, travel) <= 35) return false }
        return x.headings.size >= 2
    }

    fun phrase(landmark: Landmark, ordinal: Int, direction: String, road: String?): String? {
        val ordinals = listOf("nächsten", "zweiten", "dritten")
        if (ordinal !in 1..3) return null
        val place = when (landmark) {
            Landmark.TRAFFIC_LIGHT -> "An der ${ordinals[ordinal - 1]} Ampel"
            Landmark.STOP_SIGN -> "Am ${ordinals[ordinal - 1]} Stoppschild"
        }
        return "$place $direction abbiegen" + (road?.let { " auf $it" } ?: "")
    }

    fun directionText(d: Direction?) = when (d) {
        Direction.LEFT -> "links"; Direction.RIGHT -> "rechts"
        Direction.SLIGHT_LEFT -> "leicht links"; Direction.SLIGHT_RIGHT -> "leicht rechts"
        Direction.SHARP_LEFT -> "scharf links"; Direction.SHARP_RIGHT -> "scharf rechts"
        else -> null
    }
}

/** „Jetzt rechts abbiegen, dann links abbiegen“ nur, wenn die zweite Abbiegung sofort folgt (≤ 80 m) */
object ThenInstructions {
    const val MAX_GAP = 80.0

    fun apply(text: String, leg: LegState): String {
        val first = leg.upcoming ?: return text
        if (leg.current.type == ManeuverType.DEPART) return text
        val hasThen = THEN.containsMatchIn(text)
        // Die Seite des Ziels („Dann befindet sich das Ziel auf der rechten Seite“) bleibt
        if (leg.followOn?.type == ManeuverType.ARRIVE) return text
        val second = leg.followOn
        if (second == null || !isTurn(second)) return if (hasThen) withoutThen(text) else text
        val direction = LandmarkInstructions.directionText(second.direction)
        if (!isTurn(first) || first.distance > MAX_GAP || direction == null) return if (hasThen) withoutThen(text) else text
        if (hasThen) return text
        var base = text.trim()
        val period = base.endsWith(".")
        if (period) base = base.dropLast(1)
        return "$base, dann $direction abbiegen" + if (period) "." else ""
    }

    fun isTurn(step: Step) = (step.type == ManeuverType.TURN || step.type == ManeuverType.END_OF_ROAD) && step.direction in TURN_DIRECTIONS

    fun withoutThen(text: String): String {
        val period = text.trim().endsWith(".")
        val cut = text.replace(THEN_TAIL, "")
        return cut + if (period && !cut.endsWith(".")) "." else ""
    }
}

/** Abseits der Autobahn gleich die nächste Abbiegung: „In 800 Metern rechts auf Hafenstraße abbiegen“ */
object ContinueInstructions {
    private val pattern = Regex("""^\s*(einen|einem|[0-9]+(?:[.,][0-9]+)?) (Meter|Metern|Kilometer|Kilometern) weiter (der Route folgen|auf [^,.]+)""", RegexOption.IGNORE_CASE)
    private val lowerFirst = setOf("Rechts", "Links", "Leicht", "Scharf", "Wenden", "An", "Am", "Auf", "Geradeaus", "Bei", "Im", "Nach", "Die", "Den", "Der")

    fun apply(text: String, leg: LegState): String {
        val onMotorway = leg.current.onMotorway || Regex("""auf der [AE] ?\d+""").containsMatchIn(text)
        val next = leg.upcoming ?: return text
        if (onMotorway || next.type == ManeuverType.ARRIVE) return text
        val maneuver = leg.current.voice.minByOrNull { it.distanceAlongStep }?.text ?: return text
        return rewrite(text, maneuver) ?: text
    }

    fun rewrite(text: String, maneuver: String): String? {
        val m = pattern.find(text) ?: return null
        var turn = maneuver.trim()
        if (turn.lowercase().startsWith("in ") || turn.lowercase().contains("weiter der route")) return null
        THEN_TAIL.find(turn)?.let { turn = turn.substring(0, it.range.first) + "." }
        val first = turn.split(" ").firstOrNull()
        if (first != null && first in lowerFirst) turn = first.lowercase() + turn.drop(first.length)
        val amount = m.groupValues[1].lowercase()
        val km = m.groupValues[2].lowercase().startsWith("kilo")
        val distance = if (amount == "einen" || amount == "einem") (if (km) "In einem Kilometer" else "In einem Meter")
        else "In $amount " + if (km) "Kilometern" else "Metern"
        return "$distance $turn"
    }
}

/** Autobahn: „rechts auf die Auffahrt A 42 Richtung Dortmund fahren“, „7 Kilometer weiter auf der A 42 fahren“ */
object MotorwayPhrases {
    fun apply(text: String, leg: LegState) = followRoad(onRamp(text, leg), leg)

    fun onRamp(text: String, leg: LegState): String {
        val next = leg.upcoming ?: return text
        if (!text.contains("Auffahrt", true) || text.contains("Ausfahrt", true)) return text
        val code = RoadNames.preferredCode(next.destinationCodes) ?: Regex("""\b[AE] ?\d+\b""").find(text)?.value ?: return text
        val side = when (next.direction) {
            Direction.RIGHT, Direction.SLIGHT_RIGHT, Direction.SHARP_RIGHT -> "rechts"
            Direction.LEFT, Direction.SLIGHT_LEFT, Direction.SHARP_LEFT -> "links"
            else -> null
        }
        return phrase(text, side, code, MotorwayDirection.joinFragments(next.destinations))
    }

    fun phrase(original: String, side: String?, code: String, targets: List<String>): String {
        var head = original.trim()
        var tail = ""
        Regex("""[.,]\s+dann[\s,]""", RegexOption.IGNORE_CASE).find(head)?.let {
            tail = head.substring(it.range.first); head = head.substring(0, it.range.first)
        }
        val prefix = Regex("""^In [0-9.,]+ (Metern|Kilometern|Kilometer|Meter)""").find(head)?.value
        var core = listOfNotNull(side, "auf die Auffahrt", code).joinToString(" ")
        // Ein Ziel genügt, und nie die Autobahn selbst
        targets.firstOrNull { it.replace(" ", "") != code.replace(" ", "") }?.let { core += " Richtung $it" }
        core += " fahren"
        val sentence = prefix?.let { "$it $core" } ?: (core.take(1).uppercase() + core.drop(1))
        return sentence + tail.ifEmpty { "." }
    }

    fun followRoad(text: String, leg: LegState): String {
        if (!text.contains("der Route folgen", true)) return text
        val rampCode = RoadNames.preferredCode(leg.prior?.destinationCodes)?.takeIf { it.startsWith("A") || it.startsWith("E") }
        val code = RoadNames.preferredCode(leg.current.codes) ?: rampCode ?: return text
        if (!leg.current.onMotorway && code != rampCode) return text
        return text.replace(Regex("der Route folgen", RegexOption.IGNORE_CASE), "auf der $code fahren")
    }
}

/** Letzte Ansage an der Abbiegung: nur „Jetzt rechts abbiegen“ */
object FinalTurn {
    fun apply(text: String, instruction: Voice, leg: LegState): String {
        val spoken = leg.current.voice
        val d = instruction.distanceAlongStep
        val isLast = spoken.none { it.distanceAlongStep < d - 1 }
        val isFirst = spoken.none { it.distanceAlongStep > d + 1 }
        val next = leg.upcoming ?: return text
        if (!isTurn(next)) return text
        val direction = LandmarkInstructions.directionText(next.direction) ?: return text
        if (Regex("^In [0-9]").containsMatchIn(instruction.text) || !isLast) return text
        if (leg.current.type == ManeuverType.DEPART && isFirst) return text
        return short(direction, text)
    }

    fun isTurn(step: Step) = ThenInstructions.isTurn(step) || (step.type == ManeuverType.CONTINUE && step.direction in TURN_DIRECTIONS)

    fun short(direction: String, text: String): String {
        var tail = ""
        THEN_TAIL.find(text)?.let { m ->
            var then = m.value.trim(' ', ',', '.')
            if (then.lowercase().startsWith("dann")) then = "dann" + then.drop(4)
            then = then.replace("dann, ", "dann ")
            val first = then.drop(5).firstOrNull()
            if (first != null && first.isUpperCase()) then = "dann " + then.drop(5).take(1).lowercase() + then.drop(6)
            tail = ", $then"
        }
        return "Jetzt $direction abbiegen$tail."
    }
}

/** Autobahn: erste Ansage einer Ausfahrt erst bei 2 km statt bei 3 km */
object MotorwayTiming {
    const val FIRST_DISTANCE = 2000.0
    const val DEFER_ABOVE = 2400.0

    sealed interface Decision {
        data object Skip : Decision
        data class Later(val instruction: Voice) : Decision
    }

    fun decide(instruction: Voice, leg: LegState): Decision? {
        val next = leg.upcoming ?: return null
        if (instruction.distanceAlongStep <= DEFER_ABOVE || next.type == ManeuverType.ARRIVE || !leg.current.onMotorway) return null
        val range = Regex("""^In [0-9.,]+ (Kilometern|Kilometer)""").find(instruction.text) ?: return null
        if (leg.current.voice.any { it.distanceAlongStep >= 1600 && it.distanceAlongStep < DEFER_ABOVE }) return Decision.Skip
        return Decision.Later(Voice(FIRST_DISTANCE, instruction.text.replaceRange(range.range, "In 2 Kilometern")))
    }
}

/** Mehrere Ansagen zur selben Abbiegung: Straßenname nur in der ersten; mittlere entfällt auf kurzen Stücken */
object StepAnnouncements {
    const val SHORT_STEP = 1000.0
    const val LANDMARK_FIRST_DISTANCE = 1000.0

    data class Position(val first: Boolean, val last: Boolean)

    fun position(instruction: Voice, leg: LegState): Position {
        val d = instruction.distanceAlongStep
        val motorway = leg.current.onMotorway
        val first = leg.current.voice.none { it.distanceAlongStep > d + 1 && (!motorway || it.distanceAlongStep <= MotorwayTiming.DEFER_ABOVE) }
        val last = leg.current.voice.none { it.distanceAlongStep < d - 1 }
        return Position(first, last)
    }

    fun withoutStreet(text: String, name: String?, code: String?): String {
        var out = text
        val n = name?.takeIf { it.isNotEmpty() }?.let { Regex.escape(it) }
        val c = code?.takeIf { it.isNotEmpty() && !it.startsWith("A") && !it.startsWith("E") }?.let { Regex.escape(it) }
        val patterns = mutableListOf<String>()
        if (n != null && c != null) patterns += listOf(" auf $n,? $c", " auf $c,? $n")
        if (n != null) patterns += " auf $n"
        if (c != null) patterns += " auf $c"
        for (p in patterns) out = out.replace(Regex(p + """(?=[\s.,]|$)"""), "")
        return out
    }
}

/** An Autobahnkreuzen kein „Auf A 57 links halten“, wenn man auf derselben Autobahn bleibt */
object MotorwayContinuation {
    fun staysOnMotorway(leg: LegState): Boolean {
        val next = leg.upcoming ?: return false
        if (next.type !in setOf(ManeuverType.FORK, ManeuverType.CONTINUE, ManeuverType.USE_LANE, ManeuverType.NEW_NAME)) return false
        if (!leg.current.onMotorway || next.junctions.firstOrNull()?.motorway != true) return false
        val before = leg.current.codes.map { it.replace(" ", "") }.toSet()
        val after = next.codes.map { it.replace(" ", "") }.toSet()
        if (before.isNotEmpty() && after.isNotEmpty()) return before.intersect(after).isNotEmpty()
        val names = leg.current.names.toSet()
        return names.isNotEmpty() && names.intersect(next.names.toSet()).isNotEmpty()
    }
}

/** Richtung bei Autobahnwechseln und Ausfahrten – nur in der ersten Ansage, nur das erste Ziel */
object MotorwayDirection {
    const val MAX_DISTANCE = 3200.0
    private const val WORD = """[\p{Lu}0-9][\p{L}0-9\-]*"""
    private const val NAME = "$WORD(?: $WORD)*"
    private val directionTypes = setOf(ManeuverType.FORK, ManeuverType.OFF_RAMP, ManeuverType.ON_RAMP, ManeuverType.USE_LANE, ManeuverType.CONTINUE, ManeuverType.MERGE)

    fun add(text: String, leg: LegState, distanceAlongStep: Double): String? {
        if (leg.current.type == ManeuverType.DEPART || distanceAlongStep > MAX_DISTANCE) return null
        val next = leg.upcoming ?: return null
        if (next.type !in directionTypes || !leg.current.onMotorway) return null
        val spokenBefore = leg.current.voice.any { it.distanceAlongStep > distanceAlongStep + 1 && it.distanceAlongStep <= MotorwayTiming.DEFER_ABOVE }
        if (spokenBefore) return shortExit(withoutDirection(text))
        val first = joinFragments(next.destinations).firstOrNull() ?: return null
        val repaired = repairFragments(text)
        if (fold(repaired).contains(fold(first))) return repaired
        return insert("Richtung $first", repaired)
    }

    private fun fold(s: String) = Normalizer.normalize(s, Normalizer.Form.NFD).replace(Regex("\\p{M}"), "").lowercase()

    fun insert(direction: String, text: String): String {
        var head = text.trim()
        var tail = ""
        Regex("""[.,]\s+dann[\s,]""", RegexOption.IGNORE_CASE).find(head)?.let {
            tail = head.substring(it.range.first); head = head.substring(0, it.range.first)
        }
        val period = tail.isEmpty() && head.endsWith(".")
        if (period) head = head.dropLast(1)
        return head + ", " + direction + (if (period) "." else "") + tail
    }

    fun joinFragments(raw: List<String>): List<String> {
        val out = mutableListOf<String>()
        var city: String? = null
        for (part in raw.map { it.trim() }.filter { it.isNotEmpty() }) {
            val c = city
            if (part.startsWith("-") && c != null) {
                if (out.lastOrNull() == c) out.removeAt(out.lastIndex)
                out += c + part
            } else {
                out += part
                city = part
            }
        }
        return out
    }

    fun withoutDirection(text: String) = repairFragments(text).replace(Regex(",? (?:in )?Richtung $NAME(?:, $NAME)*"), "")

    fun shortExit(text: String) = text.replace(Regex("""Auf [AB] ?\d+(?:, [AE] ?\d+)? über die Ausfahrt (\S+) abfahren"""), "An der Ausfahrt $1 abfahren")

    fun firstTargetOnly(text: String) = repairFragments(text).replace(Regex("(Richtung $NAME)(?:, $NAME)+"), "$1")

    fun repairFragments(text: String): String {
        val regex = Regex("""(\p{L}[\p{L}\-]*)((?:,\s*-\p{L}+)+)""")
        var result = text
        for (m in regex.findAll(text).toList().reversed()) {
            val parts = m.groupValues[2].split(",").map { it.trim() }
            result = result.replaceRange(m.range, joinFragments(listOf(m.groupValues[1]) + parts).joinToString(", "))
        }
        return result
    }
}

/** Nur den Straßennamen ansagen, nicht zusätzlich die Nummer; Autobahnen mit A-, nie mit E-Nummer */
object RoadNames {
    fun dropCodes(text: String, leg: LegState): String {
        var result = text
        for (step in listOfNotNull(leg.upcoming, leg.current)) {
            if (step.names.none { it.isNotBlank() } || step.codes.isEmpty() || step.onMotorway) continue
            for (code in step.codes) result = remove(code, result)
        }
        return result
    }

    fun preferredCode(codes: List<String>?): String? {
        val list = codes.orEmpty().filter { it.isNotBlank() }
        return list.firstOrNull(::isNational) ?: list.firstOrNull()
    }

    fun isNational(code: String) = Regex("""^A ?\d+""").containsMatchIn(code)

    fun dropEuropeanCodes(text: String, leg: LegState): String {
        val known = listOfNotNull(leg.prior, leg.current, leg.upcoming, leg.followOn).flatMap { it.codes + it.destinationCodes }.filter(::isNational)
        return dropEuropeanCodes(text, known)
    }

    fun dropEuropeanCodes(text: String, national: List<String>): String {
        val eCodes = Regex("""\bE ?\d+\b""").findAll(text).map { it.value }.toList()
        if (eCodes.isEmpty()) return text
        var out = text
        if (!Regex("""\bA ?\d+\b""").containsMatchIn(text)) {
            val known = national.map { it.replace(" ", "") }.toSet()
            if (known.size != 1) return text
            val digits = Regex("""\d+""").find(known.first())?.value ?: return text
            out = out.replaceFirst(eCodes[0], "A $digits")
            for (e in eCodes.drop(1)) out = remove(e, out)
            return out
        }
        for (e in eCodes) out = remove(e, out)
        return out
    }

    /** Nummer samt Trennzeichen entfernen: „Name/L 91“, „L 91/Name“, „Name (L 91)“, „Name, L 91“ */
    fun remove(code: String, text: String): String {
        val parts = code.split(" ").filter { it.isNotEmpty() }.map { Regex.escape(it) }
        if (parts.isEmpty()) return text
        val token = "\\b" + parts.joinToString("\\s?") + "\\b"
        var out = text
        for (p in listOf("\\s*\\(\\s*$token\\s*\\)", "\\s*[/,;]\\s*$token", "$token\\s*[/,;]\\s*")) out = out.replace(Regex(p), "")
        return out
    }
}

/**
 * Ablauf wie MeeterzSpeechSynthesizer.speak auf iOS: entscheidet je Mapbox-Ansage, ob sie entfällt, später kommt
 * oder mit welchem Text sie gesprochen wird.
 */
class Announcer {
    sealed interface Result {
        data class Skip(val reason: String) : Result
        data class Defer(val instruction: Voice) : Result
        data class Speak(val text: String) : Result
    }

    /** Abbiegung, deren erste Ansage schon „Am Ende der Straße …“ / „An der Ampel …“ war */
    private var landmarkAnnounced: String? = null

    fun process(instruction: Voice, leg: LegState, deferred: Boolean = false): Result {
        if (MotorwayContinuation.staysOnMotorway(leg)) return Result.Skip("bleibt auf der Autobahn")
        if (!deferred) when (val d = MotorwayTiming.decide(instruction, leg)) {
            MotorwayTiming.Decision.Skip -> return Result.Skip("Autobahn, erst ab 2 km")
            is MotorwayTiming.Decision.Later -> return Result.Defer(d.instruction)
            null -> Unit
        }
        val position = StepAnnouncements.position(instruction, leg)
        val key = leg.upcoming?.let { "${leg.stepIndex}|${it.maneuverLat},${it.maneuverLng}" }
        if (!position.first && !position.last && (leg.current.distance < StepAnnouncements.SHORT_STEP || (key != null && key == landmarkAnnounced))) {
            return Result.Skip("schon angekündigt")
        }
        val landmark = LandmarkInstructions.rewrite(instruction, leg,
            if (position.first) StepAnnouncements.LANDMARK_FIRST_DISTANCE else 800.0)
        if (landmark != null && position.first && !position.last) landmarkAnnounced = key
        var text = landmark ?: instruction.text
        text = MotorwayPhrases.apply(text, leg)
        text = ContinueInstructions.apply(text, leg)
        MotorwayDirection.add(text, leg, instruction.distanceAlongStep)?.let { text = it }
        text = MotorwayDirection.firstTargetOnly(text)
        text = RoadNames.dropCodes(text, leg)
        text = RoadNames.dropEuropeanCodes(text, leg)
        text = ThenInstructions.apply(text, leg)
        if (!position.first) leg.upcoming?.let { text = StepAnnouncements.withoutStreet(text, it.names.firstOrNull(), it.codes.firstOrNull()) }
        text = FinalTurn.apply(text, instruction, leg)
        return Result.Speak(text)
    }
}
