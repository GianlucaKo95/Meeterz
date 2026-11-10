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

    /// Stützpunkte ab der aktuellen Position als [[lng, lat, eta_unix]]: mindestens alle `spacing` Meter (für die
    /// Ankunftszeiten) und zusätzlich jede Ecke, an der die Strecke mehr als `tolerance` Meter von der geraden
    /// Linie abweicht – vorher nur alle 300 m, die Route der Freunde schnitt dann quer durch Häuser (10.11.).
    /// Die Restzeit wird auf die aktuelle Prognose (inkl. Verkehr) skaliert.
    static func sharePoints(
        route: Route,
        distanceTraveled: CLLocationDistance,
        durationRemaining: TimeInterval,
        now: Date = Date(),
        spacing: CLLocationDistance = 300
    ) -> [[Double]] {
        sharePoints(samples: samples(of: route), distanceTraveled: distanceTraveled, durationRemaining: durationRemaining,
                    now: now, spacing: spacing)
    }

    /// Server nimmt höchstens 10 000 Punkte (set_active_route)
    static let maxPoints = 9_000

    static func sharePoints(
        samples all: [Sample],
        distanceTraveled: CLLocationDistance,
        durationRemaining: TimeInterval,
        now: Date = Date(),
        spacing: CLLocationDistance = 300,
        tolerance: CLLocationDistance = 5
    ) -> [[Double]] {
        guard let last = all.last, all.count >= 2 else { return [] }

        let baseTime = interpolatedTime(at: distanceTraveled, in: all)
        let rawRemaining = last.time - baseTime
        let factor = rawRemaining > 1 ? durationRemaining / rawRemaining : 1

        let ahead = all.filter { $0.distance >= distanceTraveled }
        guard ahead.count >= 2 else { return [] }
        var keep = corners(ahead, tolerance: tolerance)
        var nextMark = distanceTraveled
        for (i, s) in ahead.enumerated() where s.distance >= nextMark {
            keep.insert(i)
            nextMark = s.distance + spacing
        }
        keep.insert(ahead.count - 1)
        // Sehr lange Route: Ecken gröber nehmen, bis es passt
        if keep.count > maxPoints, tolerance < 200 {
            return sharePoints(samples: all, distanceTraveled: distanceTraveled, durationRemaining: durationRemaining,
                               now: now, spacing: spacing, tolerance: tolerance * 2)
        }
        return keep.sorted().map { i in
            let s = ahead[i]
            let eta = now.addingTimeInterval((s.time - baseTime) * factor)
            return [s.coordinate.longitude, s.coordinate.latitude, eta.timeIntervalSince1970]
        }
    }

    /// Ramer-Douglas-Peucker: Indizes der Punkte, ohne die die Linie um mehr als `tolerance` abwiche
    static func corners(_ s: [Sample], tolerance: CLLocationDistance) -> Set<Int> {
        guard s.count > 2 else { return Set(s.indices) }
        var keep: Set<Int> = [0, s.count - 1]
        var stack = [(0, s.count - 1)]
        // Örtliche Ebene in Metern (für die kurzen Abstände genau genug)
        let lat0 = s[0].coordinate.latitude * .pi / 180
        func xy(_ c: CLLocationCoordinate2D) -> (Double, Double) {
            (c.longitude * 111_320 * cos(lat0), c.latitude * 110_540)
        }
        let pts = s.map { xy($0.coordinate) }
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            let (ax, ay) = pts[a], (bx, by) = pts[b]
            let dx = bx - ax, dy = by - ay
            let len2 = dx * dx + dy * dy
            var worst = 0.0, worstIndex = a
            for i in (a + 1)..<b {
                let (px, py) = pts[i]
                let t = len2 > 0 ? max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / len2)) : 0
                let ex = ax + t * dx - px, ey = ay + t * dy - py
                let d = (ex * ex + ey * ey).squareRoot()
                if d > worst { worst = d; worstIndex = i }
            }
            if worst > tolerance {
                keep.insert(worstIndex)
                stack.append((a, worstIndex))
                stack.append((worstIndex, b))
            }
        }
        return keep
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
