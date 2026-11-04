import Foundation
import CoreLocation
import MapboxDirections
import MapboxNavigationCore

/// Ansagen wie bei Apple Karten: „An der nächsten Ampel rechts abbiegen“, „Am zweiten Stoppschild links abbiegen“.
///
/// Mapbox liefert mit der Route je Kreuzung, ob dort eine Ampel oder ein Stoppschild steht. Liegt die Abbiegung an
/// einer Ampel (bzw. einem Stoppschild), zählen wir die Ampeln bis dorthin und formulieren die Ansage damit.
/// Nur für echte Abbiegungen, bis zur dritten Ampel und innerhalb von 800 m – sonst bleibt Mapbox' Ansage.
/// Die letzte Ansage direkt vor der Kreuzung („Jetzt rechts abbiegen“) bleibt unverändert.
/// Ohne Ampel/Stoppschild, wenn die Straße an der Abbiegung endet: „Am Ende der Straße rechts abbiegen“.
enum LandmarkInstructions {
    enum Landmark { case trafficLight, stopSign }

    /// Neue Ansage oder nil (dann Mapbox' Text)
    static func rewrite(_ instruction: SpokenInstruction, legProgress: RouteLegProgress, maxDistance: Double = 800) -> String? {
        // Die Formulierung („An der nächsten Ampel …“) gibt es bisher nur auf Deutsch – sonst bleibt Mapbox' Ansage
        guard VoiceCatalog.language == "de" else { return nil }
        let stepProgress = legProgress.currentStepProgress
        guard let upcoming = legProgress.upcomingStep,
              [.turn, .reachEnd].contains(upcoming.maneuverType),
              let direction = directionText(upcoming.maneuverDirection),
              instruction.distanceAlongStep > 60,                         // nicht die „Jetzt …“-Ansage
              stepProgress.distanceRemaining < maxDistance,
              !instruction.text.localizedCaseInsensitiveContains("ampel") else { return nil }

        // Kreuzungen vom aktuellen Standort bis einschließlich der Abbiegung
        let all = stepProgress.intersectionsIncludingUpcomingManeuverIntersection
            ?? ((legProgress.currentStep.intersections ?? []) + (upcoming.intersections?.prefix(1).map { $0 } ?? []))
        guard let maneuver = all.last else { return nil }
        let ahead = Array(all.dropLast().dropFirst(min(stepProgress.intersectionIndex + 1, max(all.count - 1, 0))))

        // Mapbox setzt die Ampel/das Stoppschild meist nicht an die Abbiegekreuzung selbst, sondern an den Knoten
        // davor (Haltelinie, OSM-Ampel an der Zufahrt) – Probe vom 28.10.: Abbiegekreuzung nie markiert, der Knoten
        // 15–44 m davor schon. Deshalb zählt alles bis 50 m vor der Abbiegung als „an der Abbiegung“.
        //
        // Aber: Steht die Ampel an einer eigenen Einmündung und die Abbiegung kommt erst 20–50 m dahinter, wäre
        // „An der Ampel rechts“ falsch – man böge eine Straße zu früh ab. Dann heißt es „Direkt nach der Ampel …“.
        func mark(_ x: Intersection) -> Landmark? {
            x.trafficSignal == true ? .trafficLight : (x.stopSign == true ? .stopSign : nil)
        }
        var found: Landmark? = mark(maneuver)
        var afterIt = false
        if found == nil, let index = ahead.lastIndex(where: { mark($0) != nil && meters($0.location, maneuver.location) <= junctionRadius }) {
            let node = ahead[index]
            found = mark(node)
            let between = ahead[(index + 1)...]
            let isJunction: (Intersection) -> Bool = { $0.headings.count >= 3 }
            afterIt = meters(node.location, maneuver.location) > sameJunction
                && (isJunction(node) || between.contains { isJunction($0) && meters($0.location, maneuver.location) > sameJunction })
        }
        let landmark: Landmark
        if let found { landmark = found }
        else {
            // Keine Ampel, kein Stoppschild, aber die Straße endet an der Abbiegung: „Am Ende der Straße rechts abbiegen“
            guard [.left, .right, .sharpLeft, .sharpRight].contains(upcoming.maneuverDirection),
                  roadEnds(at: maneuver), !instruction.text.localizedCaseInsensitiveContains("Ende") else { return nil }
            let road = upcoming.names?.first.flatMap { $0.isEmpty ? nil : $0 }
            return "Am Ende der Straße \(direction) abbiegen" + (road.map { " auf \($0)" } ?? "")
        }

        // Ampeln davor zählen – mehrere markierte Knoten derselben Kreuzung (≤ 50 m auseinander) als eine
        var before = 0
        var last: CLLocationCoordinate2D?
        for x in ahead where meters(x.location, maneuver.location) > junctionRadius {
            let marked = landmark == .trafficLight ? x.trafficSignal == true : x.stopSign == true
            guard marked else { continue }
            if let last, meters(last, x.location) <= junctionRadius { continue }
            before += 1
            last = x.location
        }
        let road = upcoming.names?.first.flatMap { $0.isEmpty ? nil : $0 }
        if afterIt {
            // Nur bei der nächsten Ampel eindeutig – sonst Mapbox' Ansage
            guard before == 0 else { return nil }
            let place = landmark == .trafficLight ? "Direkt nach der Ampel" : "Direkt nach dem Stoppschild"
            return "\(place) \(direction) abbiegen" + (road.map { " auf \($0)" } ?? "")
        }
        return phrase(landmark: landmark, ordinal: before + 1, direction: direction, road: road)
    }

    static let junctionRadius: CLLocationDistance = 50
    /// Bis hierhin gehören zwei Knoten zur selben Kreuzung (z. B. getrennte Fahrbahnen)
    static let sameJunction: CLLocationDistance = 20

    static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    /// Endet die Straße an dieser Kreuzung? Ja, wenn keine Straße in Fahrtrichtung weitergeht (höchstens 35° Abweichung)
    /// – typisch für T-Kreuzungen, an denen man links oder rechts muss.
    static func roadEnds(at intersection: Intersection) -> Bool {
        guard let approach = intersection.approachIndex, intersection.headings.indices.contains(approach) else { return false }
        let travel = (intersection.headings[approach] + 180).truncatingRemainder(dividingBy: 360)
        for (index, heading) in intersection.headings.enumerated() where index != approach {
            var diff = abs(heading - travel).truncatingRemainder(dividingBy: 360)
            if diff > 180 { diff = 360 - diff }
            if diff <= 35 { return false }
        }
        return intersection.headings.count >= 2
    }

    /// „An der nächsten Ampel rechts abbiegen auf Hauptstraße“
    static func phrase(landmark: Landmark, ordinal: Int, direction: String, road: String?) -> String? {
        let ordinals = ["nächsten", "zweiten", "dritten"]
        guard (1...3).contains(ordinal) else { return nil }
        let place: String
        switch landmark {
        case .trafficLight: place = "An der \(ordinals[ordinal - 1]) Ampel"
        case .stopSign: place = "Am \(ordinals[ordinal - 1]) Stoppschild"
        }
        return "\(place) \(direction) abbiegen" + (road.map { " auf \($0)" } ?? "")
    }

    static func directionText(_ direction: ManeuverDirection?) -> String? {
        switch direction {
        case .left: "links"
        case .right: "rechts"
        case .slightLeft: "leicht links"
        case .slightRight: "leicht rechts"
        case .sharpLeft: "scharf links"
        case .sharpRight: "scharf rechts"
        default: nil
        }
    }
}

/// Zwei Abbiegungen direkt hintereinander: „Jetzt rechts abbiegen, dann links abbiegen“ – aber nur, wenn die zweite
/// wirklich sofort folgt (die Straße dazwischen höchstens 80 m lang). Mapbox hängt „dann …“ teils auch bei größerem
/// Abstand an; das fällt dann weg, damit „dann“ immer „gleich danach“ bedeutet. Bisher nur auf Deutsch.
enum ThenInstructions {
    static let maxGap: Double = 80

    static func apply(to text: String, legProgress: RouteLegProgress) -> String {
        guard VoiceCatalog.language == "de", let first = legProgress.upcomingStep else { return text }
        // Abfahrtsansage („Auf Waldstraße Richtung Westen fahren. Dann links abbiegen …“): Hier beschreibt der erste
        // Satz das Losfahren und „Dann …“ schon die erste Abbiegung – nicht die zweite. Nicht anfassen (29.10.: sonst
        // fiel die erste Abbiegung weg).
        if legProgress.currentStep.maneuverType == .depart { return text }
        let hasThen = text.range(of: #"[,.]?\s+dann[\s,]"#, options: [.regularExpression, .caseInsensitive]) != nil
        // Nur der erste Satz – „Dann rechts halten auf A 42“ war zu viel (04.11.). Die Seite des Ziels
        // („Dann befindet sich das Ziel auf der rechten Seite“) bleibt.
        if legProgress.followOnStep?.maneuverType == .arrive { return text }
        guard let second = legProgress.followOnStep, isTurn(second) else { return hasThen ? withoutThen(text) : text }
        guard isTurn(first), first.distance <= maxGap,
              let direction = LandmarkInstructions.directionText(second.maneuverDirection) else {
            return hasThen ? withoutThen(text) : text
        }
        if hasThen { return text }   // Mapbox sagt es schon
        var base = text.trimmingCharacters(in: .whitespaces)
        let period = base.hasSuffix(".")
        if period { base.removeLast() }
        return base + ", dann \(direction) abbiegen" + (period ? "." : "")
    }

    static func isTurn(_ step: RouteStep) -> Bool {
        [.turn, .reachEnd].contains(step.maneuverType)
            && [.left, .right, .sharpLeft, .sharpRight].contains(step.maneuverDirection)
    }

    /// „Rechts abbiegen, dann links abbiegen.“ → „Rechts abbiegen.“
    static func withoutThen(_ text: String) -> String {
        let period = text.trimmingCharacters(in: .whitespaces).hasSuffix(".")
        let cut = text.replacingOccurrences(of: #"[,.]?\s+dann[\s,].*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return cut + (period && !cut.hasSuffix(".") ? "." : "")
    }
}

/// Abseits der Autobahn gleich die nächste Abbiegung ansagen: „In 800 Metern rechts auf Hafenstraße abbiegen“
/// statt „800 Meter weiter der Route folgen“ bzw. „Einen Kilometer weiter auf L 140, dann rechts abbiegen“.
/// „… weiter fahren“ bleibt nur auf der Autobahn (längere Strecken ohne Abbiegung).
enum ContinueInstructions {
    static func apply(to text: String, legProgress: RouteLegProgress) -> String {
        let current = legProgress.currentStep
        let onMotorway = (current.intersections ?? []).contains { $0.outletRoadClasses?.contains(.motorway) == true }
            || text.range(of: #"auf der [AE] ?\d+"#, options: .regularExpression) != nil
        guard !onMotorway, let next = legProgress.upcomingStep, next.maneuverType != .arrive,
              let maneuver = current.instructionsSpokenAlongStep?.min(by: { $0.distanceAlongStep < $1.distanceAlongStep })?.text
        else { return text }
        return rewrite(text, maneuver: maneuver) ?? text
    }

    /// Reiner Text-Teil (testbar): „800 Meter weiter der Route folgen.“ + „Rechts abbiegen.“ → „In 800 Metern rechts abbiegen.“
    static func rewrite(_ text: String, maneuver: String) -> String? {
        let pattern = #"^\s*(einen|einem|[0-9]+(?:[.,][0-9]+)?) (Meter|Metern|Kilometer|Kilometern) weiter (der Route folgen|auf [^,.]+)"#
        guard let match = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
                .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let amountRange = Range(match.range(at: 1), in: text), let unitRange = Range(match.range(at: 2), in: text)
        else { return nil }
        var turn = maneuver.trimmingCharacters(in: .whitespaces)
        // Die Abbiegeansage selbst darf keine Entfernung tragen und muss eine Abbiegung sein
        guard !turn.lowercased().hasPrefix("in "), !turn.lowercased().contains("weiter der route") else { return nil }
        // „Dann …“ gehört zur Ansage kurz vor der Abbiegung, nicht schon Kilometer vorher (04.11.: „In 8 Kilometern
        // rechts auf Ruhrorter Straße abbiegen. Dann Rechts abbiegen.“)
        if let r = turn.range(of: #"[.,]?\s+dann[\s,].*$"#, options: [.regularExpression, .caseInsensitive]) {
            turn = String(turn[..<r.lowerBound]) + "."
        }
        if let first = turn.split(separator: " ").first,
           ["Rechts", "Links", "Leicht", "Scharf", "Wenden", "An", "Am", "Auf", "Geradeaus", "Bei", "Im", "Nach", "Die", "Den", "Der"].contains(String(first)) {
            turn = first.lowercased() + turn.dropFirst(first.count)
        }
        let amount = text[amountRange].lowercased()
        let km = text[unitRange].lowercased().hasPrefix("kilo")
        let distance: String
        if amount == "einen" || amount == "einem" { distance = km ? "In einem Kilometer" : "In einem Meter" }
        else { distance = "In \(amount) " + (km ? "Kilometern" : "Metern") }
        return distance + " " + turn
    }
}

/// Autobahn-Formulierungen (bisher nur Deutsch):
/// - Auffahrt: „In 500 Metern rechts auf die Auffahrt A 42 Richtung Dortmund fahren“
///   statt „In 500 Metern Auf die Auffahrt nach rechts auf A 42 abfahren“
/// - Weiterfahren: „7 Kilometer weiter auf der A 42 fahren“ statt „7 Kilometer weiter der Route folgen“
enum MotorwayPhrases {
    static func apply(to text: String, legProgress: RouteLegProgress) -> String {
        guard VoiceCatalog.language == "de" else { return text }
        return followRoad(onRamp(text, legProgress: legProgress), legProgress: legProgress)
    }

    static func onRamp(_ text: String, legProgress: RouteLegProgress) -> String {
        guard let next = legProgress.upcomingStep,
              text.range(of: "Auffahrt", options: .caseInsensitive) != nil,
              text.range(of: "Ausfahrt", options: .caseInsensitive) == nil else { return text }
        let code = RoadNames.preferredCode(next.destinationCodes)
            ?? firstMatch(#"\b[AE] ?\d+\b"#, in: text)
        guard let code else { return text }
        let side: String?
        switch next.maneuverDirection {
        case .right, .slightRight, .sharpRight: side = "rechts"
        case .left, .slightLeft, .sharpLeft: side = "links"
        default: side = nil
        }
        let targets = MotorwayDirection.joinFragments(next.destinations ?? [])
        return phrase(original: text, side: side, code: code, targets: targets)
    }

    /// Satz bauen; ein angehängtes „Dann …“ von Mapbox bleibt erhalten
    static func phrase(original text: String, side: String?, code: String, targets: [String]) -> String {
        var head = text.trimmingCharacters(in: .whitespaces)
        var tail = ""
        if let range = head.range(of: #"[.,]\s+dann[\s,]"#, options: [.regularExpression, .caseInsensitive]) {
            tail = String(head[range.lowerBound...])
            head = String(head[..<range.lowerBound])
        }
        let prefix = firstMatch(#"^In [0-9.,]+ (Metern|Kilometern|Kilometer|Meter)"#, in: head)
        var core = [side, "auf die Auffahrt", code].compactMap { $0 }.joined(separator: " ")
        // Ein Ziel genügt, und nie die Autobahn selbst („Auffahrt A 40 Richtung A 40“, 04.11.)
        if let target = targets.first(where: { $0.replacingOccurrences(of: " ", with: "") != code.replacingOccurrences(of: " ", with: "") }) {
            core += " Richtung " + target
        }
        core += " fahren"
        let sentence = prefix.map { "\($0) \(core)" } ?? core.prefix(1).uppercased() + core.dropFirst()
        return sentence + (tail.isEmpty ? "." : tail)
    }

    /// „7 Kilometer weiter der Route folgen.“ → „7 Kilometer weiter auf der A 42 fahren.“ (nur auf der Autobahn)
    static func followRoad(_ text: String, legProgress: RouteLegProgress) -> String {
        let current = legProgress.currentStep
        guard text.range(of: "der Route folgen", options: .caseInsensitive) != nil else { return text }
        // Direkt nach der Auffahrt trägt der Schritt oft noch keine Straßennummer (03.11.: „7 Kilometer weiter der
        // Route folgen“ auf der A 42) – dann die Nummer, die die Auffahrt angekündigt hat
        let rampCode = RoadNames.preferredCode(legProgress.priorStep?.destinationCodes).flatMap { $0.hasPrefix("A") || $0.hasPrefix("E") ? $0 : nil }
        let onMotorway = (current.intersections ?? []).contains(where: { $0.outletRoadClasses?.contains(.motorway) == true })
        guard let code = RoadNames.preferredCode(current.codes) ?? rampCode,
              onMotorway || code == rampCode else { return text }
        return text.replacingOccurrences(of: "der Route folgen", with: "auf der \(code) fahren", options: .caseInsensitive)
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[range])
    }
}


/// Letzte Ansage einer Abbiegung (an der Kreuzung selbst): nur kurz „Jetzt rechts abbiegen“ – auch an Ampeln oder am
/// Ende der Straße; die ausführliche Ansage kam schon vorher. Eine direkt folgende zweite Abbiegung bleibt dran
/// („Jetzt rechts abbiegen, dann links abbiegen“).
enum FinalTurn {
    /// Die letzte Ansage eines Abschnitts ist die an der Abbiegung. Ihr Abstand hängt bei Mapbox vom Tempo ab
    /// (89–190 m), eine feste Grenze von 150 m ließ sie außerorts durchrutschen (04.11.).
    static func apply(to text: String, instruction: SpokenInstruction, legProgress: RouteLegProgress) -> String {
        let spoken = legProgress.currentStep.instructionsSpokenAlongStep ?? []
        let d = instruction.distanceAlongStep
        // Abstände mit 1 m Spielraum vergleichen: Mapbox reicht sie über die Navigator-Bibliothek durch, ein exakter
        // Vergleich traf nur manchmal (04.11.: „Rechts auf Friedensstraße abbiegen.“ blieb lang)
        let isLast = !spoken.contains { $0.distanceAlongStep < d - 1 }
        let isFirst = !spoken.contains { $0.distanceAlongStep > d + 1 }
        guard VoiceCatalog.language == "de",
              let next = legProgress.upcomingStep, isTurn(next),
              let direction = LandmarkInstructions.directionText(next.maneuverDirection),
              instruction.text.range(of: #"^In [0-9]"#, options: .regularExpression) == nil,
              isLast,
              // Losfahren („Auf X Richtung Norden fahren. Dann rechts abbiegen“) ist keine Abbiegeansage – auch nicht
              // nach einer Neuberechnung, die jedes Mal mit einem Losfahr-Abschnitt beginnt (04.11.: dort fehlte „Jetzt“)
              !(legProgress.currentStep.maneuverType == .depart && isFirst && spoken.count > 1) else { return text }
        return short(direction: direction, from: text)
    }

    /// Abbiegen, auch „Am Ende der Straße …“ und „Rechts abbiegen, um auf … zu bleiben“
    static func isTurn(_ step: RouteStep) -> Bool {
        ThenInstructions.isTurn(step)
            || (step.maneuverType == .continue && [.left, .right, .sharpLeft, .sharpRight].contains(step.maneuverDirection))
    }

    /// „Jetzt rechts abbiegen“ + ggf. „, dann links abbiegen“ aus dem bisherigen Text
    static func short(direction: String, from text: String) -> String {
        var tail = ""
        if let r = text.range(of: #"[,.]?\s+dann[\s,].*$"#, options: [.regularExpression, .caseInsensitive]) {
            var then = String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: " ,."))
            if then.lowercased().hasPrefix("dann") { then = "dann" + then.dropFirst(4) }
            then = then.replacingOccurrences(of: "dann, ", with: "dann ")
            if let first = then.dropFirst(5).first, first.isUppercase {
                // „dann Links abbiegen“ → „dann links abbiegen“
                then = "dann " + then.dropFirst(5).prefix(1).lowercased() + then.dropFirst(6)
            }
            tail = ", " + then
        }
        return "Jetzt \(direction) abbiegen\(tail)."
    }
}

/// Autobahn: Die erste Ansage einer Ausfahrt oder eines Wechsels erst bei 2 km statt bei 3 km
enum MotorwayTiming {
    static let firstDistance: Double = 2000
    /// Ansagen weiter vorher werden auf 2 km verschoben oder ausgelassen
    static let deferAbove: Double = 2400

    enum Decision {
        /// Ansage weglassen (es kommt ohnehin eine um 2 km)
        case skip
        /// Später bei 2 km sagen
        case later(SpokenInstruction)
    }

    static func decide(_ instruction: SpokenInstruction, legProgress: RouteLegProgress) -> Decision? {
        let current = legProgress.currentStep
        guard VoiceCatalog.language == "de", instruction.distanceAlongStep > deferAbove,
              let next = legProgress.upcomingStep, next.maneuverType != .arrive,
              (current.intersections ?? []).contains(where: { $0.outletRoadClasses?.contains(.motorway) == true }),
              let range = instruction.text.range(of: #"^In [0-9.,]+ (Kilometern|Kilometer)"#, options: .regularExpression)
        else { return nil }
        if current.instructionsSpokenAlongStep?.contains(where: { $0.distanceAlongStep >= 1600 && $0.distanceAlongStep < deferAbove }) == true {
            return .skip
        }
        let text = instruction.text.replacingCharacters(in: range, with: "In 2 Kilometern")
        return .later(SpokenInstruction(distanceAlongStep: firstDistance, text: text, ssmlText: "<speak>\(text)</speak>"))
    }
}

/// Mehrere Ansagen zur selben Abbiegung: Straßenname nur in der ersten, und steht dort schon „An der Ampel“ /
/// „Am Ende der Straße“, entfällt die mittlere „In 400 Metern …“ (04.11.: drei Ansagen für eine Abbiegung).
enum StepAnnouncements {
    /// Erste bzw. letzte Ansage dieses Abschnitts (1 m Spielraum, Ansagen über 2,4 km zählen auf der Autobahn nicht)
    static func position(of instruction: SpokenInstruction, in legProgress: RouteLegProgress) -> (first: Bool, last: Bool) {
        let spoken = legProgress.currentStep.instructionsSpokenAlongStep ?? []
        let d = instruction.distanceAlongStep
        let onMotorway = (legProgress.currentStep.intersections ?? []).contains { $0.outletRoadClasses?.contains(.motorway) == true }
        let first = !spoken.contains { $0.distanceAlongStep > d + 1 && (!onMotorway || $0.distanceAlongStep <= MotorwayTiming.deferAbove) }
        let last = !spoken.contains { $0.distanceAlongStep < d - 1 }
        return (first, last)
    }

    /// Bis zu dieser Entfernung darf schon die erste Ansage „Am Ende der Straße …“ / „An der Ampel …“ lauten
    static let landmarkFirstDistance: Double = 1000

    /// „Rechts auf Friedensstraße abbiegen.“ → „Rechts abbiegen.“ (Name und Nummer der Zielstraße weg)
    static func withoutStreet(_ text: String, name: String?, code: String?) -> String {
        var out = text
        let n = name.flatMap { $0.isEmpty ? nil : NSRegularExpression.escapedPattern(for: $0) }
        // Autobahnnummern bleiben – „auf A 42“ ist dort die eigentliche Information
        let c = code.flatMap { $0.isEmpty || $0.hasPrefix("A") || $0.hasPrefix("E") ? nil : NSRegularExpression.escapedPattern(for: $0) }
        var patterns: [String] = []
        if let n, let c { patterns += [" auf \(n),? \(c)", " auf \(c),? \(n)"] }
        if let n { patterns.append(" auf \(n)") }
        if let c { patterns.append(" auf \(c)") }
        for p in patterns {
            out = out.replacingOccurrences(of: p + #"(?=[\s.,]|$)"#, with: "", options: .regularExpression)
        }
        return out
    }
}
