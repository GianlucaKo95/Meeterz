package de.koeven.meeterz.nav

import android.app.PendingIntent
import android.os.Looper
import android.util.Log
import com.mapbox.bindgen.Expected
import com.mapbox.bindgen.ExpectedFactory
import com.mapbox.common.Cancelable
import com.mapbox.common.location.DeviceLocationProvider
import com.mapbox.common.location.DeviceLocationProviderFactory
import com.mapbox.common.location.GetLocationCallback
import com.mapbox.common.location.Location
import com.mapbox.common.location.LocationError
import com.mapbox.common.location.LocationObserver
import com.mapbox.common.location.LocationProviderRequest
import com.mapbox.common.location.LocationServiceFactory
import de.koeven.meeterz.ev.ChargePlanner

/**
 * Hält die Position im Stand fest, bevor sie Mapbox erreicht (wie StandstillFilter.swift).
 * An der Ampel springt die GPS-Position über den Abbiegepunkt in der Kreuzungsmitte, und Mapbox wechselte zum
 * nächsten Abschnitt – Anzeige und Ansage, obwohl man noch nicht abgebogen war. Steht das Auto (zwei Meldungen
 * unter ~4 km/h), bleibt die Position auf dem Haltepunkt; frei erst nach zwei Meldungen über ~5 km/h (gut 1 s)
 * oder wenn das Auto sehr weit weg ist.
 */
class StandstillFilter {
    /** Eingabe ohne Android-Klassen (testbar); speed < 0 = unbekannt */
    data class Fix(val lat: Double, val lng: Double, val speed: Double, val bearing: Double?)

    companion object {
        const val STANDING = 1.0
        const val MOVING = 1.5
        const val CONFIRMATIONS = 2
        const val RELEASE = 40.0
    }

    private var anchor: Fix? = null
    private var standingCount = 0
    private var movingCount = 0
    var frozen = false
        private set

    /** Liefert die Position für Mapbox: die echte oder den Haltepunkt (dann Tempo 0) */
    fun filter(fix: Fix): Fix {
        val a = anchor
        if (frozen && a != null) {
            val away = ChargePlanner.distance(a.lat, a.lng, fix.lat, fix.lng)
            movingCount = if (fix.speed >= MOVING || (fix.speed < 0 && away > 15)) movingCount + 1 else 0
            if (movingCount >= CONFIRMATIONS || away > RELEASE) {
                frozen = false; standingCount = 0; movingCount = 0; anchor = null
                return fix
            }
            return a.copy(speed = 0.0)
        }
        standingCount = if (fix.speed >= 0 && fix.speed < STANDING) standingCount + 1 else 0
        if (standingCount >= CONFIRMATIONS) {
            frozen = true; anchor = fix; movingCount = 0
            return fix.copy(speed = 0.0)
        }
        return fix
    }
}

/** Standortquelle für Mapbox: die des Geräts, mit StandstillFilter dazwischen */
class FilteredLocationProviderFactory : DeviceLocationProviderFactory {
    override fun build(request: LocationProviderRequest?): Expected<LocationError, DeviceLocationProvider> {
        val inner = LocationServiceFactory.getOrCreate().getDeviceLocationProvider(request)
        return inner.value?.let { ExpectedFactory.createValue<LocationError, DeviceLocationProvider>(FilteredProvider(it)) } ?: inner
    }
}

private class FilteredProvider(private val inner: DeviceLocationProvider) : DeviceLocationProvider by inner {
    private val filter = StandstillFilter()
    private var wasFrozen = false
    private val wrappers = mutableMapOf<LocationObserver, LocationObserver>()

    private fun apply(loc: Location): Location {
        val out = filter.filter(StandstillFilter.Fix(loc.latitude, loc.longitude, loc.speed ?: -1.0, loc.bearing))
        if (filter.frozen != wasFrozen) {
            wasFrozen = filter.frozen
            Log.i("Meeterz", if (wasFrozen) "Stand erkannt – Position für die Navigation festgehalten"
                else "Fährt wieder – Position freigegeben (${((loc.speed ?: 0.0) * 3.6).toInt()} km/h)")
        }
        if (out.lat == loc.latitude && out.lng == loc.longitude && out.speed == (loc.speed ?: -1.0)) return loc
        return Location.Builder()
            .source(loc.source)
            .latitude(out.lat).longitude(out.lng)
            .altitude(loc.altitude)
            .timestamp(loc.timestamp)
            .monotonicTimestamp(loc.monotonicTimestamp)
            .horizontalAccuracy(loc.horizontalAccuracy)
            .verticalAccuracy(loc.verticalAccuracy)
            .bearing(out.bearing ?: loc.bearing)
            .bearingAccuracy(loc.bearingAccuracy)
            .speed(0.0)
            .speedAccuracy(loc.speedAccuracy)
            .build()
    }

    private fun wrap(observer: LocationObserver) = wrappers.getOrPut(observer) {
        LocationObserver { locations -> observer.onLocationUpdateReceived(locations.map(::apply).toMutableList()) }
    }

    override fun addLocationObserver(observer: LocationObserver) = inner.addLocationObserver(wrap(observer))
    override fun addLocationObserver(observer: LocationObserver, looper: Looper) = inner.addLocationObserver(wrap(observer), looper)
    override fun removeLocationObserver(observer: LocationObserver) {
        wrappers.remove(observer)?.let { inner.removeLocationObserver(it) }
    }
    override fun getLastLocation(callback: GetLocationCallback): Cancelable = inner.getLastLocation(callback)
    override fun requestLocationUpdates(pendingIntent: PendingIntent) = inner.requestLocationUpdates(pendingIntent)
    override fun removeLocationUpdates(pendingIntent: PendingIntent) = inner.removeLocationUpdates(pendingIntent)
}
