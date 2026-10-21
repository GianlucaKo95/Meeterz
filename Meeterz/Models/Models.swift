import Foundation
import CoreLocation

struct Profile: Codable, Equatable {
    let id: UUID
    var handle: String
    var displayName: String
    var sharingEnabled: Bool
    /// nil = unbegrenzt
    var sharingUntil: Date?
    /// 0/nil = kein Profilbild; wird bei jedem neuen Bild erhöht
    var avatarVersion: Int?
    /// Inkognito bis zu diesem Zeitpunkt (nil = aus). Sehr weit in der Zukunft = bis zum Ausschalten.
    var incognitoUntil: Date?
    /// Eigene Routen für Freunde dauerhaft verbergen
    var hideRoutes: Bool?

    enum CodingKeys: String, CodingKey {
        case id, handle
        case incognitoUntil = "incognito_until"
        case hideRoutes = "hide_routes"
        case avatarVersion = "avatar_version"
        case displayName = "display_name"
        case sharingEnabled = "sharing_enabled"
        case sharingUntil = "sharing_until"
    }

    var isIncognito: Bool { incognitoUntil.map { $0 > Date() } ?? false }

    /// Inkognito ohne Ende (bis der Nutzer es ausschaltet)
    var isIncognitoIndefinitely: Bool {
        incognitoUntil.map { $0 > Date().addingTimeInterval(10 * 365 * 86400) } ?? false
    }

    var routesHidden: Bool { hideRoutes ?? false }

    var isSharingNow: Bool {
        sharingEnabled && (sharingUntil.map { $0 > Date() } ?? true) && !isIncognito
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
    let avatarVersion: Int?

    var id: UUID { friendId }
    var isAccepted: Bool { status == "accepted" }

    enum CodingKeys: String, CodingKey {
        case friendshipId = "friendship_id"
        case friendId = "friend_id"
        case handle
        case displayName = "display_name"
        case status, incoming, lat, lng, heading, speed
        case locationUpdatedAt = "location_updated_at"
        case avatarVersion = "avatar_version"
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
    /// Fortbewegungsart des Freundes (fehlt bei älterer Datenbank → Auto)
    var friendModeRaw: String? = nil

    var friendMode: TravelMode { friendModeRaw.flatMap(TravelMode.init(rawValue:)) ?? .car }
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
        case friendModeRaw = "friend_mode"
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
    /// Gruppen-Treffen: gemeinsame ID aller Einladungen und Zahl der Beteiligten (inkl. Einladendem)
    var groupId: UUID? = nil
    var groupSize: Int? = nil

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
    var isGroup: Bool { groupId != nil }
    /// „mit Lisa“ bzw. „mit Lisa und 2 weiteren“
    var withText: String {
        let others = max(0, (groupSize ?? 2) - 2)
        return others == 0 ? otherName : "\(otherName) und \(others) weiteren"
    }
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
        case groupId = "group_id"
        case groupSize = "group_size"
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
