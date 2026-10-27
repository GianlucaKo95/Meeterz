import Foundation

/// Telemetrie an Mapbox (anonymisierte Standort- und Nutzungsdaten zur Verbesserung der Karten).
/// Standardmäßig **aus** (Einwilligung nötig, Mapbox nutzt die Daten für eigene Zwecke); einschaltbar in den
/// Einstellungen. Ein Schalter von Mapbox (`MGLMapboxMetricsEnabled`) steuert Karte und Navigation gemeinsam.
enum MapboxTelemetry {
    private static let choiceKey = "mapbox.telemetry.optIn"
    /// Mapbox' eigener Schalter (Maps SDK, wirkt über MapboxCommon auch für die Navigation)
    private static let mapboxKey = "MGLMapboxMetricsEnabled"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: choiceKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: choiceKey)
            UserDefaults.standard.set(newValue, forKey: mapboxKey)
        }
    }

    /// Beim Start, bevor Karte oder Navigation entstehen: gespeicherte Wahl (Standard aus) ausdrücklich setzen.
    /// Ausdrücklich statt nur als Standardwert – Mapbox registriert selbst „an“ als Standard.
    static func apply() {
        UserDefaults.standard.set(enabled, forKey: mapboxKey)
    }
}
