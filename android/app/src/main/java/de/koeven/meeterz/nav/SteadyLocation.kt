package de.koeven.meeterz.nav

import android.os.Looper
import com.mapbox.bindgen.Expected
import com.mapbox.bindgen.ExpectedFactory
import com.mapbox.common.location.DeviceLocationProvider
import com.mapbox.common.location.DeviceLocationProviderFactory
import com.mapbox.common.location.DeviceLocationProviderType
import com.mapbox.common.location.ExtendedLocationProviderParameters
import com.mapbox.common.location.Location
import com.mapbox.common.location.LocationError
import com.mapbox.common.location.LocationObserver
import com.mapbox.common.location.LocationServiceFactory
import de.koeven.meeterz.Diag
import de.koeven.meeterz.ev.ChargePlanner
import java.util.concurrent.ConcurrentHashMap

/**
 * Live-Standort für die Navigation mit Plausibilitätsprüfung (wie iOS SteadyLocation): Steht man an der Ampel und
 * das GPS springt durch Spiegelungen 20–50 m weg, rechnete die Navigation immer wieder neu (21.11.). Ein Sprung,
 * der schneller wäre als das Auto fährt, wird verworfen – die letzte gute Position gilt weiter. Bleibt der neue Ort
 * länger als 10 s bestehen, war es keine Störung, dann wird er übernommen.
 */
object SteadyLocation {
    /** Für `LocationOptions.Builder().locationProviderFactory(factory, MIXED)` – liefert nur echte Orte */
    val factory = DeviceLocationProviderFactory { request ->
        val inner: Expected<LocationError, DeviceLocationProvider> = LocationServiceFactory.getOrCreate().getDeviceLocationProvider(
            ExtendedLocationProviderParameters.Builder().deviceLocationProviderType(DeviceLocationProviderType.BEST).build(), request)
        inner.value?.let { ExpectedFactory.createValue<LocationError, DeviceLocationProvider>(Provider(it)) } ?: inner
    }

    /** Weiter als das Auto in der Zeit fahren kann (Tempo + 8 m/s Spielraum, mindestens 15 m) = Störung */
    fun plausible(distance: Double, seconds: Double, speed: Double): Boolean =
        distance <= maxOf(15.0, (maxOf(speed, 0.0) + 8) * maxOf(seconds, 0.5))

    private var accepted: Location? = null
    private var heldSince = 0L

    @Synchronized
    private fun filtered(location: Location): Location {
        val last = accepted
        if (last == null || location.horizontalAccuracy == null) { accepted = location; return location }
        val distance = ChargePlanner.distance(last.latitude, last.longitude, location.latitude, location.longitude)
        val seconds = (location.timestamp - last.timestamp) / 1000.0
        val tooLong = heldSince > 0 && System.currentTimeMillis() - heldSince > 10_000
        if (plausible(distance, seconds, location.speed ?: 0.0) || tooLong) {
            if (tooLong) Diag.log("GPS: neuer Ort nach 10 s übernommen (${distance.toInt()} m)")
            heldSince = 0L
            accepted = location
            return location
        }
        if (heldSince == 0L) {
            heldSince = System.currentTimeMillis()
            Diag.log("GPS-Sprung verworfen: ${distance.toInt()} m in ${"%.1f".format(seconds)} s bei " +
                "${((location.speed ?: 0.0) * 3.6).toInt()} km/h (±${location.horizontalAccuracy?.toInt()} m)")
        }
        // Letzte gute Position, aber mit aktueller Zeit und Geschwindigkeit
        return last.toBuilder().timestamp(location.timestamp).monotonicTimestamp(location.monotonicTimestamp)
            .speed(location.speed).speedAccuracy(location.speedAccuracy).build()
    }

    private class Provider(private val inner: DeviceLocationProvider) : DeviceLocationProvider by inner {
        private val wrapped = ConcurrentHashMap<LocationObserver, LocationObserver>()
        private fun wrap(observer: LocationObserver) = wrapped.getOrPut(observer) {
            LocationObserver { list -> observer.onLocationUpdateReceived(list.map(::filtered)) }
        }
        override fun addLocationObserver(observer: LocationObserver) = inner.addLocationObserver(wrap(observer))
        override fun addLocationObserver(observer: LocationObserver, looper: Looper) = inner.addLocationObserver(wrap(observer), looper)
        override fun removeLocationObserver(observer: LocationObserver) {
            wrapped.remove(observer)?.let { inner.removeLocationObserver(it) }
        }
    }
}
