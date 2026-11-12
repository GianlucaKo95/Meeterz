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
                    if (existing != null) { existing.featureCollection(data); keepBelowOwnRoute(style); return@getStyle }
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
                    keepBelowOwnRoute(style)
                }
            }
        }
    }

    /**
     * Freundes-Routen unter die eigene Route: Mapbox fügt seine Routenlinie erst beim Start der Führung hinzu,
     * darum bei jeder Aktualisierung prüfen und beide Ebenen unter die unterste Navigations-Ebene schieben (wie iOS)
     */
    private fun keepBelowOwnRoute(style: com.mapbox.maps.Style) {
        val ids = style.styleLayers.map { it.id }
        val own = ids.indexOfFirst { it.startsWith("mapbox-layerGroup") || it.startsWith("mapbox-masking") || it.contains("route-line") }
        val casing = ids.indexOf(CASING)
        if (own < 0 || casing < 0 || casing < own) return
        style.moveStyleLayer(CASING, com.mapbox.maps.LayerPosition(null, ids[own], null))
        style.moveStyleLayer(LINE, com.mapbox.maps.LayerPosition(CASING, null, null))
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
