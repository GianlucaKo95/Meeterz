package de.koeven.meeterz.widget

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.action.actionStartActivity
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.updateAll
import androidx.glance.background
import androidx.glance.color.ColorProvider
import androidx.glance.layout.Alignment
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import de.koeven.meeterz.AppState
import de.koeven.meeterz.ev.ChargePlanner
import de.koeven.meeterz.nav.NavigationController
import de.koeven.meeterz.ui.MainActivity
import de.koeven.meeterz.ui.km
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.text.DateFormat
import java.util.Date

/** Datenstand für die Widgets (wie WidgetSnapshot auf iOS) – in den Einstellungen gespeichert, damit Widgets ohne laufende App zeichnen */
@Serializable
data class WidgetSnapshot(
    val updated: Long = 0,
    val sharing: Boolean = false,
    val sharingUntil: Long? = null,
    val incognito: Boolean = false,
    val friends: List<Friend> = emptyList(),
    val meetup: Meetup? = null,
    val suggestion: Suggestion? = null,
) {
    @Serializable data class Suggestion(val title: String, val detail: String, val minutes: Int, val arrival: Long, val calendar: Boolean,
                                        val lat: Double, val lng: Double, val name: String)
    @Serializable data class Friend(val name: String, val distance: Double? = null, val heading: String? = null, val arrival: Long? = null)
    @Serializable data class Meetup(val place: String, val with: String, val friendArrival: Long? = null, val myArrival: Long? = null)
}

object WidgetSnapshotWriter {
    private val json = Json { ignoreUnknownKeys = true }
    private var lastSaved: WidgetSnapshot? = null
    private var lastReload = 0L

    fun read(context: Context): WidgetSnapshot =
        context.getSharedPreferences("widgets", 0).getString("snapshot", null)?.let { runCatching { json.decodeFromString<WidgetSnapshot>(it) }.getOrNull() }
            ?: WidgetSnapshot()

    /** Alle 30 s aus der Sitzung: speichern; Widgets neu zeichnen bei wichtigen Änderungen, sonst höchstens alle 15 Min. */
    suspend fun update(context: Context, force: Boolean = false) {
        val s = make()
        context.getSharedPreferences("widgets", 0).edit().putString("snapshot", json.encodeToString(s)).apply()
        val old = lastSaved
        val important = old == null || s.meetup != old.meetup || s.sharing != old.sharing || s.incognito != old.incognito ||
            s.friends.map { it.name } != old.friends.map { it.name } || s.suggestion?.title != old.suggestion?.title
        lastSaved = s
        if (force || important || System.currentTimeMillis() - lastReload > 15 * 60_000) {
            lastReload = System.currentTimeMillis()
            runCatching {
                FriendsWidget().updateAll(context); MeetupWidget().updateAll(context); SharingWidget().updateAll(context)
                SuggestionWidget().updateAll(context)
            }
        }
    }

    fun clear(context: Context) { context.getSharedPreferences("widgets", 0).edit().clear().apply(); lastSaved = null }

    private fun make(): WidgetSnapshot {
        val me = AppState.lastLocation
        val live = AppState.hub.positions.value
        val routes = AppState.routes.routes.value
        val friends = AppState.friends.value.filter { it.isAccepted }.mapNotNull { f ->
            val p = live[f.friendId] ?: return@mapNotNull null
            val r = routes[f.friendId]
            WidgetSnapshot.Friend(f.firstName, me?.let { ChargePlanner.distance(it.latitude, it.longitude, p.lat, p.lng) },
                r?.let { route -> route.destinationName?.let { "nach $it" } ?: "unterwegs" }, r?.eta?.epochSecond)
        }.sortedBy { it.distance ?: Double.MAX_VALUE }.take(6)
        val meetup = AppState.meetups.accepted.firstOrNull()?.let { m ->
            val friendEta = routes[m.otherId]?.takeIf { ChargePlanner.distance(it.destLat, it.destLng, m.lat, m.lng) < 300 }?.eta?.epochSecond
            val myEta = NavigationController.guidance.value?.takeIf { m.distanceTo(it.destination.lat, it.destination.lng) < 300 }
                ?.let { System.currentTimeMillis() / 1000 + it.remainingSeconds.toLong() }
            WidgetSnapshot.Meetup(m.placeName, m.otherName.substringBefore(" "), friendEta, myEta)
        }
        val p = AppState.profile
        return WidgetSnapshot(System.currentTimeMillis() / 1000, p?.isSharingNow == true, p?.sharingUntilInstant?.epochSecond,
            p?.isIncognito == true, friends, meetup,
            de.koeven.meeterz.suggest.RouteSuggestions.current.value?.let { sg ->
                WidgetSnapshot.Suggestion(sg.title, sg.subtitle, sg.minutes, sg.arrival / 1000, sg.calendarStart != null, sg.lat, sg.lng, sg.name.ifEmpty { sg.title })
            })
    }
}

private fun clock(seconds: Long) = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(seconds * 1000))
private val petrol = ColorProvider(Color(0xFF062A32), Color(0xFF062A32))
private val mint = ColorProvider(Color(0xFF6FF3DA), Color(0xFF6FF3DA))
private val white = ColorProvider(Color.White, Color.White)
private val muted = ColorProvider(Color(0xB3FFFFFF), Color(0xB3FFFFFF))

@Composable
private fun Card(content: @Composable () -> Unit) {
    Column(GlanceModifier.fillMaxSize().background(petrol).cornerRadius(20.dp).padding(14.dp)
        .clickable(actionStartActivity<MainActivity>())) { content() }
}

@Composable
private fun Header(text: String) = Text(text.uppercase(), style = TextStyle(color = mint, fontSize = 11.sp, fontWeight = FontWeight.Bold))

/** Freunde: wer in der Nähe ist und wer unterwegs ist */
class FriendsWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val s = WidgetSnapshotWriter.read(context)
        provideContent {
            Card {
                Header("Freunde")
                Spacer(GlanceModifier.height(6.dp))
                if (s.friends.isEmpty()) Text("Gerade teilt niemand seinen Standort.", style = TextStyle(color = muted, fontSize = 13.sp))
                for (f in s.friends.take(4)) Row(GlanceModifier.fillMaxWidth().padding(vertical = 3.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(f.name, style = TextStyle(color = white, fontSize = 14.sp, fontWeight = FontWeight.Bold))
                    Text("  " + listOfNotNull(f.distance?.let { km(it) }, f.heading, f.arrival?.let { "an ${clock(it)}" }).joinToString(" · "),
                        style = TextStyle(color = muted, fontSize = 12.sp), maxLines = 1)
                }
            }
        }
    }
}

/** Nächstes Treffen: wo ihr euch trefft und wann dein Freund ankommt */
class MeetupWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val m = WidgetSnapshotWriter.read(context).meetup
        provideContent {
            Card {
                Header("Treffen")
                Spacer(GlanceModifier.height(6.dp))
                if (m == null) Text("Kein Treffen geplant.", style = TextStyle(color = muted, fontSize = 13.sp))
                else {
                    Text(m.place, style = TextStyle(color = white, fontSize = 17.sp, fontWeight = FontWeight.Bold), maxLines = 2)
                    Text("mit ${m.with}", style = TextStyle(color = muted, fontSize = 13.sp))
                    m.friendArrival?.let { Text("${m.with} an ${clock(it)}", style = TextStyle(color = mint, fontSize = 13.sp, fontWeight = FontWeight.Bold)) }
                    m.myArrival?.let { Text("Du an ${clock(it)}", style = TextStyle(color = white, fontSize = 13.sp)) }
                }
            }
        }
    }
}

/** Teilen: ob du gerade deinen Standort teilst – und wie lange noch */
class SharingWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val s = WidgetSnapshotWriter.read(context)
        provideContent {
            Card {
                Header("Standort")
                Spacer(GlanceModifier.height(6.dp))
                val (title, sub) = when {
                    s.incognito -> "Inkognito" to "Niemand sieht dich"
                    s.sharing -> "Teilst live" to (s.sharingUntil?.let { "bis ${clock(it)}" } ?: "dauerhaft")
                    else -> "Pausiert" to "Freunde sehen dich nicht"
                }
                Text(title, style = TextStyle(color = if (s.sharing && !s.incognito) mint else white, fontSize = 18.sp, fontWeight = FontWeight.Bold))
                Text(sub, style = TextStyle(color = muted, fontSize = 13.sp))
            }
        }
    }
}

/** Nächstes Ziel: Termin mit Ort oder häufiges Ziel mit Fahrzeit – Tippen zeigt die Route */
class SuggestionWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val sg = WidgetSnapshotWriter.read(context).suggestion
        provideContent {
            val open = sg?.let { actionStartActivity(MainActivity.planIntent(context, it.name, it.lat, it.lng)) } ?: actionStartActivity<MainActivity>()
            Column(GlanceModifier.fillMaxSize().background(petrol).cornerRadius(20.dp).padding(14.dp).clickable(open)) {
                Header(if (sg?.calendar == true) "Termin" else "Nächstes Ziel")
                Spacer(GlanceModifier.height(6.dp))
                if (sg == null) Text("Gerade kein Vorschlag.", style = TextStyle(color = muted, fontSize = 13.sp))
                else {
                    Text(sg.title, style = TextStyle(color = white, fontSize = 17.sp, fontWeight = FontWeight.Bold), maxLines = 2)
                    Text("${sg.minutes} Min.", style = TextStyle(color = mint, fontSize = 22.sp, fontWeight = FontWeight.Bold))
                    Text(sg.detail, style = TextStyle(color = muted, fontSize = 12.sp), maxLines = 1)
                }
            }
        }
    }
}

class FriendsWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget = FriendsWidget() }
class MeetupWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget = MeetupWidget() }
class SharingWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget = SharingWidget() }
class SuggestionWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget = SuggestionWidget() }
