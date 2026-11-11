package de.koeven.meeterz.car

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface
import androidx.car.app.CarContext
import androidx.car.app.Screen
import androidx.car.app.model.Action
import androidx.car.app.model.CarIcon
import androidx.car.app.model.Pane
import androidx.car.app.model.PaneTemplate
import androidx.car.app.model.Row
import androidx.car.app.model.Template
import androidx.compose.ui.graphics.toArgb
import androidx.core.graphics.drawable.IconCompat
import de.koeven.meeterz.AppState
import de.koeven.meeterz.ev.ChargePlanner
import de.koeven.meeterz.nav.NavigationController
import de.koeven.meeterz.social.Passengers
import de.koeven.meeterz.tr
import de.koeven.meeterz.ui.FriendPalette
import de.koeven.meeterz.ui.MeeterzColors
import de.koeven.meeterz.ui.TimelineItem
import java.text.DateFormat
import java.util.Date

/** Wer fährt zum selben Ziel wie ich bzw. ist schon dort (für die Zeitleiste im Auto) – null ohne Führung oder ohne jemanden */
fun carArrivals(): Pair<String, List<TimelineItem>>? {
    val g = NavigationController.guidance.value ?: return null
    val d = g.destination
    val live = AppState.hub.positions.value
    val routes = AppState.routes.routes.value
    val riding = Passengers.riding
    val friends = AppState.friends.value.filter { it.isAccepted && it.friendId !in riding }.mapNotNull { f ->
        val p = live[f.friendId]
        val here = p != null && ChargePlanner.distance(p.lat, p.lng, d.lat, d.lng) < 150
        val eta = routes[f.friendId]?.takeIf { ChargePlanner.distance(it.destLat, it.destLng, d.lat, d.lng) < 300 }?.eta?.epochSecond
        if (!here && eta == null) null else TimelineItem(f.friendId, f.firstName, FriendPalette.routeColor(f.friendId), eta, here)
    }
    if (friends.isEmpty()) return null
    val me = TimelineItem("me", tr("Du"), MeeterzColors.mint, System.currentTimeMillis() / 1000 + g.remainingSeconds.toLong(), false)
    return d.name to (friends + me)
}

/**
 * Zeitleiste als Bild (Android Auto erlaubt keine eigenen Einblendungen auf der Karte): links jetzt, rechts die späteste
 * Ankunft, jeder ein Punkt in seiner Farbe; Namen abwechselnd über und unter der Linie (wie ArrivalTimeline).
 */
fun timelineBitmap(items: List<TimelineItem>, width: Int = 900, height: Int = 260): Bitmap {
    val bmp = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    val c = Canvas(bmp)
    val axis = height / 2f
    val inset = 24f
    val labelWidth = 200f
    val now = System.currentTimeMillis() / 1000
    val span = maxOf((items.mapNotNull { it.eta }.maxOrNull() ?: now) - now, 5 * 60L).toFloat()
    val line = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xFF3A4547.toInt(); strokeWidth = 6f; strokeCap = Paint.Cap.ROUND }
    c.drawLine(inset, axis, width - inset, axis, line)
    val name = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = android.graphics.Color.WHITE; textSize = 38f; typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD); textAlign = Paint.Align.CENTER }
    val time = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 36f; textAlign = Paint.Align.CENTER; fontFeatureSettings = "tnum" }
    val dot = Paint(Paint.ANTI_ALIAS_FLAG)
    val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xFF111719.toInt() }
    val placed = items.map { item ->
        val f = if (item.here || item.eta == null) 0f else ((item.eta - now) / span).coerceIn(0f, 1f)
        item to (inset + (width - 2 * inset) * f)
    }.sortedBy { it.second }
    val last = floatArrayOf(Float.NEGATIVE_INFINITY, Float.NEGATIVE_INFINITY)
    for ((item, x) in placed) {
        val row = when {
            x - last[0] >= labelWidth -> 0
            x - last[1] >= labelWidth -> 1
            else -> if (last[0] < last[1]) 0 else 1
        }
        last[row] = x
        c.drawCircle(x, axis, 20f, ring)
        dot.color = item.color.toArgb()
        c.drawCircle(x, axis, 15f, dot)
        val lx = x.coerceIn(labelWidth / 2, width - labelWidth / 2)
        val (nameY, timeY) = if (row == 0) axis - 76f to axis - 36f else axis + 72f to axis + 112f
        c.drawText(item.name, lx, nameY, name)
        time.color = if (item.here) 0xFFFFC857.toInt() else 0xFF8D9A9C.toInt()
        c.drawText(if (item.here) tr("da") else item.eta?.let { DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(it * 1000)) } ?: "–", lx, timeY, time)
    }
    return bmp
}

/** „Wer ist wann da“ im Auto: Zeitleiste als Bild, darunter die Ankunftszeiten als Liste */
class CarArrivalsScreen(carContext: CarContext) : Screen(carContext) {
    override fun onGetTemplate(): Template {
        val data = carArrivals()
        val pane = Pane.Builder()
        if (data == null) {
            pane.addRow(Row.Builder().setTitle(tr("Gerade fährt niemand mit dir im Konvoi.")).build())
        } else {
            val (_, items) = data
            if (carContext.carAppApiLevel >= 4) pane.setImage(CarIcon.Builder(IconCompat.createWithBitmap(timelineBitmap(items))).build())
            val fmt = DateFormat.getTimeInstance(DateFormat.SHORT)
            items.sortedWith(compareBy({ if (it.here) 0 else 1 }, { it.eta ?: Long.MAX_VALUE })).take(4).forEach { i ->
                pane.addRow(Row.Builder().setTitle(i.name).addText(if (i.here) tr("da") else i.eta?.let { tr("an %@", fmt.format(Date(it * 1000))) } ?: "–").build())
            }
        }
        return PaneTemplate.Builder(pane.build()).setTitle(data?.first ?: tr("Wer ist wann da")).setHeaderAction(Action.BACK).build()
    }
}
