package de.koeven.meeterz.ui

import com.mapbox.maps.EdgeInsets
import com.mapbox.maps.MapView
import com.mapbox.maps.plugin.animation.camera
import com.mapbox.maps.plugin.locationcomponent.LocationProvider
import com.mapbox.maps.plugin.locationcomponent.location
import com.mapbox.navigation.base.route.NavigationRoute
import com.mapbox.navigation.core.MapboxNavigation
import com.mapbox.navigation.core.directions.session.RoutesObserver
import com.mapbox.navigation.core.lifecycle.MapboxNavigationApp
import com.mapbox.navigation.core.lifecycle.MapboxNavigationObserver
import com.mapbox.navigation.core.trip.session.LocationMatcherResult
import com.mapbox.navigation.core.trip.session.LocationObserver
import com.mapbox.navigation.core.trip.session.RouteProgressObserver
import com.mapbox.navigation.base.trip.model.RouteProgress
import com.mapbox.navigation.ui.maps.camera.NavigationCamera
import com.mapbox.navigation.ui.maps.camera.data.MapboxNavigationViewportDataSource
import com.mapbox.navigation.ui.maps.location.NavigationLocationProvider
import com.mapbox.navigation.ui.maps.route.line.api.MapboxRouteLineApi
import com.mapbox.navigation.ui.maps.route.line.api.MapboxRouteLineView
import com.mapbox.navigation.ui.maps.route.line.model.MapboxRouteLineApiOptions
import com.mapbox.navigation.ui.maps.route.line.model.MapboxRouteLineViewOptions
import com.mapbox.common.location.Location

/**
 * Verbindet die Karte mit der Navigation: Routenlinie, Pfeil auf der Straße, Kamera.
 * Die Kamera ist eine Zoomstufe näher als Mapbox' Vorgabe (wie iOS seit 04.11.: Ausschnitt halbiert, Grenzen +1).
 */
class NavigationMapBinder(private val mapView: MapView) : MapboxNavigationObserver {
    companion object {
        const val MINIMUM_PITCH = 25.0
        const val PITCH_TRIGGER = 200.0
        private val keepThreeD = setOf("continue", "merge", "on ramp", "off ramp", "fork", "arrive")

        /** Neigung für jetzt – null: Mapbox überlassen (weit vor der Abbiegung, Ausnahme-Manöver, Karte in 2D) */
        fun maneuverPitch(progress: RouteProgress, defaultPitch: Double): Double? {
            if (defaultPitch <= MINIMUM_PITCH) return null
            val leg = progress.currentLegProgress ?: return null
            val upcoming = leg.upcomingStep ?: return null
            if (upcoming.maneuver().type() in keepThreeD) return null
            val d = leg.currentStepProgress?.distanceRemaining?.toDouble() ?: return null
            if (d > PITCH_TRIGGER) return null
            return MINIMUM_PITCH + (defaultPitch - MINIMUM_PITCH) * maxOf(0.0, d) / PITCH_TRIGGER
        }
    }

    private val locationProvider = NavigationLocationProvider()
    private var defaultProvider: LocationProvider? = null
    private val routeLineApi = MapboxRouteLineApi(MapboxRouteLineApiOptions.Builder().build())
    private val routeLineView = MapboxRouteLineView(MapboxRouteLineViewOptions.Builder(mapView.context).build())
    private val viewport = MapboxNavigationViewportDataSource(mapView.mapboxMap).apply {
        options.followingFrameOptions.intersectionDensityCalculation.averageDistanceMultiplier = 3.5
        options.followingFrameOptions.minZoom = 11.5
        options.followingFrameOptions.maxZoom = 17.35
        val d = mapView.resources.displayMetrics.density
        followingPadding = EdgeInsets(180.0 * d, 40.0 * d, 120.0 * d, 40.0 * d)
    }
    private val camera = NavigationCamera(mapView.mapboxMap, mapView.camera, viewport)
    private var active = false

    fun attach() = MapboxNavigationApp.registerObserver(this)
    fun detach() = MapboxNavigationApp.unregisterObserver(this)

    /** Führung beginnt/endet: Pfeil von der Navigation (auf der Straße) bzw. wieder vom GPS */
    fun setActive(on: Boolean) {
        if (on == active) return
        active = on
        if (on) {
            defaultProvider = mapView.location.getLocationProvider()
            mapView.location.setLocationProvider(locationProvider)
            camera.requestNavigationCameraToFollowing()
        } else {
            defaultProvider?.let { mapView.location.setLocationProvider(it) }
            viewport.clearRouteData()
            mapView.mapboxMap.style?.let { style ->
                routeLineApi.clearRouteLine { routeLineView.renderClearRouteLineValue(style, it) }
            }
        }
    }

    private val routesObserver = RoutesObserver { result ->
        val routes: List<NavigationRoute> = result.navigationRoutes
        if (routes.isEmpty()) return@RoutesObserver
        routeLineApi.setNavigationRoutes(routes) { value ->
            mapView.mapboxMap.style?.let { routeLineView.renderRouteDrawData(it, value) }
        }
        viewport.onRouteChanged(routes.first())
        viewport.evaluate()
    }

    private val progressObserver = RouteProgressObserver { progress ->
        viewport.onRouteProgressChanged(progress)
        // Vor Abbiegungen flacher statt 2D (wie iOS NavigationZoom.maneuverPitch): über die letzten 200 m sanft
        // von der normalen Neigung auf 25°; Ausfahrten, Gabelungen, Auffahrten und das Ziel bleiben voll 3D
        viewport.followingPitchPropertyOverride(maneuverPitch(progress, viewport.options.followingFrameOptions.defaultPitch))
        viewport.evaluate()
        routeLineApi.updateWithRouteProgress(progress) { value ->
            mapView.mapboxMap.style?.let { routeLineView.renderRouteLineUpdate(it, value) }
        }
    }

    private val locationObserver = object : LocationObserver {
        override fun onNewRawLocation(rawLocation: Location) = Unit
        override fun onNewLocationMatcherResult(locationMatcherResult: LocationMatcherResult) {
            val loc = locationMatcherResult.enhancedLocation
            locationProvider.changePosition(loc, locationMatcherResult.keyPoints)
            viewport.onLocationChanged(loc)
            viewport.evaluate()
        }
    }

    override fun onAttached(mapboxNavigation: MapboxNavigation) {
        mapboxNavigation.registerRoutesObserver(routesObserver)
        mapboxNavigation.registerRouteProgressObserver(progressObserver)
        mapboxNavigation.registerLocationObserver(locationObserver)
    }

    override fun onDetached(mapboxNavigation: MapboxNavigation) {
        mapboxNavigation.unregisterRoutesObserver(routesObserver)
        mapboxNavigation.unregisterRouteProgressObserver(progressObserver)
        mapboxNavigation.unregisterLocationObserver(locationObserver)
    }
}
