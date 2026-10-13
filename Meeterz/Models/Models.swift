import Foundation
import CoreLocation

struct Profile: Codable, Equatable {
    let id: UUID
    var handle: String
    var displayName: String
    var sharingEnabled: Bool
    /// nil = unbegrenzt
    var sharingUntil: Date?

    enum CodingKeys: String, CodingKey {
        case id, handle
        case displayName = "display_name"
        case sharingEnabled = "sharing_enabled"
        case sharingUntil = "sharing_until"
    }

    var isSharingNow: Bool {
        sharingEnabled && (sharingUntil.map { $0 > Date() } ?? true)
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

    var initials: String {
        displayName.split(separator: " ").prefix(2)
            .compactMap(\.first).map(String.init).joined().uppercased()
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

/// Aktive Route eines Freundes (RPC `friends_routes()`)
struct FriendRoute: Identifiable, Equatable {
    let friendId: UUID
    let destinationName: String?
    let destination: CLLocationCoordinate2D
    let eta: Date
    let coordinates: [CLLocationCoordinate2D]

    var id: UUID { friendId }

    static func == (a: FriendRoute, b: FriendRoute) -> Bool {
        a.friendId == b.friendId && a.eta == b.eta && a.coordinates.count == b.coordinates.count
    }
}

/// Möglicher Treffpunkt (RPC `find_meetups()`)
struct MeetupCandidate: Codable, Identifiable, Equatable {
    let friendId: UUID
    let lat: Double
    let lng: Double
    let myEta: Date
    let friendEta: Date
    let distanceM: Double

    var id: UUID { friendId }
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
    /// Wer wartet wie lange am Treffpunkt (positiv: ich warte)
    var waitSeconds: TimeInterval { friendEta.timeIntervalSince(myEta) }

    enum CodingKeys: String, CodingKey {
        case friendId = "friend_id"
        case lat, lng
        case myEta = "my_eta"
        case friendEta = "friend_eta"
        case distanceM = "distance_m"
    }
}

/// Treffen-Vorschlag (RPC `my_meetups()`)
struct Meetup: Codable, Identifiable, Equatable {
    let id: UUID
    let otherId: UUID
    let otherName: String
    let incoming: Bool
    let placeName: String
    let lat: Double
    let lng: Double
    let status: String
    let createdAt: Date

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
    var isPending: Bool { status == "pending" }
    var isAccepted: Bool { status == "accepted" }
    var place: Place { Place(id: id.uuidString, name: placeName, address: nil, coordinate: coordinate) }

    enum CodingKeys: String, CodingKey {
        case id
        case otherId = "other_id"
        case otherName = "other_name"
        case incoming
        case placeName = "place_name"
        case lat, lng, status
        case createdAt = "created_at"
    }
}

/// Ort aus der Mapbox-Suche
struct Place: Identifiable, Hashable {
    let id: String
    let name: String
    let address: String?
    let coordinate: CLLocationCoordinate2D

    static func == (a: Place, b: Place) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension CLLocationCoordinate2D {
    func distance(to other: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude))
    }
}
