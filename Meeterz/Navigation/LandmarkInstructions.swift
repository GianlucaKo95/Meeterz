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
    static func rewrite(_ instruction: SpokenInstruction, legProgress: RouteLegProgress) -> String? {
        // Die Formulierung („An der nächsten Ampel …“) gibt es bisher nur auf Deutsch – sonst bleibt Mapbox' Ansage
        guard VoiceCatalog.language == "de" else { return nil }
        let stepProgress = legProgress.currentStepProgress
        guard let upcoming = legProgress.upcomingStep,
              [.turn, .reachEnd].contains(upcoming.maneuverType),
              let direction = directionText(upcoming.maneuverDirection),
              instruction.distanceAlongStep > 60,                         // nicht die „Jetzt …“-Ansage
              stepProgress.distanceRemaining < 800,
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
        let hasThen = text.range(of: #"[,.]?\s+dann\s"#, options: [.regularExpression, .caseInsensitive]) != nil
        guard let second = legProgress.followOnStep, isTurn(second) else { return text }   // z. B. „dann Ziel erreicht“ bleibt
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
        let cut = text.replacingOccurrences(of: #"[,.]?\s+dann\s.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return cut + (period && !cut.hasSuffix(".") ? "." : "")
    }
}

/// Autobahn-Formulierungen (bisher nur Deutsch):
/// - Auffahrt: „In 500 Metern rechts auf die Auffahrt A 42 Richtung Dortmund fahren“
///   statt „In 500 Metern Auf die Auffahrt nach rechts auf A 42 abfahren“
/// - Weiterfahren: „7 Kilometer weiter der A 42 folgen“ statt „7 Kilometer weiter der Route folgen“
enum MotorwayPhrases {
    static func apply(to text: String, legProgress: RouteLegProgress) -> String {
        guard VoiceCatalog.language == "de" else { return text }
        return followRoad(onRamp(text, legProgress: legProgress), legProgress: legProgress)
    }

    static func onRamp(_ text: String, legProgress: RouteLegProgress) -> String {
        guard let next = legProgress.upcomingStep,
              text.range(of: "Auffahrt", options: .caseInsensitive) != nil,
              text.range(of: "Ausfahrt", options: .caseInsensitive) == nil else { return text }
        let code = next.destinationCodes?.first.flatMap { $0.isEmpty ? nil : $0 }
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
        if let range = head.range(of: #"[.,]\s+dann\s"#, options: [.regularExpression, .caseInsensitive]) {
            tail = String(head[range.lowerBound...])
            head = String(head[..<range.lowerBound])
        }
        let prefix = firstMatch(#"^In [0-9.,]+ (Metern|Kilometern|Kilometer|Meter)"#, in: head)
        var core = [side, "auf die Auffahrt", code].compactMap { $0 }.joined(separator: " ")
        if !targets.isEmpty { core += " Richtung " + targets.prefix(2).joined(separator: ", ") }
        core += " fahren"
        let sentence = prefix.map { "\($0) \(core)" } ?? core.prefix(1).uppercased() + core.dropFirst()
        return sentence + (tail.isEmpty ? "." : tail)
    }

    /// „7 Kilometer weiter der Route folgen.“ → „7 Kilometer weiter der A 42 folgen.“ (nur auf der Autobahn)
    static func followRoad(_ text: String, legProgress: RouteLegProgress) -> String {
        let current = legProgress.currentStep
        guard text.range(of: "der Route folgen", options: .caseInsensitive) != nil,
              (current.intersections ?? []).contains(where: { $0.outletRoadClasses?.contains(.motorway) == true }),
              let code = current.codes?.first, !code.isEmpty else { return text }
        return text.replacingOccurrences(of: "der Route folgen", with: "der \(code) folgen", options: .caseInsensitive)
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[range])
    }
}
