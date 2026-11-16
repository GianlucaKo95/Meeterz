package de.koeven.meeterz.ui

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow

/** Persistente App-Einstellungen, die Karte und Oberfläche gemeinsam verwenden. */
object UiPreferences {
    private lateinit var prefs: android.content.SharedPreferences
    val appearance = MutableStateFlow("system") // system, light, dark
    val mapStyle = MutableStateFlow("satellite") // satellite (Vorgabe wie iOS), standard
    val map3d = MutableStateFlow(true)
    val staleHours = MutableStateFlow(6)

    fun init(context: Context) {
        prefs = context.applicationContext.getSharedPreferences("app", Context.MODE_PRIVATE)
        appearance.value = prefs.getString("appearance", "system") ?: "system"
        mapStyle.value = prefs.getString("android.map.style", "satellite") ?: "satellite"
        map3d.value = prefs.getBoolean("android.map.3d", true)
        staleHours.value = prefs.getInt("map.hideStaleHours", 6)
    }

    fun setAppearance(value: String) { appearance.value = value; prefs.edit().putString("appearance", value).apply() }
    fun setMapStyle(value: String) { mapStyle.value = value; prefs.edit().putString("android.map.style", value).apply() }
    fun setMap3d(value: Boolean) { map3d.value = value; prefs.edit().putBoolean("android.map.3d", value).apply() }
    fun setStaleHours(value: Int) { staleHours.value = value; prefs.edit().putInt("map.hideStaleHours", value).apply() }
}
