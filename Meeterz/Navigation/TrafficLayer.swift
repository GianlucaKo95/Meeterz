import UIKit
import MapboxMaps
import ObjectiveC

/// Verkehrslage auf allen Karten wie bei Apple Karten: stockender Verkehr orange, Stau rot, Stillstand dunkelrot –
/// auch in der freien Fahrt, in „Klassisch“ und „Satellit“. Freie Straßen bleiben ungefärbt.
/// Quelle: Mapbox Traffic v1 (live, im Mapbox-Kontingent enthalten). Android: TrafficLayer.kt.
@MainActor
enum TrafficLayer {
    static let sourceId = "meeterz-traffic"
    static let layerId = "meeterz-traffic"
    static let url = "mapbox://mapbox.mapbox-traffic-v1"

    static let moderate = UIColor(red: 1.0, green: 0.62, blue: 0.04, alpha: 1)   // stockend
    static let heavy = UIColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1)      // Stau
    static let severe = UIColor(red: 0.70, green: 0.10, blue: 0.10, alpha: 1)    // Stillstand

    static var filter: Exp { Exp(.match) { Exp(.get) { "congestion" }; ["moderate", "heavy", "severe"]; true; false } }
    static var color: Exp {
        Exp(.match) { Exp(.get) { "congestion" }; "moderate"; moderate; "heavy"; heavy; "severe"; severe; UIColor.clear }
    }
    /// Etwa Straßenbreite: weit draußen dünn, nah dran breit
    static var width: Exp {
        Exp(.interpolate) { Exp(.exponential) { 1.5 }; Exp(.zoom); 8; 1.0; 12; 2.5; 16; 6.0; 19; 14.0 }
    }

    private static var key: UInt8 = 0
    private final class Helper { var token: Cancelable? }

    /// Für MapViews (Navigation, CarPlay, Dashboard): Ebene anlegen und nach jedem Stilwechsel (Tag/Nacht) neu
    static func install(on mapView: MapView) {
        guard objc_getAssociatedObject(mapView, &key) == nil, let map = mapView.mapboxMap else { return }
        let helper = Helper()
        objc_setAssociatedObject(mapView, &key, helper, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        helper.token = map.onStyleLoaded.observe { [weak map] _ in
            MainActor.assumeIsolated { if let map { add(to: map) } }
        }
        if map.isStyleLoaded { add(to: map) }
    }

    private static func add(to map: MapboxMap) {
        do {
            if !map.sourceExists(withId: sourceId) {
                var source = VectorSource(id: sourceId)
                source.url = url
                try map.addSource(source)
            }
            guard !map.layerExists(withId: layerId) else { return }
            var layer = LineLayer(id: layerId, source: sourceId)
            layer.sourceLayer = "traffic"
            layer.filter = filter
            layer.lineColor = .expression(color)
            layer.lineWidth = .expression(width)
            layer.lineOpacity = .constant(0.9)
            layer.lineCap = .constant(.round)
            layer.lineJoin = .constant(.round)
            layer.lineEmissiveStrength = .constant(1)   // nachts nicht abgedunkelt
            layer.slot = .middle
            // Unter die eigene Routenlinie, falls sie schon da ist (die zeigt den Verkehr auf der Route selbst)
            if let route = map.allLayerIdentifiers.map(\.id).first(where: { $0.hasPrefix("com.mapbox.navigation") && $0.contains("route") }) {
                try map.addLayer(layer, layerPosition: .below(route))
            } else {
                try map.addLayer(layer)
            }
        } catch {
            Diag.log("Verkehrsebene konnte nicht hinzugefügt werden: \(error)")
        }
    }
}
