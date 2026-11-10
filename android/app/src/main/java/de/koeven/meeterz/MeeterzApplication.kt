package de.koeven.meeterz

import android.app.Application
import com.mapbox.common.MapboxOptions
import com.mapbox.navigation.base.options.LocationOptions
import com.mapbox.navigation.base.options.NavigationOptions
import com.mapbox.navigation.core.lifecycle.MapboxNavigationApp
import de.koeven.meeterz.nav.NavigationController

class MeeterzApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        MapboxOptions.accessToken = getString(R.string.mapbox_access_token)
        // Eine Navigation für App und Android Auto
        // Standort mit Stillstandsfilter: an der Ampel kein Abschnittswechsel durch GPS-Springen (wie iOS)
        if (!MapboxNavigationApp.isSetup()) MapboxNavigationApp.setup {
            NavigationOptions.Builder(this)
                .locationOptions(LocationOptions.Builder()
                    .locationProviderFactory(de.koeven.meeterz.nav.FilteredLocationProviderFactory(), LocationOptions.LocationProviderType.REAL)
                    .build())
                .build()
        }
        NavigationController.init(this)
        AppState.init(this)
        de.koeven.meeterz.ev.EvSettings.init(this)
        de.koeven.meeterz.ev.ConsumptionLearner.init(this)
        de.koeven.meeterz.sound.SoundStore.init(this)
    }
}
