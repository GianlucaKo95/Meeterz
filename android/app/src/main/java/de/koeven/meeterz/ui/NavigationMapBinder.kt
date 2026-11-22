package de.koeven.meeterz.ui

import com.mapbox.maps.EdgeInsets
import com.mapbox.maps.MapView
import com.mapbox.maps.plugin.animation.camera
import com.mapbox.maps.plugin.viewport.viewport
import com.mapbox.maps.plugin.gestures.gestures
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

        private val zoomTurns = setOf("turn", "end of road", "roundabout", "rotary", "off ramp", "fork")
        private val zoomExits = setOf("off ramp", "fork")

        /**
         * Vor Abbiegungen/Ausfahrten heranzoomen (wie ManeuverGuidance.swift): ca. 12 s vorher, mindestens 250 m,
         * bei Ausfahrten 600 m, auf 17 bzw. 16,5 – nur wenn die Karte nicht schon näher ist. null = Mapbox überlassen.
         */
        fun maneuverZoom(progress: RouteProgress, speed: Double, currentZoom: Double): Double? {
            val leg = progress.currentLegProgress ?: return null
            val type = leg.upcomingStep?.maneuver()?.type() ?: return null
            if (type !in zoomTurns) return null
            val exit = type in zoomExits
            val lead = maxOf(speed * 12, if (exit) 600.0 else 250.0)
            val d = leg.currentStepProgress?.distanceRemaining?.toDouble() ?: return null
            if (d >= lead) return null
            val target = if (exit) 16.5 else 17.0
            return target.takeIf { currentZoom <= target + 0.01 }
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
    private var previewing = false

    // Routenvorschau: Verschieben/Zoomen lässt die Kamera los (sonst zieht die Übersicht sie bei jedem
    // Standort zurück). Eine andere Route wählen springt wieder zur Gesamtübersicht (showPreview). Wie iOS.
    init {
        val release = { if (previewing && !active) camera.requestNavigationCameraToIdle() }
        mapView.gestures.addOnMoveListener(object : com.mapbox.maps.plugin.gestures.OnMoveListener {
            override fun onMoveBegin(detector: com.mapbox.android.gestures.MoveGestureDetector) = release()
            override fun onMove(detector: com.mapbox.android.gestures.MoveGestureDetector) = false
            override fun onMoveEnd(detector: com.mapbox.android.gestures.MoveGestureDetector) = Unit
        })
        mapView.gestures.addOnScaleListener(object : com.mapbox.maps.plugin.gestures.OnScaleListener {
            override fun onScaleBegin(detector: com.mapbox.android.gestures.StandardScaleGestureDetector) = release()
            override fun onScale(detector: com.mapbox.android.gestures.StandardScaleGestureDetector) = Unit
            override fun onScaleEnd(detector: com.mapbox.android.gestures.StandardScaleGestureDetector) = Unit
        })
    }
    private var meetingMode = false

    /** Treffen-Navigation: den Positionspfeil oberhalb der dauerhaft eingeblendeten unteren Karten halten. */
    fun setMeetingMode(enabled: Boolean) {
        if (meetingMode == enabled) return
        meetingMode = enabled
        val d = mapView.resources.displayMetrics.density
        viewport.followingPadding = if (enabled) {
            // Größerer unterer Sicherheitsabstand verschiebt den Puck sichtbar nach oben.
            EdgeInsets(120.0 * d, 40.0 * d, 420.0 * d, 40.0 * d)
        } else {
            EdgeInsets(180.0 * d, 40.0 * d, 120.0 * d, 40.0 * d)
        }
        if (active) viewport.evaluate()
    }
    private var lastRenderedRoutes: List<NavigationRoute> = emptyList()

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

    /** Routenvorschau (vor dem Start): alle Routen zeichnen, gewählte hervorgehoben, Übersicht – null räumt auf */
    fun showPreview(routes: List<NavigationRoute>?, selected: Int = 0) {
        if (active) return
        val style = mapView.mapboxMap.style ?: return
        previewing = !routes.isNullOrEmpty()
        if (routes.isNullOrEmpty()) {
            lastRenderedRoutes = emptyList()
            routeLineApi.clearRouteLine { routeLineView.renderClearRouteLineValue(style, it) }
            viewport.clearRouteData()
            mapView.viewport.transitionTo(followMe(mapView.viewport, map3d = (mapView.mapboxMap.cameraState.pitch > 0)))
            return
        }
        val main = routes.getOrNull(selected) ?: routes.first()
        lastRenderedRoutes = listOf(main) + routes.filter { it !== main }
        routeLineApi.setNavigationRoutes(lastRenderedRoutes) { routeLineView.renderRouteDrawData(style, it) }
        viewport.onRouteChanged(main)
        viewport.evaluate()
        mapView.viewport.idle()   // „Puck folgen“ loslassen, sonst zieht es die Kamera zurück
        camera.requestNavigationCameraToOverview()
    }

    /** Nach einem Kartenstil-Wechsel die zuletzt dargestellte Route in den neuen Style zeichnen. */
    fun refreshStyle() {
        val style = mapView.mapboxMap.style ?: return
        val routes = lastRenderedRoutes
        if (routes.isEmpty()) return
        routeLineApi.setNavigationRoutes(routes) { value ->
            routeLineView.renderRouteDrawData(style, value)
        }
    }

    private val routesObserver = RoutesObserver { result ->
        val routes: List<NavigationRoute> = result.navigationRoutes
        if (routes.isEmpty()) return@RoutesObserver
        lastRenderedRoutes = routes
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
        viewport.followingZoomPropertyOverride(maneuverZoom(progress, (de.koeven.meeterz.AppState.lastLocation?.speed ?: 0f).toDouble(),
            mapView.mapboxMap.cameraState.zoom))
        // Norden oben (Einstellung wie Apple Karten / iOS): Kamera nicht mit der Fahrtrichtung drehen
        viewport.followingBearingPropertyOverride(if (UiPreferences.northUp.value) 0.0 else null)
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
