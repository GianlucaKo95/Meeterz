import Foundation
import CoreLocation
import Observation
import Supabase

/// Routen der Freunde laden und die eigene aktive Route teilen.
@MainActor @Observable
final class RoutesStore {
    private(set) var friendRoutes: [UUID: FriendRoute] = [:]

    private var client: SupabaseClient { Backend.client }

    private struct Row: Decodable {
        let friend_id: UUID
        let destination_name: String?
        let dest_lat: Double
        let dest_lng: Double
        let eta: Date
        let path_geojson: String
    }

    private struct GeoJSONLine: Decodable {
        let coordinates: [[Double]]
    }

    func refresh() async {
        do {
            let rows: [Row] = try await client.rpc("friends_routes").execute().value
            var next: [UUID: FriendRoute] = [:]
            for r in rows {
                guard let data = r.path_geojson.data(using: .utf8),
                      let line = try? JSONDecoder().decode(GeoJSONLine.self, from: data)
                else { continue }
                let coords = line.coordinates.compactMap { c -> CLLocationCoordinate2D? in
                    c.count >= 2 ? CLLocationCoordinate2D(latitude: c[1], longitude: c[0]) : nil
                }
                next[r.friend_id] = FriendRoute(
                    friendId: r.friend_id,
                    destinationName: r.destination_name,
                    destination: .init(latitude: r.dest_lat, longitude: r.dest_lng),
                    eta: r.eta,
                    coordinates: coords
                )
            }
            friendRoutes = next
        } catch {
            // Netzfehler: alte Routen behalten, nächster Versuch in 30 s
        }
    }

    /// points: [[lng, lat, eta_unix]]
    func shareMine(destinationName: String?, destination: CLLocationCoordinate2D, eta: Date, points: [[Double]],
                   mode: TravelMode = .car) async {
        guard points.count >= 2 else { return }
        struct Params: Encodable {
            let destination_name: String?
            let dest_lat: Double
            let dest_lng: Double
            let eta_unix: Double
            let points: [[Double]]
            var travel_mode: String?
        }
        var params = Params(
            destination_name: destinationName,
            dest_lat: destination.latitude,
            dest_lng: destination.longitude,
            eta_unix: eta.timeIntervalSince1970,
            points: points,
            travel_mode: mode.rawValue
        )
        do {
            try await client.rpc("set_active_route", params: params).execute()
        } catch {
            // Datenbank kennt die Fortbewegungsart noch nicht: ohne sie teilen, damit die Route trotzdem ankommt
            params.travel_mode = nil
            _ = try? await client.rpc("set_active_route", params: params).execute()
        }
    }

    func clearMine() async {
        _ = try? await client.rpc("clear_active_route").execute()
    }
}
