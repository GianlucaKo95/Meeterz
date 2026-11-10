package de.koeven.meeterz.car

import android.location.Location
import androidx.car.app.CarContext
import androidx.car.app.CarToast
import androidx.car.app.Screen
import androidx.car.app.model.Action
import androidx.car.app.model.ActionStrip
import androidx.car.app.model.CarColor
import androidx.car.app.model.ItemList
import androidx.car.app.model.ListTemplate
import androidx.car.app.model.Row
import androidx.car.app.model.SearchTemplate
import androidx.car.app.model.Template
import androidx.car.app.navigation.model.NavigationTemplate
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.lifecycleScope
import com.mapbox.geojson.Point
import com.mapbox.maps.extension.androidauto.MapboxCarMap
import com.mapbox.navigation.ui.androidauto.action.MapboxMapActionStrip
import com.mapbox.navigation.ui.androidauto.location.CarLocationProvider
import com.mapbox.navigation.ui.androidauto.location.CarLocationRenderer
import com.mapbox.navigation.ui.androidauto.navigation.CarActiveGuidanceMarkers
import com.mapbox.navigation.ui.androidauto.navigation.CarCameraMode
import com.mapbox.navigation.ui.androidauto.navigation.CarNavigationCamera
import com.mapbox.navigation.ui.androidauto.navigation.CarNavigationInfoProvider
import com.mapbox.navigation.ui.androidauto.preview.CarRouteLineRenderer
import de.koeven.meeterz.AppState
import de.koeven.meeterz.data.FriendRow
import de.koeven.meeterz.data.MessagesStore
import de.koeven.meeterz.nav.NavigationController
import de.koeven.meeterz.nav.PlaceSearch
import de.koeven.meeterz.ui.km
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Eigener Standort fürs Planen: vom Handy (Teilen-Dienst) oder vom Auto-Bildschirm */
private suspend fun origin(): Point? {
    val loc: Location? = AppState.lastLocation
    if (loc != null) return Point.fromLngLat(loc.longitude, loc.latitude)
    return CarLocationProvider.getRegisteredInstance().lastLocation()?.let { Point.fromLngLat(it.longitude, it.latitude) }
}

/** Route planen und gleich losfahren (Android Auto erlaubt während der Fahrt keine lange Auswahl) */
private fun Screen.navigateTo(name: String, lat: Double, lng: Double) {
    lifecycleScope.launch {
        val from = origin() ?: return@launch
        val dest = NavigationController.Destination(name, lat, lng)
        val routes = NavigationController.plan(carContext, from, dest)
        if (routes.isNotEmpty()) NavigationController.start(routes, dest)
    }
}

/** Freie Fahrt: Karte mit Freunden, oben „Suchen“ und „Freunde“ */
class FreeDriveScreen(carContext: CarContext, private val carMap: MapboxCarMap) : Screen(carContext) {
    private val location = CarLocationRenderer()
    private val camera = CarNavigationCamera(CarCameraMode.FOLLOWING, null)
    private val friends = CarFriendMarkers()
    private val mapActions = MapboxMapActionStrip(this, camera)

    init {
        lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onResume(owner: LifecycleOwner) {
                carMap.registerObserver(location); carMap.registerObserver(camera); carMap.registerObserver(friends)
                carMap.setGestureHandler(camera.gestureHandler)
            }
            override fun onPause(owner: LifecycleOwner) {
                carMap.unregisterObserver(location); carMap.unregisterObserver(camera); carMap.unregisterObserver(friends)
                carMap.setGestureHandler(null)
            }
        })
    }

    override fun onGetTemplate(): Template = NavigationTemplate.Builder()
        .setBackgroundColor(CarColor.PRIMARY)
        .setActionStrip(
            ActionStrip.Builder()
                .addAction(Action.Builder().setTitle("Suchen").setOnClickListener { screenManager.push(CarSearchScreen(carContext)) }.build())
                .addAction(Action.Builder().setTitle("Ziele").setOnClickListener { screenManager.push(CarPlacesScreen(carContext)) }.build())
                .addAction(Action.Builder().setTitle("Freunde").setOnClickListener { screenManager.push(CarFriendsScreen(carContext)) }.build())
                .build(),
        )
        .setMapActionStrip(mapActions.build())
        .build()
}

/** Führung: Abbiegeanzeige, Routenlinie, Kamera; „Beenden“ oben */
class GuidanceScreen(carContext: CarContext, private val carMap: MapboxCarMap) : Screen(carContext) {
    private val routeLine = CarRouteLineRenderer()
    private val location = CarLocationRenderer()
    private val camera = CarNavigationCamera(CarCameraMode.FOLLOWING, CarCameraMode.OVERVIEW)
    private val markers = CarActiveGuidanceMarkers()
    private val friends = CarFriendMarkers()
    private val info = CarNavigationInfoProvider().invalidateOnChange(this)
    private val mapActions = MapboxMapActionStrip(this, camera)

    init {
        lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onResume(owner: LifecycleOwner) {
                listOf(routeLine, location, camera, markers, friends, info).forEach(carMap::registerObserver)
                carMap.setGestureHandler(camera.gestureHandler)
            }
            override fun onPause(owner: LifecycleOwner) {
                listOf(routeLine, location, camera, markers, friends, info).forEach(carMap::unregisterObserver)
                carMap.setGestureHandler(null)
            }
        })
    }

    override fun onGetTemplate(): Template = NavigationTemplate.Builder()
        .setBackgroundColor(CarColor.PRIMARY)
        .setActionStrip(
            ActionStrip.Builder()
                .addAction(Action.Builder().setTitle("Bescheid").setOnClickListener { screenManager.push(messageScreen(carContext)) }.build())
                .addAction(Action.Builder().setTitle("Beenden").setOnClickListener { NavigationController.stop() }.build())
                .build(),
        )
        .setMapActionStrip(mapActions.build())
        .apply { info.setNavigationInfo(this) }
        .build()
}

/**
 * Kurz Bescheid geben (CarPlay: „Kurz Bescheid geben“): sind am Ziel Freunde oder fahren welche hin,
 * gleich die Schnellantworten an sie – sonst erst den Freund wählen.
 */
fun messageScreen(carContext: CarContext): Screen {
    val partners = MessagesStore.recipientsAtDestination()
    return if (partners.isNotEmpty()) CarQuickRepliesScreen(carContext, partners) else CarMessageRecipientsScreen(carContext)
}

class CarMessageRecipientsScreen(carContext: CarContext) : Screen(carContext) {
    override fun onGetTemplate(): Template {
        val list = ItemList.Builder().setNoItemsMessage("Noch keine Freunde.")
        MessagesStore.friendsByDistance().take(6).forEach { f ->
            list.addItem(Row.Builder().setTitle(f.displayName)
                .setOnClickListener { screenManager.push(CarQuickRepliesScreen(carContext, listOf(f))) }.build())
        }
        return ListTemplate.Builder().setTitle("Bescheid geben").setHeaderAction(Action.BACK).setSingleList(list.build()).build()
    }
}

class CarQuickRepliesScreen(carContext: CarContext, private val to: List<FriendRow>) : Screen(carContext) {
    override fun onGetTemplate(): Template {
        val eta = NavigationController.guidance.value?.let { System.currentTimeMillis() + (it.remainingSeconds * 1000).toLong() }
        val list = ItemList.Builder()
        MessagesStore.quickReplies(eta).take(6).forEach { text ->
            list.addItem(Row.Builder().setTitle(text).setOnClickListener {
                lifecycleScope.launch {
                    val sent = AppState.messages.send(text, to.map { it.friendId })
                    CarToast.makeText(carContext, if (sent > 0) "Gesendet: „$text“" else "Nachricht nicht gesendet", CarToast.LENGTH_LONG).show()
                    screenManager.popToRoot()
                }
            }.build())
        }
        return ListTemplate.Builder().setTitle("An " + to.joinToString(", ") { it.firstName })
            .setHeaderAction(Action.BACK).setSingleList(list.build()).build()
    }
}

/** Freunde mit Standort; Antippen fährt zu ihnen (CarPlay: FriendsMenu) */
class CarFriendsScreen(carContext: CarContext) : Screen(carContext) {
    init {
        lifecycleScope.launch { AppState.hub.positions.collect { invalidate() } }
    }

    override fun onGetTemplate(): Template {
        val live = AppState.hub.positions.value
        val me = AppState.lastLocation
        val list = ItemList.Builder().setNoItemsMessage("Gerade teilt kein Freund seinen Standort.")
        AppState.friends.value.filter { it.isAccepted }.forEach { f ->
            val p = live[f.friendId]
            val lat = p?.lat ?: f.lat ?: return@forEach
            val lng = p?.lng ?: f.lng ?: return@forEach
            val detail = me?.let { km(FloatArray(1).also { r -> Location.distanceBetween(it.latitude, it.longitude, lat, lng, r) }[0].toDouble()) }
            list.addItem(
                Row.Builder().setTitle(f.firstName)
                    .apply { detail?.let { addText(it) } }
                    .setOnClickListener { navigateTo(f.firstName, lat, lng); screenManager.pop() }
                    .build(),
            )
        }
        return ListTemplate.Builder().setTitle("Freunde").setHeaderAction(Action.BACK).setSingleList(list.build()).build()
    }
}

/** Ziel suchen (Tastatur nur im Stand – das regelt Android Auto selbst) */
class CarSearchScreen(carContext: CarContext) : Screen(carContext) {
    private var results: List<PlaceSearch.Place> = emptyList()
    private var job: Job? = null

    override fun onGetTemplate(): Template {
        val list = ItemList.Builder()
        results.forEach { place ->
            list.addItem(
                Row.Builder().setTitle(place.name)
                    .apply { place.address?.let { addText(it) } }
                    .setOnClickListener { navigateTo(place.name, place.lat, place.lng); screenManager.pop() }
                    .build(),
            )
        }
        return SearchTemplate.Builder(object : SearchTemplate.SearchCallback {
            override fun onSearchTextChanged(searchText: String) = search(searchText)
            override fun onSearchSubmitted(searchTerm: String) = search(searchTerm)
        })
            .setHeaderAction(Action.BACK)
            .setSearchHint("Ziel oder Adresse")
            .setShowKeyboardByDefault(true)
            .setItemList(list.build())
            .build()
    }

    private fun search(text: String) {
        job?.cancel()
        job = lifecycleScope.launch {
            delay(300)
            val me = AppState.lastLocation
            results = PlaceSearch.search(text, me?.latitude, me?.longitude)
            invalidate()
        }
    }
}

/** Gespeicherte Orte (Zuhause, Arbeit, Favoriten) – Antippen fährt los */
class CarPlacesScreen(carContext: CarContext) : Screen(carContext) {
    override fun onGetTemplate(): Template {
        val list = ItemList.Builder().setNoItemsMessage("Noch keine Orte gespeichert – in der App bei der Routenvorschau „Als Zuhause“ o. Ä. wählen.")
        AppState.favorites.items.value.sortedBy { listOf("home", "work", "other").indexOf(it.kind) }.forEach { fav ->
            list.addItem(
                Row.Builder().setTitle(fav.label)
                    .apply { fav.address?.let { addText(it) } }
                    .setOnClickListener { navigateTo(fav.label, fav.lat, fav.lng); screenManager.pop() }
                    .build(),
            )
        }
        return ListTemplate.Builder().setTitle("Ziele").setHeaderAction(Action.BACK).setSingleList(list.build()).build()
    }
}
