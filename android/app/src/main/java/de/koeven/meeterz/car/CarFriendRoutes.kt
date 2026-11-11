package de.koeven.meeterz.car

import androidx.compose.ui.graphics.toArgb
import com.mapbox.geojson.Feature
import com.mapbox.geojson.FeatureCollection
import com.mapbox.geojson.LineString
import com.mapbox.geojson.Point
import com.mapbox.maps.extension.androidauto.MapboxCarMapObserver
import com.mapbox.maps.extension.androidauto.MapboxCarMapSurface
import com.mapbox.maps.extension.style.expressions.generated.Expression.Companion.get
import com.mapbox.maps.extension.style.layers.addLayer
import com.mapbox.maps.extension.style.layers.addLayerBelow
import com.mapbox.maps.extension.style.layers.generated.lineLayer
import com.mapbox.maps.extension.style.layers.properties.generated.LineCap
import com.mapbox.maps.extension.style.layers.properties.generated.LineJoin
import com.mapbox.maps.extension.style.sources.addSource
import com.mapbox.maps.extension.style.sources.generated.GeoJsonSource
import com.mapbox.maps.extension.style.sources.generated.geoJsonSource
import com.mapbox.maps.extension.style.sources.getSourceAs
import de.koeven.meeterz.AppState
import de.koeven.meeterz.social.Passengers
import de.koeven.meeterz.ui.FriendPalette
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

/** Routen der Freunde auf der Auto-Karte: in ihrer Farbe mit dunkler Umrandung, unter den Markierungen (CarPlay: FriendOverlay) */
class CarFriendRoutes : MapboxCarMapObserver {
    private var job: Job? = null

    override fun onAttached(mapboxCarMapSurface: MapboxCarMapSurface) {
        val map = mapboxCarMapSurface.mapSurface.mapboxMap
        job = CoroutineScope(SupervisorJob() + Dispatchers.Main).launch {
            combine(AppState.routes.routes, Passengers.version) { routes, _ ->
                val riding = Passengers.riding
                routes.filterKeys { it !in riding }.map { (id, r) ->
                    Feature.fromGeometry(LineString.fromLngLats(r.coordinates.map { Point.fromLngLat(it.first, it.second) })).apply {
                        addStringProperty("color", String.format("#%06X", FriendPalette.routeColor(id).toArgb() and 0xFFFFFF))
                    }
                }
            }.collect { features ->
                map.getStyle { style ->
                    val data = FeatureCollection.fromFeatures(features)
                    val existing = style.getSourceAs<GeoJsonSource>(SOURCE)
                    if (existing != null) { existing.featureCollection(data); return@getStyle }
                    style.addSource(geoJsonSource(SOURCE) { featureCollection(data) })
                    val casing = lineLayer(CASING, SOURCE) {
                        lineColor("#050A12"); lineOpacity(0.92); lineWidth(8.0); lineCap(LineCap.ROUND); lineJoin(LineJoin.ROUND)
                    }
                    val line = lineLayer(LINE, SOURCE) {
                        lineColor(get("color")); lineWidth(5.0); lineCap(LineCap.ROUND); lineJoin(LineJoin.ROUND)
                    }
                    // Unter die Freundes-Markierungen, falls schon da
                    if (style.styleLayerExists(FRIEND_DOTS)) { style.addLayerBelow(casing, FRIEND_DOTS); style.addLayerBelow(line, FRIEND_DOTS) }
                    else { style.addLayer(casing); style.addLayer(line) }
                }
            }
        }
    }

    override fun onDetached(mapboxCarMapSurface: MapboxCarMapSurface) {
        job?.cancel(); job = null
        mapboxCarMapSurface.mapSurface.mapboxMap.getStyle { style ->
            listOf(LINE, CASING).forEach { if (style.styleLayerExists(it)) style.removeStyleLayer(it) }
            if (style.styleSourceExists(SOURCE)) style.removeStyleSource(SOURCE)
        }
    }

    private companion object {
        const val SOURCE = "meeterz-friend-routes"
        const val CASING = "meeterz-friend-routes-casing"
        const val LINE = "meeterz-friend-routes-line"
        const val FRIEND_DOTS = "meeterz-friends-dots"
    }
}
