import Foundation
import CoreLocation

struct Profile: Codable, Equatable {
    let id: UUID
    var handle: String
    var displayName: String
    var sharingEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case id, handle
        case displayName = "display_name"
        case sharingEnabled = "sharing_enabled"
    }
}

/// Zeile aus RPC `my_friends()`
struct FriendRow: Codable, Identifiable, Equatable {
    let friendshipId: UUID
    let friendId: UUID
    let handle: String
    let displayName: String
    let status: String
    let incoming: Bool
    let lat: Double?
    let lng: Double?
    let heading: Double?
    let speed: Double?
    let locationUpdatedAt: Date?

    var id: UUID { friendId }
    var isAccepted: Bool { status == "accepted" }

    enum CodingKeys: String, CodingKey {
        case friendshipId = "friendship_id"
        case friendId = "friend_id"
        case handle
        case displayName = "display_name"
        case status, incoming, lat, lng, heading, speed
        case locationUpdatedAt = "location_updated_at"
    }

    var lastKnown: LivePosition? {
        guard let lat, let lng, let locationUpdatedAt else { return nil }
        return LivePosition(userId: friendId, lat: lat, lng: lng,
                            heading: heading, speed: speed,
                            ts: locationUpdatedAt.timeIntervalSince1970)
    }
}

/// Payload der Realtime-Broadcasts (und Seed aus last_locations)
struct LivePosition: Codable, Equatable {
    let userId: UUID
    let lat: Double
    let lng: Double
    let heading: Double?
    let speed: Double?
    let ts: TimeInterval

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
    var date: Date { Date(timeIntervalSince1970: ts) }
    var age: TimeInterval { Date().timeIntervalSince(date) }
}
