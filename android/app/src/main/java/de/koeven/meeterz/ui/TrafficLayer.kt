package de.koeven.meeterz.ui

import com.mapbox.common.Cancelable
import com.mapbox.maps.MapboxMap
import com.mapbox.maps.Style
import com.mapbox.maps.extension.androidauto.MapboxCarMapObserver
import com.mapbox.maps.extension.androidauto.MapboxCarMapSurface
import com.mapbox.maps.extension.style.expressions.dsl.generated.match
import com.mapbox.maps.extension.style.expressions.generated.Expression
import com.mapbox.maps.extension.style.layers.addLayer
import com.mapbox.maps.extension.style.layers.addLayerBelow
import com.mapbox.maps.extension.style.layers.generated.lineLayer
import com.mapbox.maps.extension.style.layers.properties.generated.LineCap
import com.mapbox.maps.extension.style.layers.properties.generated.LineJoin
import com.mapbox.maps.extension.style.sources.addSource
import com.mapbox.maps.extension.style.sources.generated.vectorSource
import de.koeven.meeterz.Diag

/**
 * Verkehrslage auf allen Karten wie Apple Karten (iOS: TrafficLayer.swift): stockend orange, Stau rot,
 * Stillstand dunkelrot – auch in der freien Fahrt, in „Klassisch“ und „Satellit“. Freie Straßen bleiben ungefärbt.
 */
object TrafficLayer {
    private const val ID = "meeterz-traffic"
    private val maps = java.util.Collections.newSetFromMap(java.util.WeakHashMap<MapboxMap, Boolean>())

    /**
     * Mit aktiver Route nur noch der Verkehr auf der eigenen Route (zeigt die Routenlinie) – Staus auf anderen Straßen
     * und der Gegenrichtung sahen aus, als stünde man selbst im Stau (wie iOS, 24.11.)
     */
    var routeActive = false
        set(value) {
            if (field == value) return
            field = value
            maps.toList().forEach { m -> m.getStyle()?.let(::applyVisibility) }
        }

    private fun applyVisibility(style: Style) {
        if (style.styleLayerExists(ID)) style.setStyleLayerProperty(ID, "visibility",
            com.mapbox.bindgen.Value.valueOf(if (routeActive) "none" else "visible"))
    }

    /** Ebene anlegen und nach jedem Stilwechsel neu; Rückgabe beendet das */
    fun install(map: MapboxMap): Cancelable {
        maps.add(map)
        map.getStyle()?.let(::add)
        return map.subscribeStyleLoaded { map.getStyle(::add) }
    }

    fun add(style: Style) = runCatching {
        if (!style.styleSourceExists(ID)) style.addSource(vectorSource(ID) { url("mapbox://mapbox.mapbox-traffic-v1") })
        if (style.styleLayerExists(ID)) { applyVisibility(style); return@runCatching }
        val layer = lineLayer(ID, ID) {
            sourceLayer("traffic")
            filter(match {
                get("congestion"); literal(listOf("moderate", "heavy", "severe")); literal(true); literal(false)
            })
            lineColor(match {
                get("congestion")
                literal("moderate"); rgb(255.0, 158.0, 10.0)
                literal("heavy"); rgb(255.0, 69.0, 58.0)
                literal("severe"); rgb(179.0, 26.0, 26.0)
                rgba(0.0, 0.0, 0.0, 0.0)
            })
            lineWidth(Expression.interpolate {
                exponential { literal(1.5) }; zoom()
                stop { literal(8.0); literal(1.0) }; stop { literal(12.0); literal(2.5) }
                stop { literal(16.0); literal(6.0) }; stop { literal(19.0); literal(14.0) }
            })
            lineOpacity(0.9)
            lineCap(LineCap.ROUND)
            lineJoin(LineJoin.ROUND)
            lineEmissiveStrength(1.0)
            slot("middle")
        }
        // Unter die eigene Routenlinie (die zeigt den Verkehr auf der Route selbst)
        val route = style.styleLayers.map { it.id }.firstOrNull { it.startsWith("mapbox-layerGroup") || it.contains("route-line") }
        if (route != null) style.addLayerBelow(layer, route) else style.addLayer(layer)
        applyVisibility(style)
    }.onFailure { Diag.log("Verkehrsebene: ${it.message}") }

    /** Android Auto: Ebene auf der Auto-Karte */
    class Car : MapboxCarMapObserver {
        private var token: Cancelable? = null
        override fun onAttached(mapboxCarMapSurface: MapboxCarMapSurface) { token = install(mapboxCarMapSurface.mapSurface.mapboxMap) }
        override fun onDetached(mapboxCarMapSurface: MapboxCarMapSurface) { token?.cancel(); token = null }
    }
}
