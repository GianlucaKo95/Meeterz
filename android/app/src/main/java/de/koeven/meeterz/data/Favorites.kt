package de.koeven.meeterz.data

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.util.UUID

/** Gespeicherte Orte – wie iOS nur auf dem Gerät (je Konto), Adressen gehen nicht an den Server */
@Serializable
data class Favorite(
    val id: String = UUID.randomUUID().toString(),
    val kind: String,   // home, work, other
    val label: String,
    val address: String? = null,
    val lat: Double,
    val lng: Double,
)

class FavoritesStore(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences("favorites", Context.MODE_PRIVATE)
    private val json = Json { ignoreUnknownKeys = true }
    private var userId: String? = null
    private val _items = MutableStateFlow<List<Favorite>>(emptyList())
    val items: StateFlow<List<Favorite>> = _items

    fun load(userId: String) {
        this.userId = userId
        _items.value = prefs.getString(key(userId), null)?.let { runCatching { json.decodeFromString<List<Favorite>>(it) }.getOrNull() } ?: emptyList()
    }

    /** Zuhause und Arbeit gibt es nur einmal (wird ersetzt), eigene Favoriten kommen dazu */
    fun save(kind: String, label: String, address: String?, lat: Double, lng: Double) {
        val rest = if (kind == "other") _items.value else _items.value.filter { it.kind != kind }
        _items.value = rest + Favorite(kind = kind, label = label, address = address, lat = lat, lng = lng)
        persist()
    }

    fun remove(id: String) { _items.value = _items.value.filter { it.id != id }; persist() }

    private fun key(id: String) = "favorites.${id.lowercase()}"
    private fun persist() { userId?.let { prefs.edit().putString(key(it), json.encodeToString(_items.value)).apply() } }
}
