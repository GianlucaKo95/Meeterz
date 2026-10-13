import Foundation
import CoreLocation
import MapboxDirections

/// Wandelt eine Mapbox-Route in Stützpunkte mit Ankunftszeit um (für die Treffpunkt-Suche).
enum RouteSampler {
    struct Sample {
        let coordinate: CLLocationCoordinate2D
        let distance: CLLocationDistance   // ab Routenstart
        let time: TimeInterval             // ab Routenstart, laut Route
    }

    /// Alle Koordinaten der Route mit kumulierter Distanz und Fahrzeit.
    /// Die Fahrzeit eines Schritts wird anteilig zur Strecke auf seine Koordinaten verteilt.
    static func samples(of route: Route) -> [Sample] {
        var result: [Sample] = []
        var dist: CLLocationDistance = 0
        var time: TimeInterval = 0

        for leg in route.legs {
            for step in leg.steps {
                guard let coords = step.shape?.coordinates, !coords.isEmpty else {
                    time += step.expectedTravelTime
                    continue
                }
                var segments: [CLLocationDistance] = []
                if coords.count > 1 {
                    for i in 1..<coords.count {
                        segments.append(coords[i - 1].distance(to: coords[i]))
                    }
                }
                let stepLength = max(segments.reduce(0, +), 0.1)

                if result.isEmpty {
                    result.append(Sample(coordinate: coords[0], distance: 0, time: 0))
                }
                for (i, seg) in segments.enumerated() {
                    dist += seg
                    time += step.expectedTravelTime * seg / stepLength
                    result.append(Sample(coordinate: coords[i + 1], distance: dist, time: time))
                }
                if segments.isEmpty { time += step.expectedTravelTime }
            }
        }
        return result
    }

    /// Stützpunkte ab der aktuellen Position, ca. alle `spacing` Meter, als [[lng, lat, eta_unix]].
    /// Die Restzeit wird auf die aktuelle Prognose (inkl. Verkehr) skaliert.
    static func sharePoints(
        route: Route,
        distanceTraveled: CLLocationDistance,
        durationRemaining: TimeInterval,
        now: Date = Date(),
        spacing: CLLocationDistance = 300
    ) -> [[Double]] {
        let all = samples(of: route)
        guard let last = all.last, all.count >= 2 else { return [] }

        let baseTime = interpolatedTime(at: distanceTraveled, in: all)
        let rawRemaining = last.time - baseTime
        let factor = rawRemaining > 1 ? durationRemaining / rawRemaining : 1

        var points: [[Double]] = []
        var nextMark = distanceTraveled
        for s in all where s.distance >= distanceTraveled {
            if s.distance >= nextMark || s.distance == last.distance {
                let eta = now.addingTimeInterval((s.time - baseTime) * factor)
                points.append([s.coordinate.longitude, s.coordinate.latitude, eta.timeIntervalSince1970])
                nextMark = s.distance + spacing
            }
        }
        return points
    }

    private static func interpolatedTime(at distance: CLLocationDistance, in samples: [Sample]) -> TimeInterval {
        guard let idx = samples.firstIndex(where: { $0.distance >= distance }) else { return samples.last?.time ?? 0 }
        guard idx > 0 else { return samples[0].time }
        let a = samples[idx - 1], b = samples[idx]
        let span = b.distance - a.distance
        let t = span > 0 ? (distance - a.distance) / span : 0
        return a.time + (b.time - a.time) * t
    }
}
