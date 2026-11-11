package de.koeven.meeterz.car

import com.mapbox.geojson.Feature
import com.mapbox.geojson.FeatureCollection
import com.mapbox.geojson.Point
import com.mapbox.maps.Style
import com.mapbox.maps.extension.androidauto.MapboxCarMapObserver
import com.mapbox.maps.extension.androidauto.MapboxCarMapSurface
import com.mapbox.maps.extension.style.expressions.generated.Expression.Companion.get
import com.mapbox.maps.extension.style.layers.addLayer
import com.mapbox.maps.extension.style.layers.generated.symbolLayer
import com.mapbox.maps.extension.style.sources.addSource
import com.mapbox.maps.extension.style.sources.generated.GeoJsonSource
import com.mapbox.maps.extension.style.sources.generated.geoJsonSource
import com.mapbox.maps.extension.style.sources.getSourceAs
import de.koeven.meeterz.AppState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

/** Freunde auf der Auto-Karte: Profilbild (sonst Initialen) mit Vornamen – wie auf dem Handy (CarPlay: FriendOverlay) */
class CarFriendMarkers : MapboxCarMapObserver {
    private var job: Job? = null

    override fun onAttached(mapboxCarMapSurface: MapboxCarMapSurface) {
        val map = mapboxCarMapSurface.mapSurface.mapboxMap
        job = CoroutineScope(SupervisorJob() + Dispatchers.Main).launch {
            combine(AppState.friends, AppState.hub.positions, de.koeven.meeterz.social.Passengers.version,
                de.koeven.meeterz.data.AvatarStore.images) { friends, live, _, avatars ->
                val riding = de.koeven.meeterz.social.Passengers.riding
                friends.filter { it.isAccepted && it.friendId !in riding }.mapNotNull { f ->
                    val p = live[f.friendId]
                    val lat = p?.lat ?: f.lat ?: return@mapNotNull null
                    val lng = p?.lng ?: f.lng ?: return@mapNotNull null
                    val image = avatars[f.friendId]?.let { "friend-${f.friendId}-${it.generationId}" to it }
                    val icon = image?.first ?: "friend-initials-${f.initials}"
                    Triple(Feature.fromGeometry(Point.fromLngLat(lng, lat)).apply {
                        addStringProperty("name", f.firstName); addStringProperty("icon", icon)
                    }, icon, { image?.second?.let { de.koeven.meeterz.data.AvatarStore.pin(it) } ?: de.koeven.meeterz.ui.initialsBubble(f.initials) })
                }
            }.collect { items ->
                map.getStyle { style ->
                    for ((_, id, bitmap) in items) if (!style.hasStyleImage(id)) style.addImage(id, bitmap())   // nur neue Bilder zeichnen
                    show(style, FeatureCollection.fromFeatures(items.map { it.first }))
                }
            }
        }
    }

    private fun show(style: Style, data: FeatureCollection) {
        val existing = style.getSourceAs<GeoJsonSource>(SOURCE)
        if (existing != null) { existing.featureCollection(data); return }
        style.addSource(geoJsonSource(SOURCE) { featureCollection(data) })
        style.addLayer(symbolLayer(DOTS, SOURCE) {
            iconImage(get("icon")); iconSize(0.5); iconAllowOverlap(true)
        })
        style.addLayer(symbolLayer(NAMES, SOURCE) {
            textField(get("name")); textSize(13.0); textOffset(listOf(0.0, 2.0)); textColor("#FFFFFF")
            textHaloColor("#062A32"); textHaloWidth(1.5)
        })
    }

    override fun onDetached(mapboxCarMapSurface: MapboxCarMapSurface) {
        job?.cancel(); job = null
        mapboxCarMapSurface.mapSurface.mapboxMap.getStyle { style ->
            listOf(NAMES, DOTS).forEach { if (style.styleLayerExists(it)) style.removeStyleLayer(it) }
            if (style.styleSourceExists(SOURCE)) style.removeStyleSource(SOURCE)
        }
    }

    private companion object {
        const val SOURCE = "meeterz-friends"
        const val DOTS = "meeterz-friends-dots"
        const val NAMES = "meeterz-friends-names"
    }
}
