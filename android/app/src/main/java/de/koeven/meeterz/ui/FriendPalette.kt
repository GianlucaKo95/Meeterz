package de.koeven.meeterz.ui

import androidx.compose.ui.graphics.Color

/**
 * Eine Farbe je Freund (wie FriendPalette auf iOS): aus dem ersten Byte der Nutzer-ID, damit derselbe Freund auf
 * iPhone und Android gleich aussieht. `color` für Profilbilder und Punkte, `routeColor` kräftiger für Routenlinien.
 */
object FriendPalette {
    private val colors = listOf(0xFFFF8A3D, 0xFFB894F5, 0xFF4DE3C4, 0xFF4DA3FF, 0xFFFF6B9E, 0xFFFFC23D).map { Color(it) }
    private val routeColors = listOf(0xFFFF6E00, 0xFFD933FF, 0xFF00E6FF, 0xFF2673FF, 0xFFFF1A8C, 0xFFFFED00).map { Color(it) }
    /** Dunkle Umrandung unter Routen, damit sie auch auf heller Karte lesbar bleiben */
    val routeCasing = Color(0xEB050A12)

    private fun index(id: String) = (id.take(2).toIntOrNull(16) ?: id.hashCode() and 0xFF) % colors.size

    fun color(id: String) = colors[index(id)]
    fun routeColor(id: String) = routeColors[index(id)]
}
