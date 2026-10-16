import UIKit
import MapboxMaps
import ObjectiveC

/// 3D-Gebäude auf dem Satellitenbild. Der Standard-Kartenstil bringt sie selbst mit,
/// der Satellitenstil nicht – deshalb legen wir eine Gebäudeebene aus Mapbox Streets darüber.
/// Wird für Navigation (iPhone und CarPlay) benutzt; die Hauptkarte macht es deklarativ in MainView.
@MainActor
final class Satellite3DBuildings {
    private static var key: UInt8 = 0
    private static let sourceId = "meeterz-streets-3d"
    private static let layerId = "meeterz-3d-buildings"

    private var cancelables: [Cancelable] = []

    /// Hängt die Ebene an die Karte, falls Satellit aktiv ist. Überlebt Stilwechsel (Tag/Nacht).
    static func install(on mapView: MapView, satellite: Bool) {
        guard satellite else { return }
        if objc_getAssociatedObject(mapView, &key) != nil { return }
        guard let map = mapView.mapboxMap else { return }
        let helper = Satellite3DBuildings()
        objc_setAssociatedObject(mapView, &key, helper, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        helper.cancelables.append(map.onStyleLoaded.observe { [weak map] _ in
            guard let map else { return }
            Satellite3DBuildings.addLayer(to: map)
        })
        if map.isStyleLoaded { addLayer(to: map) }
    }

    private static func addLayer(to map: MapboxMap) {
        do {
            if !map.sourceExists(withId: sourceId) {
                var source = VectorSource(id: sourceId)
                source.url = "mapbox://mapbox.mapbox-streets-v8"
                try map.addSource(source)
            }
            if !map.layerExists(withId: layerId) {
                var layer = FillExtrusionLayer(id: layerId, source: sourceId)
                layer.sourceLayer = "building"
                layer.filter = Exp(.eq) { Exp(.get) { "extrude" }; "true" }
                layer.minZoom = 14.5
                layer.fillExtrusionColor = .constant(StyleColor(UIColor(red: 0.93, green: 0.91, blue: 0.87, alpha: 1)))
                layer.fillExtrusionOpacity = .constant(0.94)
                // Helle, eigenleuchtende Fassaden mit weichem Verlauf statt dunkler Lichtstimmung des Nachtstils
                layer.fillExtrusionEmissiveStrength = .constant(0.65)
                layer.fillExtrusionVerticalGradient = .constant(true)
                layer.fillExtrusionAmbientOcclusionIntensity = .constant(0.25)
                layer.fillExtrusionHeight = .expression(Exp(.get) { "height" })
                layer.fillExtrusionBase = .expression(Exp(.get) { "min_height" })
                layer.slot = .middle
                try map.addLayer(layer)
            }
        } catch {
            NSLog("Meeterz: 3D-Gebäude konnten nicht hinzugefügt werden: \(error)")
        }
    }
}
