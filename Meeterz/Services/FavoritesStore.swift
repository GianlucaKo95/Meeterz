import Foundation
import CoreLocation
import Observation

/// Ein gespeicherter Ort: Zuhause, Arbeit oder ein eigener Favorit mit Namen.
struct Favorite: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case home, work, other }

    var id = UUID()
    var kind: Kind
    var label: String
    var address: String?
    var lat: Double
    var lng: Double

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lng) }
    var place: Place { Place(id: "fav-\(id.uuidString)", name: label, address: address, coordinate: coordinate) }

    var symbol: String {
        switch kind {
        case .home: "house.fill"
        case .work: "briefcase.fill"
        case .other: "star.fill"
        }
    }
}

/// Favoriten liegen nur auf dem Gerät (je Konto getrennt) – Adressen wie „Zuhause“ gehen nicht an den Server.
@MainActor @Observable
final class FavoritesStore {
    private(set) var items: [Favorite] = []
    @ObservationIgnored private var userId: UUID?

    var home: Favorite? { items.first { $0.kind == .home } }
    var work: Favorite? { items.first { $0.kind == .work } }
    var others: [Favorite] { items.filter { $0.kind == .other } }

    func load(userId: UUID) {
        self.userId = userId
        guard let data = UserDefaults.standard.data(forKey: key(userId)),
              let list = try? JSONDecoder().decode([Favorite].self, from: data) else { items = []; return }
        items = list
        MeeterzShortcuts.updateAppShortcutParameters()
    }

    func reset() {
        items = []
        userId = nil
    }

    /// Zuhause und Arbeit gibt es nur einmal (wird ersetzt), eigene Favoriten kommen dazu.
    func save(kind: Favorite.Kind, label: String, place: Place) {
        let fav = Favorite(kind: kind, label: label, address: place.address ?? place.name,
                           lat: place.coordinate.latitude, lng: place.coordinate.longitude)
        if kind != .other { items.removeAll { $0.kind == kind } }
        items.append(fav)
        persist()
    }

    func rename(_ id: UUID, to label: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].label = label
        persist()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    /// Ist an dieser Stelle (≈ 30 m) schon etwas gespeichert?
    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        items.contains { $0.coordinate.distance(to: coordinate) < 30 }
    }

    private func key(_ id: UUID) -> String { "favorites.\(id.uuidString.lowercased())" }

    private func persist() {
        guard let userId, let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key(userId))
        MeeterzShortcuts.updateAppShortcutParameters()   // Siri: „Mit Meeterz nach Zuhause“
        CarPlayDashboard.shared.updateShortcuts()
    }
}
