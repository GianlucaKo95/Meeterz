package de.koeven.meeterz

import android.app.Application
import com.mapbox.common.MapboxOptions

class MeeterzApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        MapboxOptions.accessToken = getString(R.string.mapbox_access_token)
    }
}
