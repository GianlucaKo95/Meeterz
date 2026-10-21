import Foundation
import CoreLocation
import Observation

/// Zuletzt angefahrene Ziele (nur auf dem Gerät, je Konto getrennt) – für die Zielliste auf CarPlay.
@MainActor @Observable
final class RecentsStore {
    struct Entry: Codable, Identifiable, Hashable {
        var id = UUID()
        var name: String
        var address: String?
        var lat: Double
        var lng: Double
        var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lng) }
    }

    private(set) var items: [Entry] = []
    @ObservationIgnored private var userId: UUID?
    private let limit = 8

    func load(userId: UUID) {
        self.userId = userId
        guard let data = UserDefaults.standard.data(forKey: key(userId)),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { items = []; return }
        items = list
    }

    func reset() { items = []; userId = nil }

    /// Neustes Ziel nach oben; derselbe Ort (≈ 50 m) wird nicht doppelt geführt.
    func record(_ place: Place) {
        guard userId != nil else { return }
        items.removeAll { $0.coordinate.distance(to: place.coordinate) < 50 }
        items.insert(Entry(name: place.name, address: place.address, lat: place.coordinate.latitude, lng: place.coordinate.longitude), at: 0)
        if items.count > limit { items.removeLast(items.count - limit) }
        guard let userId, let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key(userId))
    }

    private func key(_ id: UUID) -> String { "recents.\(id.uuidString.lowercased())" }
}
