package de.koeven.meeterz.car

import com.mapbox.geojson.Feature
import com.mapbox.geojson.FeatureCollection
import com.mapbox.geojson.Point
import com.mapbox.maps.extension.androidauto.MapboxCarMapObserver
import com.mapbox.maps.extension.androidauto.MapboxCarMapSurface
import com.mapbox.maps.extension.style.expressions.generated.Expression.Companion.get
import com.mapbox.maps.extension.style.layers.addLayer
import com.mapbox.maps.extension.style.layers.generated.symbolLayer
import com.mapbox.maps.extension.style.sources.addSource
import com.mapbox.maps.extension.style.sources.generated.GeoJsonSource
import com.mapbox.maps.extension.style.sources.generated.geoJsonSource
import com.mapbox.maps.extension.style.sources.getSourceAs
import de.koeven.meeterz.nav.RightOfWaySigns
import de.koeven.meeterz.ui.RoadSigns
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

/**
 * „Vorfahrt achten“ / „Stopp“ auf der Auto-Karte am Knoten (CarPlay: unter dem Tempolimit). Android Auto erlaubt
 * keine eigenen Ansichten neben der Karte – darum steht das Schild direkt auf der Karte an der Kreuzung.
 */
class CarSignMarker : MapboxCarMapObserver {
    private var job: Job? = null

    override fun onAttached(mapboxCarMapSurface: MapboxCarMapSurface) {
        val map = mapboxCarMapSurface.mapSurface.mapboxMap
        job = CoroutineScope(SupervisorJob() + Dispatchers.Main).launch {
            RightOfWaySigns.sign.map { s -> s?.let { Triple(it.stop, it.lat, it.lng) } }.distinctUntilChanged().collect { s ->
                map.getStyle { style ->
                    if (!style.hasStyleImage(STOP)) style.addImage(STOP, RoadSigns.bitmap(true))
                    if (!style.hasStyleImage(YIELD)) style.addImage(YIELD, RoadSigns.bitmap(false))
                    val features = listOfNotNull(s?.let { (stop, lat, lng) ->
                        Feature.fromGeometry(Point.fromLngLat(lng, lat)).apply { addStringProperty("icon", if (stop) STOP else YIELD) }
                    })
                    val data = FeatureCollection.fromFeatures(features)
                    val existing = style.getSourceAs<GeoJsonSource>(SOURCE)
                    if (existing != null) existing.featureCollection(data)
                    else {
                        style.addSource(geoJsonSource(SOURCE) { featureCollection(data) })
                        style.addLayer(symbolLayer(LAYER, SOURCE) {
                            iconImage(get("icon")); iconSize(0.45); iconAllowOverlap(true); iconOffset(listOf(0.0, -60.0))
                        })
                    }
                }
            }
        }
    }

    override fun onDetached(mapboxCarMapSurface: MapboxCarMapSurface) {
        job?.cancel(); job = null
        mapboxCarMapSurface.mapSurface.mapboxMap.getStyle { style ->
            if (style.styleLayerExists(LAYER)) style.removeStyleLayer(LAYER)
            if (style.styleSourceExists(SOURCE)) style.removeStyleSource(SOURCE)
        }
    }

    private companion object {
        const val SOURCE = "meeterz-sign"
        const val LAYER = "meeterz-sign-layer"
        const val STOP = "meeterz-sign-stop"
        const val YIELD = "meeterz-sign-yield"
    }
}
