import Foundation
import CoreLocation

/// Sucht für eine Gruppe einen Treffpunkt, der für alle ähnlich schnell erreichbar ist.
///
/// Vorgehen: Orte (Café, Essen, …) rund um die Mitte aller Teilnehmer suchen, dann mit der Mapbox Matrix API
/// die Fahrzeit jedes Teilnehmers zu jedem Ort holen (je Fortbewegungsart eine Anfrage) und die Orte nach
/// der längsten Anfahrt sortieren – fair heißt: niemand muss viel weiter als die anderen.
enum FairMeetupFinder {
    struct Participant: Identifiable, Hashable {
        let id: UUID
        let name: String
        let coordinate: CLLocationCoordinate2D
        var mode: TravelMode

        static func == (a: Participant, b: Participant) -> Bool { a.id == b.id && a.mode == b.mode }
        func hash(into hasher: inout Hasher) { hasher.combine(id); hasher.combine(mode) }
    }

    struct Option: Identifiable {
        let place: Place
        /// Sekunden je Teilnehmer-ID
        let durations: [UUID: TimeInterval]
        var id: String { place.id }
        var longest: TimeInterval { durations.values.max() ?? 0 }
        var spread: TimeInterval { longest - (durations.values.min() ?? 0) }
    }

    enum FinderError: LocalizedError {
        case tooFewPeople, nothingFound, failed
        var errorDescription: String? {
            switch self {
            case .tooFewPeople: "Wähle mindestens einen Freund mit sichtbarem Standort."
            case .nothingFound: "In der Mitte wurde kein passender Ort gefunden."
            case .failed: "Die Fahrzeiten konnten gerade nicht berechnet werden."
            }
        }
    }

    static func find(for people: [Participant]) async throws -> [Option] {
        guard people.count >= 2 else { throw FinderError.tooFewPeople }

        // Mitte aller Teilnehmer
        let center = CLLocationCoordinate2D(
            latitude: people.map(\.coordinate.latitude).reduce(0, +) / Double(people.count),
            longitude: people.map(\.coordinate.longitude).reduce(0, +) / Double(people.count))

        // Kandidaten: Raststätte/Tankstelle nur, wenn alle mit dem Auto kommen
        let allByCar = people.allSatisfy { $0.mode == .car }
        let categories: [SearchService.Category] = allByCar ? [.coffee, .restaurant, .restArea] : [.coffee, .restaurant, .park]
        var candidates: [Place] = []
        for category in categories {
            if let found = try? await SearchService.places(category, near: center, limit: 4) {
                for place in found where !candidates.contains(where: { $0.coordinate.distance(to: place.coordinate) < 40 }) {
                    candidates.append(place)
                }
            }
        }
        candidates = Array(candidates.sorted { $0.coordinate.distance(to: center) < $1.coordinate.distance(to: center) }.prefix(10))
        guard !candidates.isEmpty else { throw FinderError.nothingFound }

        // Fahrzeiten je Fortbewegungsart
        var durations: [UUID: [TimeInterval?]] = [:]
        for mode in Set(people.map(\.mode)) {
            let group = people.filter { $0.mode == mode }
            let matrix = try await Self.matrix(from: group.map(\.coordinate), to: candidates.map(\.coordinate), mode: mode)
            for (i, person) in group.enumerated() { durations[person.id] = matrix[i] }
        }

        // Nur Orte, die jeder erreichen kann; sortiert nach längster Anfahrt, dann nach Unterschied
        let options: [Option] = candidates.enumerated().compactMap { index, place in
            var perPerson: [UUID: TimeInterval] = [:]
            for person in people {
                guard let row = durations[person.id], index < row.count, let d = row[index] else { return nil }
                perPerson[person.id] = d
            }
            return Option(place: place, durations: perPerson)
        }
        guard !options.isEmpty else { throw FinderError.nothingFound }
        return Array(options.sorted { ($0.longest, $0.spread) < ($1.longest, $1.spread) }.prefix(3))
    }

    /// Mapbox Matrix API: Zeilen = Start, Spalten = Ziel (Sekunden, nil = nicht erreichbar)
    private static func matrix(from sources: [CLLocationCoordinate2D], to destinations: [CLLocationCoordinate2D],
                               mode: TravelMode) async throws -> [[TimeInterval?]] {
        let profile: String = switch mode {
        case .car: "mapbox/driving"
        case .bike: "mapbox/cycling"
        case .walk: "mapbox/walking"
        }
        let coords = (sources + destinations).map { "\($0.longitude),\($0.latitude)" }.joined(separator: ";")
        var comps = URLComponents(string: "https://api.mapbox.com/directions-matrix/v1/\(profile)/\(coords)")!
        comps.queryItems = [
            URLQueryItem(name: "sources", value: (0..<sources.count).map(String.init).joined(separator: ";")),
            URLQueryItem(name: "destinations", value: (sources.count..<(sources.count + destinations.count)).map(String.init).joined(separator: ";")),
            URLQueryItem(name: "annotations", value: "duration"),
            URLQueryItem(name: "access_token", value: AppConfig.mapboxToken),
        ]
        guard let url = comps.url else { throw FinderError.failed }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw FinderError.failed }
        struct Result: Decodable { let durations: [[Double?]]? }
        guard let rows = try JSONDecoder().decode(Result.self, from: data).durations else { throw FinderError.failed }
        return rows
    }
}
