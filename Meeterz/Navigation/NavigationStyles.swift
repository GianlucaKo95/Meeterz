import Foundation
import UIKit
import MapboxMaps
import MapboxNavigationUIKit

/// Navigationsdarstellung mit Satellitenbild (Mapbox Standard Satellite)
final class SatelliteDayStyle: StandardDayStyle {
    required init() {
        super.init()
        mapStyleURL = URL(string: StyleURI.standardSatellite.rawValue)!
        previewMapStyleURL = mapStyleURL
        styleType = .day
    }
}

final class SatelliteNightStyle: StandardNightStyle {
    required init() {
        super.init()
        mapStyleURL = URL(string: StyleURI.standardSatellite.rawValue)!
        previewMapStyleURL = mapStyleURL
        styleType = .night
    }
}

enum NavigationStyles {
    /// iPhone: folgt dem Umschalter auf der Karte
    static func phone() -> [MapboxNavigationUIKit.Style] {
        styles(satellite: UserDefaults.standard.object(forKey: "map.satellite") as? Bool ?? true)
    }

    /// CarPlay: wird nur in den iPhone-Einstellungen festgelegt
    static func carPlay() -> [MapboxNavigationUIKit.Style] {
        styles(satellite: UserDefaults.standard.object(forKey: "carplay.satellite") as? Bool ?? true)
    }

    private static func styles(satellite: Bool) -> [MapboxNavigationUIKit.Style] {
        satellite
            ? [SatelliteNightStyle(), SatelliteDayStyle()]
            : [StandardNightStyle(), StandardDayStyle()]
    }
}
