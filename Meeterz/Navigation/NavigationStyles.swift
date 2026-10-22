import Foundation
import UIKit
import MapboxMaps
import MapboxNavigationUIKit

/// Navigationsdarstellung mit Satellitenbild (Mapbox Standard Satellite)
class SatelliteDayStyle: StandardDayStyle {
    required init() {
        super.init()
        mapStyleURL = URL(string: StyleURI.standardSatellite.rawValue)!
        previewMapStyleURL = mapStyleURL
        styleType = .day
    }
}

class SatelliteNightStyle: StandardNightStyle {
    required init() {
        super.init()
        mapStyleURL = URL(string: StyleURI.standardSatellite.rawValue)!
        previewMapStyleURL = mapStyleURL
        styleType = .night
    }
}

// MARK: iPhone-Navigation im Meeterz-Look (dunkel, Limettengrün) statt Mapbox-Blau

/// Banner, Knöpfe und Abbiegepfeile in den App-Farben; die Karte selbst bleibt (Satellit bzw. klassisch)
enum MeeterzNavigationLook {
    // Folgen der Einstellung „Darstellung“ (hell/dunkel) wie der Rest der App
    static let ink = Theme.UI.ink
    static let panel = Theme.dynamic(dark: 0x161B22, light: 0xFFFFFF, alpha: 0.97)
    static let stroke = Theme.UI.stroke
    static let text = Theme.UI.text
    static let muted = Theme.UI.muted
    static let accent = Theme.UI.accent

    static func apply() {
        for idiom in [UIUserInterfaceIdiom.phone, .pad] {
            let t = UITraitCollection(userInterfaceIdiom: idiom)
            for view in [TopBannerView.self, InstructionsBannerView.self, BottomBannerView.self,
                         BottomPaddingView.self, LanesView.self, NextBannerView.self, StepsBackgroundView.self] as [UIView.Type] {
                view.appearance(for: t).backgroundColor = panel
            }
            for container in [InstructionsBannerView.self, NextBannerView.self] as [UIView.Type] {
                ManeuverView.appearance(for: t, whenContainedInInstancesOf: [container]).primaryColor = accent
                ManeuverView.appearance(for: t, whenContainedInInstancesOf: [container]).secondaryColor = muted.withAlphaComponent(0.5)
            }
            DistanceLabel.appearance(for: t, whenContainedInInstancesOf: [InstructionsBannerView.self]).valueTextColor = text
            DistanceLabel.appearance(for: t, whenContainedInInstancesOf: [InstructionsBannerView.self]).unitTextColor = muted
            PrimaryLabel.appearance(for: t, whenContainedInInstancesOf: [InstructionsBannerView.self]).normalTextColor = text
            SecondaryLabel.appearance(for: t, whenContainedInInstancesOf: [InstructionsBannerView.self]).normalTextColor = muted
            ArrivalTimeLabel.appearance(for: t).normalTextColor = text
            DistanceRemainingLabel.appearance(for: t).normalTextColor = muted
            TimeRemainingLabel.appearance(for: t).normalTextColor = text
            TimeRemainingLabel.appearance(for: t).trafficUnknownColor = text
            FloatingButton.appearance(for: t).backgroundColor = panel
            FloatingButton.appearance(for: t).tintColor = accent
            FloatingButton.appearance(for: t).borderColor = stroke
            CancelButton.appearance(for: t).tintColor = text
            LaneView.appearance(for: t).primaryColor = accent
            LaneView.appearance(for: t).secondaryColor = muted.withAlphaComponent(0.45)
            WayNameView.appearance(for: t).borderColor = accent
        }
    }
}

final class MeeterzSatelliteDayStyle: SatelliteDayStyle {
    override func apply() { super.apply(); MeeterzNavigationLook.apply() }
}
final class MeeterzSatelliteNightStyle: SatelliteNightStyle {
    override func apply() { super.apply(); MeeterzNavigationLook.apply() }
}
final class MeeterzStandardDayStyle: StandardDayStyle {
    override func apply() { super.apply(); MeeterzNavigationLook.apply() }
}
final class MeeterzStandardNightStyle: StandardNightStyle {
    override func apply() { super.apply(); MeeterzNavigationLook.apply() }
}

enum NavigationStyles {
    /// iPhone: folgt dem Umschalter auf der Karte, Banner und Knöpfe im Meeterz-Look
    static func phone() -> [MapboxNavigationUIKit.Style] {
        (UserDefaults.standard.object(forKey: "map.satellite") as? Bool ?? true)
            ? [MeeterzSatelliteNightStyle(), MeeterzSatelliteDayStyle()]
            : [MeeterzStandardNightStyle(), MeeterzStandardDayStyle()]
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
