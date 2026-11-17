package de.koeven.meeterz.nav

import de.koeven.meeterz.AppState
import de.koeven.meeterz.tr

/** Fortbewegungsart für Routen (wie TravelMode.swift; in Android Auto immer Auto). Schlüssel = travel_mode in Supabase. */
enum class TravelMode(val key: String, val profile: String, val matrixProfile: String) {
    CAR("car", "driving-traffic", "mapbox/driving"),
    BIKE("bike", "cycling", "mapbox/cycling"),
    WALK("walk", "walking", "mapbox/walking");

    val title: String get() = when (this) { CAR -> tr("Auto"); BIKE -> tr("Fahrrad"); WALK -> tr("Zu Fuß") }

    /** „Max ist zu Fuß unterwegs“ */
    val activity: String get() = when (this) { CAR -> tr("mit dem Auto"); BIKE -> tr("mit dem Fahrrad"); WALK -> tr("zu Fuß") }

    companion object {
        fun of(key: String?) = entries.firstOrNull { it.key == key } ?: CAR

        var saved: TravelMode
            get() = of(AppState.appContextOrNull()?.getSharedPreferences("app", 0)?.getString("nav.travelMode", null))
            set(v) { AppState.appContextOrNull()?.getSharedPreferences("app", 0)?.edit()?.putString("nav.travelMode", v.key)?.apply() }

        /** Treffpunkt „auf der Route“ (z. B. Raststätte) nur, wenn beide mit dem Auto fahren */
        fun canMeetOnRoute(a: TravelMode, b: TravelMode?) = a == CAR && (b ?: CAR) == CAR
    }
}
