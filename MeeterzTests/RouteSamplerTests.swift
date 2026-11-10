import XCTest
import CoreLocation
@testable import Meeterz

final class RouteSamplerTests: XCTestCase {
    private func sample(_ lat: Double, _ lng: Double, _ d: Double, _ t: Double) -> RouteSampler.Sample {
        .init(coordinate: .init(latitude: lat, longitude: lng), distance: d, time: t)
    }

    /// Eine Ecke zwischen zwei 300-m-Marken muss erhalten bleiben, sonst schneidet die Linie quer durchs Viertel
    func testKeepsCorners() {
        // 200 m nach Norden, dann 200 m nach Osten (Ecke bei 200 m)
        let s = [sample(51.4000, 6.7000, 0, 0), sample(51.4009, 6.7000, 100, 10), sample(51.4018, 6.7000, 200, 20),
                 sample(51.4018, 6.7014, 300, 30), sample(51.4018, 6.7029, 400, 40)]
        let pts = RouteSampler.sharePoints(samples: s, distanceTraveled: 0, durationRemaining: 40,
                                           now: Date(timeIntervalSince1970: 1000))
        XCTAssertTrue(pts.contains { abs($0[1] - 51.4018) < 1e-6 && abs($0[0] - 6.7000) < 1e-6 }, "\(pts)")
        // Gerade Stücke werden ausgedünnt
        XCTAssertFalse(pts.contains { abs($0[1] - 51.4009) < 1e-6 })
        XCTAssertEqual(pts.last?[2] ?? 0, 1040, accuracy: 0.5)
    }
}
