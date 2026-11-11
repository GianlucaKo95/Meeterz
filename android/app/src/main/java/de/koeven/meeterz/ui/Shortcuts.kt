package de.koeven.meeterz.ui

import android.content.Context
import android.content.Intent
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import de.koeven.meeterz.AppState
import de.koeven.meeterz.R
import de.koeven.meeterz.tr

/**
 * App-Kurzbefehle (Gegenstück zu den Siri-Kurzbefehlen auf iOS): langes Drücken aufs App-Symbol, Startbildschirm,
 * Assistant. Favoriten („Nach Zuhause“), die nächsten Freunde („Zu Lisa“) und Teilen/Pausieren/Inkognito.
 */
object Shortcuts {
    private var last: List<String> = emptyList()

    fun update(context: Context) {
        val favs = AppState.favorites.items.value.sortedBy { if (it.kind == "home") 0 else if (it.kind == "work") 1 else 2 }.take(2)
        val friends = AppState.friends.value.filter { it.isAccepted && AppState.hub.positions.value[it.friendId] != null }.take(1)
        val key = favs.map { it.id + it.label } + friends.map { it.friendId } + (AppState.profile?.isSharingNow?.toString() ?: "")
        if (key == last) return
        last = key
        val icon = IconCompat.createWithResource(context, R.drawable.ic_launcher_foreground)
        fun open() = Intent(context, MainActivity::class.java).setAction(Intent.ACTION_VIEW)
        val list = buildList {
            for (f in favs) add(ShortcutInfoCompat.Builder(context, "fav-${f.id}").setShortLabel(tr("Nach %@", f.label)).setIcon(icon)
                .setIntent(MainActivity.planIntent(context, f.label, f.lat, f.lng).setAction(Intent.ACTION_VIEW)).build())
            for (f in friends) add(ShortcutInfoCompat.Builder(context, "friend-${f.friendId}").setShortLabel(tr("Zu %@", f.firstName)).setIcon(icon)
                .setIntent(open().putExtra("friend_id", f.friendId)).build())
            val sharing = AppState.profile?.isSharingNow == true
            add(ShortcutInfoCompat.Builder(context, "sharing").setShortLabel(if (sharing) tr("Teilen pausieren") else tr("Standort teilen")).setIcon(icon)
                .setIntent(open().putExtra("action", if (sharing) "pause" else "share")).build())
            add(ShortcutInfoCompat.Builder(context, "incognito").setShortLabel(tr("Inkognito")).setIcon(icon)
                .setIntent(open().putExtra("action", "incognito")).build())
        }
        runCatching { ShortcutManagerCompat.setDynamicShortcuts(context, list.take(ShortcutManagerCompat.getMaxShortcutCountPerActivity(context))) }
    }
}
