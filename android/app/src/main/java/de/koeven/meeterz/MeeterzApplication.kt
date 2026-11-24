package de.koeven.meeterz

import android.app.Application
import com.mapbox.common.MapboxOptions
import com.mapbox.navigation.base.options.NavigationOptions
import com.mapbox.navigation.core.lifecycle.MapboxNavigationApp
import de.koeven.meeterz.nav.NavigationController
import kotlinx.coroutines.launch

class MeeterzApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        L10n.init(this)
        MapboxOptions.accessToken = getString(R.string.mapbox_access_token)
        // Eine Navigation für App und Android Auto
        if (!MapboxNavigationApp.isSetup()) MapboxNavigationApp.setup {
            NavigationOptions.Builder(this)
                // Live-Standort mit Sprungfilter: stehend an der Ampel kein Neuberechnen wegen GPS-Spiegelungen (wie iOS)
                .locationOptions(com.mapbox.navigation.base.options.LocationOptions.Builder()
                    .locationProviderFactory(de.koeven.meeterz.nav.SteadyLocation.factory,
                        com.mapbox.navigation.base.options.LocationOptions.LocationProviderType.MIXED)
                    .build())
                .build()
        }
        NavigationController.init(this)
        Diag.init(this)
        AppState.init(this)
        de.koeven.meeterz.ev.EvSettings.init(this)
        de.koeven.meeterz.ev.ConsumptionLearner.init(this)
        de.koeven.meeterz.sound.SoundStore.init(this)
        de.koeven.meeterz.data.AvatarStore.init(this)
        de.koeven.meeterz.data.StoriesStore.init(this)
        de.koeven.meeterz.social.Passengers.load()
        de.koeven.meeterz.suggest.Parking.load()
        // Mit aktiver Route nur der Verkehr auf ihr (wie iOS)
        AppState.scope.launch(kotlinx.coroutines.Dispatchers.Main) {
            NavigationController.guidance.collect { de.koeven.meeterz.ui.TrafficLayer.routeActive = it != null }
        }
    }
}
