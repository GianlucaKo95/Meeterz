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
 * länger als 10 s bestehen, war es keine Störung, dann wird er übernommen. Dazu: im Stand Position und Richtung
 * fest, Messungen hinter der Fahrtrichtung und Nachzügler verworfen, langsam die letzte verlässliche Richtung.
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

    /** Unterschied zweier Richtungen in Grad (0–180) */
    fun angle(a: Double, b: Double): Double = Math.abs(((a - b + 540) % 360) - 180)

    /** Liegt der neue Ort hinter dem alten, obwohl man vorwärts fährt? (wie iOS) */
    fun behind(lastLat: Double, lastLng: Double, lat: Double, lng: Double, course: Double): Boolean {
        val dLat = lat - lastLat
        val dLng = (lng - lastLng) * Math.cos(Math.toRadians(lastLat))
        val bearing = (Math.toDegrees(Math.atan2(dLng, dLat)) + 360) % 360
        return angle(bearing, course) > 120
    }

    private var accepted: Location? = null
    private var heldSince = 0L
    /** Letzte verlässliche Fahrtrichtung (aus einer Messung in Fahrt) */
    private var goodCourse: Double? = null

    @Synchronized
    private fun filtered(location: Location): Location {
        val speed = location.speed ?: -1.0
        // Richtung nur aus Fahrt mit sicherer Richtung merken – langsam ist die GPS-Richtung Zufall
        val bearing = location.bearing
        if (speed >= 3 && bearing != null && (location.bearingAccuracy ?: 0.0) < 30) goodCourse = bearing
        val last = accepted
        if (last == null || location.horizontalAccuracy == null) { accepted = location; return location }
        // Nachzügler nie verwenden – sie ließen den Pfeil zurückspringen
        if (location.timestamp <= last.timestamp) return held(last, location, standing = false)
        val distance = ChargePlanner.distance(last.latitude, last.longitude, location.latitude, location.longitude)
        val seconds = (location.timestamp - last.timestamp) / 1000.0
        val tooLong = heldSince > 0 && System.currentTimeMillis() - heldSince > 10_000
        // Stillstand: Position und Richtung fest, Tempo 0 – kein Vor- und Zurückkriechen (wie iOS, 21.11.)
        if (speed >= 0 && speed < 0.8 && distance < 25 && !tooLong) return held(last, location, standing = true)
        val course = goodCourse
        val reason = when {
            !plausible(distance, seconds, speed) -> "Sprung"
            speed >= 3 && distance > 10 && course != null &&
                behind(last.latitude, last.longitude, location.latitude, location.longitude, course) -> "rückwärts"
            else -> null
        }
        if (reason == null || tooLong) {
            if (tooLong) Diag.log("GPS: neuer Ort nach 10 s übernommen (${distance.toInt()} m)")
            heldSince = 0L
            accepted = location
            return if (speed < 2 && course != null) location.toBuilder().bearing(course).bearingAccuracy(10.0).build() else location
        }
        if (heldSince == 0L) {
            heldSince = System.currentTimeMillis()
            Diag.log("GPS-$reason verworfen: ${distance.toInt()} m in ${"%.1f".format(seconds)} s bei " +
                "${(maxOf(speed, 0.0) * 3.6).toInt()} km/h (±${location.horizontalAccuracy?.toInt()} m)")
        }
        return held(last, location, standing = false)
    }

    /** Letzte gute Position mit aktueller Zeit (im Stand mit Tempo 0) */
    private fun held(last: Location, now: Location, standing: Boolean): Location =
        last.toBuilder().timestamp(maxOf(now.timestamp, last.timestamp + 1)).monotonicTimestamp(now.monotonicTimestamp)
            .speed(if (standing) 0.0 else now.speed).speedAccuracy(now.speedAccuracy)
            .bearing(goodCourse ?: last.bearing).build()

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
