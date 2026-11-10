package de.koeven.meeterz.nav

import android.annotation.SuppressLint
import android.content.Context
import android.util.Log
import com.mapbox.api.directions.v5.models.RouteOptions
import com.mapbox.geojson.Point
import com.mapbox.navigation.base.extensions.applyDefaultNavigationOptions
import com.mapbox.navigation.base.extensions.applyLanguageAndVoiceUnitOptions
import com.mapbox.navigation.base.route.NavigationRoute
import com.mapbox.navigation.base.route.NavigationRouterCallback
import com.mapbox.navigation.base.route.RouterFailure
import com.mapbox.navigation.base.trip.model.RouteProgress
import com.mapbox.navigation.base.trip.model.RouteProgressState
import com.mapbox.navigation.core.MapboxNavigation
import com.mapbox.navigation.core.directions.session.RoutesObserver
import com.mapbox.navigation.core.lifecycle.MapboxNavigationApp
import com.mapbox.navigation.core.lifecycle.MapboxNavigationObserver
import com.mapbox.navigation.core.trip.session.RouteProgressObserver
import com.mapbox.navigation.core.trip.session.VoiceInstructionsObserver
import de.koeven.meeterz.AppState
import de.koeven.meeterz.auth.AuthRepository
import de.koeven.meeterz.data.Backend
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.time.Instant
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine

/**
 * Navigation auf dem Handy (iOS: NavigationCoordinator). Plant Routen, startet die Führung und spricht die Ansagen
 * mit denselben Regeln wie auf iOS (Announcer).
 */
object NavigationController : MapboxNavigationObserver {
    data class Destination(val name: String, val lat: Double, val lng: Double, val address: String? = null)

    data class Guidance(
        val destination: Destination,
        val instruction: String = "",
        val distanceToTurn: Double = 0.0,
        val remainingDistance: Double = 0.0,
        val remainingSeconds: Double = 0.0,
    )

    private val _guidance = MutableStateFlow<Guidance?>(null)
    /** Läuft gerade eine Führung? (null = nein) */
    val guidance: StateFlow<Guidance?> = _guidance

    private val _progress = MutableStateFlow<RouteProgress?>(null)
    val progress: StateFlow<RouteProgress?> = _progress

    private var speaker: Speaker? = null
    private var announcer = Announcer()
    /** Auf 2 km verschobene Autobahnansage (Abschnitt, Ansage) */
    private var deferred: Pair<Int, Voice>? = null
    private var navigation: MapboxNavigation? = null

    fun init(context: Context) {
        if (speaker == null) speaker = Speaker(context.applicationContext)
        MapboxNavigationApp.registerObserver(this)
    }

    override fun onAttached(mapboxNavigation: MapboxNavigation) {
        navigation = mapboxNavigation
        mapboxNavigation.registerRouteProgressObserver(progressObserver)
        mapboxNavigation.registerVoiceInstructionsObserver(voiceObserver)
        mapboxNavigation.registerRoutesObserver(routesObserver)
    }

    override fun onDetached(mapboxNavigation: MapboxNavigation) {
        mapboxNavigation.unregisterRouteProgressObserver(progressObserver)
        mapboxNavigation.unregisterVoiceInstructionsObserver(voiceObserver)
        mapboxNavigation.unregisterRoutesObserver(routesObserver)
        navigation = null
    }

    /** Routen zum Ziel planen (schnellste zuerst, dazu Alternativen); `via` = Zwischenziele, z. B. Ladestopps */
    suspend fun plan(context: Context, from: Point, to: Destination, via: List<Point> = emptyList()): List<NavigationRoute> {
        val nav = navigation ?: return emptyList()
        val options = RouteOptions.builder()
            .applyDefaultNavigationOptions()
            .applyLanguageAndVoiceUnitOptions(context)
            .coordinatesList(listOf(from) + via + Point.fromLngLat(to.lng, to.lat))
            .alternatives(via.isEmpty())
            .build()
        return suspendCoroutine { cont ->
            nav.requestRoutes(options, object : NavigationRouterCallback {
                override fun onRoutesReady(routes: List<NavigationRoute>, routerOrigin: String) = cont.resume(routes)
                override fun onFailure(reasons: List<RouterFailure>, routeOptions: RouteOptions) {
                    Log.w("Meeterz", "Routenplanung fehlgeschlagen: ${reasons.joinToString { it.message }}")
                    cont.resume(emptyList())
                }
                override fun onCanceled(routeOptions: RouteOptions, routerOrigin: String) = cont.resume(emptyList())
            })
        }
    }

    @SuppressLint("MissingPermission")
    fun start(routes: List<NavigationRoute>, destination: Destination) {
        val nav = navigation ?: return
        announcer = Announcer()
        deferred = null
        nav.setNavigationRoutes(routes)
        nav.startTripSession()
        _guidance.value = Guidance(destination)
    }

    fun stop() {
        if (_guidance.value != null) AppState.scope.launch { runCatching { Backend.client.postgrest.rpc("clear_active_route") } }
        lastShare = 0L
        navigation?.setNavigationRoutes(emptyList())
        speaker?.stop()
        deferred = null
        _guidance.value = null
        _progress.value = null
    }

    /** Hinweis vorlesen (Musik wird leiser), ohne laufende Ansagen abzubrechen */
    fun announce(text: String) { speaker?.announce(text) }

    var muted: Boolean
        get() = speaker?.muted ?: false
        set(value) { speaker?.muted = value; if (value) speaker?.stop() }

    private val routesObserver = RoutesObserver { result ->
        if (result.navigationRoutes.isEmpty()) _progress.value = null
    }

    private var lastShare = 0L

    /** Eigene Route für Freunde (alle 60 s, wie iOS); nicht bei Inkognito oder verborgenen Routen */
    private fun share(progress: RouteProgress, destination: Destination) {
        val now = System.currentTimeMillis()
        if (now - lastShare < 60_000) return
        lastShare = now
        val profile = (AppState.auth.state.value as? AuthRepository.State.Ready)?.profile ?: return
        if (profile.hideRoutes == true || (profile.incognitoUntil?.let { runCatching { Instant.parse(it) > Instant.now() }.getOrNull() } == true)) return
        val samples = RouteSampler.samples(RouteSampler.pieces(progress.navigationRoute.directionsRoute))
        val points = RouteSampler.sharePoints(samples, progress.distanceTraveled.toDouble(), progress.durationRemaining, now / 1000.0)
        if (points.size < 2) return
        val params = buildJsonObject {
            put("destination_name", destination.name)
            put("dest_lat", destination.lat)
            put("dest_lng", destination.lng)
            put("eta_unix", now / 1000.0 + progress.durationRemaining)
            put("points", JsonArray(points.map { p -> JsonArray(p.map { JsonPrimitive(it) }) }))
            put("travel_mode", "car")
        }
        AppState.scope.launch { runCatching { Backend.client.postgrest.rpc("set_active_route", params) } }
    }

    private val progressObserver = RouteProgressObserver { progress ->
        _progress.value = progress
        _guidance.value?.let { share(progress, it.destination) }
        val g = _guidance.value ?: return@RouteProgressObserver
        val banner = progress.bannerInstructions?.primary()?.text().orEmpty()
        _guidance.value = g.copy(
            instruction = banner,
            distanceToTurn = progress.currentLegProgress?.currentStepProgress?.distanceRemaining?.toDouble() ?: 0.0,
            remainingDistance = progress.distanceRemaining.toDouble(),
            remainingSeconds = progress.durationRemaining,
        )
        if (progress.currentState == RouteProgressState.COMPLETE) stop()
        // Verschobene Autobahnansage bei 2 km sprechen
        deferred?.let { (stepIndex, voice) ->
            val leg = MapboxRoute.legState(progress) ?: return@let
            if (leg.stepIndex != stepIndex) { deferred = null; return@let }
            if (leg.distanceRemaining <= MotorwayTiming.FIRST_DISTANCE + 30) {
                deferred = null
                speak(voice, leg, isDeferred = true)
            }
        }
    }

    private val voiceObserver = VoiceInstructionsObserver { v ->
        val leg = _progress.value?.let(MapboxRoute::legState)
        val voice = Voice(v.distanceAlongGeometry() ?: 0.0, v.announcement() ?: return@VoiceInstructionsObserver)
        if (leg == null) { speaker?.say(voice.text); return@VoiceInstructionsObserver }
        speak(voice, leg, isDeferred = false)
    }

    private fun speak(voice: Voice, leg: LegState, isDeferred: Boolean) {
        when (val r = announcer.process(voice, leg, isDeferred)) {
            is Announcer.Result.Skip -> Log.i("Meeterz", "Ansage ausgelassen (${r.reason}): ${voice.text}")
            is Announcer.Result.Defer -> { deferred = leg.stepIndex to r.instruction; Log.i("Meeterz", "Ansage auf 2 km verschoben: ${voice.text}") }
            is Announcer.Result.Speak -> {
                if (r.text != voice.text) Log.i("Meeterz", "Ansage angepasst: „${voice.text}“ → „${r.text}“")
                speaker?.say(r.text)
            }
        }
    }
}
