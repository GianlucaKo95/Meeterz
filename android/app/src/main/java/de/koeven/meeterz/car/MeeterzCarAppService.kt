package de.koeven.meeterz.car

import android.content.Intent
import androidx.car.app.CarAppService
import androidx.car.app.Screen
import androidx.car.app.Session
import androidx.car.app.validation.HostValidator
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import com.mapbox.maps.MapInitOptions
import com.mapbox.maps.extension.androidauto.MapboxCarMap
import com.mapbox.navigation.base.options.NavigationOptions
import com.mapbox.navigation.core.lifecycle.MapboxNavigationApp
import com.mapbox.navigation.ui.androidauto.MapboxCarContext
import com.mapbox.navigation.ui.androidauto.map.MapboxCarMapLoader
import com.mapbox.navigation.ui.androidauto.screenmanager.MapboxScreen
import com.mapbox.navigation.ui.androidauto.screenmanager.MapboxScreenManager
import com.mapbox.navigation.ui.androidauto.screenmanager.prepareScreens

/** Android Auto (Gegenstück zu CarPlay). Erster Stand: Mapbox' fertige Bildschirme für freie Fahrt und Navigation. */
class MeeterzCarAppService : CarAppService() {
    // ponytail: alle Hosts zulassen, bis die App bei Google eingereicht wird – dann HostValidator mit Googles Liste
    override fun createHostValidator() = HostValidator.ALLOW_ALL_HOSTS_VALIDATOR

    override fun onCreateSession(): Session = MeeterzCarSession()
}

class MeeterzCarSession : Session() {
    private val mapboxCarMap = MapboxCarMap()
    private val mapboxCarContext = MapboxCarContext(lifecycle, mapboxCarMap).prepareScreens()
    private val mapLoader = MapboxCarMapLoader()

    init {
        lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onCreate(owner: LifecycleOwner) {
                if (!MapboxNavigationApp.isSetup()) {
                    MapboxNavigationApp.setup { NavigationOptions.Builder(carContext).build() }
                }
                MapboxNavigationApp.attach(owner)
                mapboxCarMap.setup(carContext, MapInitOptions(carContext))
                mapboxCarMap.registerObserver(mapLoader)
            }

            override fun onDestroy(owner: LifecycleOwner) {
                mapboxCarMap.unregisterObserver(mapLoader)
                MapboxNavigationApp.detach(owner)
            }
        })
    }

    override fun onCreateScreen(intent: Intent): Screen {
        val key = MapboxScreenManager.current()?.key ?: MapboxScreen.FREE_DRIVE
        return mapboxCarContext.mapboxScreenManager.createScreen(key)
    }
}
