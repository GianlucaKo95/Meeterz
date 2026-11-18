package de.koeven.meeterz.ui

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.net.Uri
import android.provider.MediaStore
import android.widget.Toast
import android.widget.VideoView
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.imePadding
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.BatteryChargingFull
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Coffee
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material.icons.filled.Flag
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material.icons.filled.Place
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.FileProvider
import de.koeven.meeterz.AppState
import de.koeven.meeterz.data.ConvoyFeed
import de.koeven.meeterz.data.StoriesStore
import de.koeven.meeterz.data.Story
import de.koeven.meeterz.tr
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/** Video aufnehmen, höchstens 15 s und 24 MB (Bucket-Grenze 25 MB) */
private class CaptureStoryVideo : ActivityResultContracts.CaptureVideo() {
    override fun createIntent(context: Context, input: Uri): Intent = super.createIntent(context, input)
        .putExtra(MediaStore.EXTRA_DURATION_LIMIT, 15)
        .putExtra(MediaStore.EXTRA_SIZE_LIMIT, 24L * 1024 * 1024)
}

private fun captureUri(context: Context, video: Boolean): Uri {
    val dir = File(context.cacheDir, "capture").apply { mkdirs() }
    val file = File(dir, "story.${if (video) "mp4" else "jpg"}").apply { delete() }
    return FileProvider.getUriForFile(context, "${context.packageName}.files", file)
}

/** Neue Story (wie iOS StoryComposer): aufnehmen, Ort und Text ergänzen, teilen */
@Composable
fun StoryComposer(onDismiss: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var captured by remember { mutableStateOf<Pair<Uri, Boolean>?>(null) }
    var pending by remember { mutableStateOf<Pair<Uri, Boolean>?>(null) }
    var caption by remember { mutableStateOf("") }
    var placeName by remember { mutableStateOf<String?>(null) }
    val posting by StoriesStore.posting.collectAsState()
    val here = AppState.lastLocation

    val photo = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { ok -> if (ok) captured = pending }
    val video = rememberLauncherForActivityResult(CaptureStoryVideo()) { ok ->
        val p = pending
        if (ok && p != null) {
            if (StoriesStore.videoSeconds(p.first) > 16) Toast.makeText(context, tr("Video ist länger als 15 Sekunden."), Toast.LENGTH_LONG).show()
            else captured = p
        }
    }
    LaunchedEffect(here) {
        here ?: return@LaunchedEffect
        placeName = withContext(Dispatchers.IO) {
            @Suppress("DEPRECATION")
            runCatching { android.location.Geocoder(context).getFromLocation(here.latitude, here.longitude, 1)?.firstOrNull() }.getOrNull()
                ?.let { a -> a.featureName?.takeIf { it != a.subThoroughfare } ?: a.thoroughfare ?: a.locality }
        } ?: tr("Unterwegs")
    }

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            val focus = androidx.compose.ui.platform.LocalFocusManager.current
            // imePadding: mit Tastatur schrumpft das Bild, Textfeld und „Story teilen“ bleiben sichtbar (wie iOS)
            Column(Modifier.statusBarsPadding().navigationBarsPadding().imePadding().padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Box(Modifier.fillMaxWidth()) {
                    TextButton(onClick = onDismiss, modifier = Modifier.align(Alignment.CenterStart)) { Text(tr("Abbrechen")) }
                    Text(tr("Neue Story"), Modifier.align(Alignment.Center), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                }
                val c = captured
                if (c == null) {
                    Spacer(Modifier.weight(1f))
                    Button(onClick = { captureUri(context, false).let { pending = it to false; photo.launch(it) } }, Modifier.fillMaxWidth()) {
                        Icon(Icons.Default.PhotoCamera, null, Modifier.size(18.dp)); Spacer(Modifier.width(8.dp)); Text(tr("Foto aufnehmen"))
                    }
                    OutlinedButton(onClick = { captureUri(context, true).let { pending = it to true; video.launch(it) } }, Modifier.fillMaxWidth()) {
                        Icon(Icons.Default.Videocam, null, Modifier.size(18.dp)); Spacer(Modifier.width(8.dp)); Text(tr("Video (bis 15 s)"))
                    }
                    Spacer(Modifier.weight(1f))
                } else {
                    Box(Modifier.weight(1f).fillMaxWidth().background(Color.Black, RoundedCornerShape(16.dp))
                        .clip(RoundedCornerShape(16.dp)).clickable { focus.clearFocus() }) {
                        if (c.second) LoopingVideo(c.first)
                        else {
                            val bmp = remember(c.first) {
                                context.contentResolver.openInputStream(c.first)?.use { s -> BitmapFactory.decodeStream(s, null, BitmapFactory.Options().apply { inSampleSize = 4 }) }
                            }
                            bmp?.let { Image(it.asImageBitmap(), null, Modifier.fillMaxSize(), contentScale = ContentScale.Fit) }
                        }
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.Place, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(18.dp))
                        Text(placeName ?: tr("Ort wird ermittelt …"), Modifier.padding(start = 8.dp), style = MaterialTheme.typography.bodyMedium)
                    }
                    OutlinedTextField(caption, { caption = it.take(140) }, Modifier.fillMaxWidth(), placeholder = { Text(tr("Text (optional)")) }, maxLines = 3,
                        keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(imeAction = androidx.compose.ui.text.input.ImeAction.Done),
                        keyboardActions = androidx.compose.foundation.text.KeyboardActions(onDone = { focus.clearFocus() }))
                    Button(enabled = !posting && here != null, onClick = {
                        val loc = here ?: return@Button
                        scope.launch {
                            if (StoriesStore.post(c.first, c.second, caption, placeName, loc.latitude, loc.longitude)) {
                                Toast.makeText(context, tr("Story geteilt"), Toast.LENGTH_SHORT).show(); onDismiss()
                            } else Toast.makeText(context, tr("Story konnte nicht gespeichert werden."), Toast.LENGTH_LONG).show()
                        }
                    }, modifier = Modifier.fillMaxWidth()) {
                        if (posting) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp) else Text(tr("Story teilen"))
                    }
                    Text(tr("24 Stunden für deine Freunde sichtbar – an diesem Ort auf der Karte."),
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
}

@Composable
private fun LoopingVideo(uri: Uri, loop: Boolean = true, onEnd: () -> Unit = {}) {
    AndroidView(factory = { ctx ->
        VideoView(ctx).apply {
            setVideoURI(uri)
            setOnPreparedListener { it.isLooping = loop; start() }
            setOnCompletionListener { onEnd() }
        }
    }, modifier = Modifier.fillMaxSize(), onRelease = { it.stopPlayback() })
}

/** Vollbild (wie iOS StoryViewer): Stories einer Person nacheinander, Tippen rechts weiter, links zurück */
@Composable
fun StoryViewer(stories: List<Story>, onDismiss: () -> Unit, onNavigate: (name: String, lat: Double, lng: Double) -> Unit) {
    val scope = rememberCoroutineScope()
    var index by remember { mutableStateOf(0) }
    val story = stories.getOrNull(index)
    var file by remember { mutableStateOf<File?>(null) }
    var failed by remember { mutableStateOf(false) }
    var viewers by remember { mutableStateOf<List<StoriesStore.Viewer>?>(null) }
    var showViewers by remember { mutableStateOf(false) }
    val friends by AppState.friends.collectAsState()
    LaunchedEffect(story?.id) {
        viewers = null; showViewers = false
        story?.takeIf { it.userId == AppState.myId }?.let { viewers = StoriesStore.viewers(it) }
    }
    fun step(d: Int) { val n = index + d; if (n < 0) return; if (n >= stories.size) onDismiss() else index = n }

    LaunchedEffect(story?.id) {
        file = null; failed = false
        val s = story ?: return@LaunchedEffect
        val f = StoriesStore.file(s)
        if (f == null) { failed = true; return@LaunchedEffect }
        file = f
        StoriesStore.markSeen(s)
        if (!s.isVideo) { delay(6_000); step(1) }
    }

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize().background(Color.Black)) {
            val f = file
            when {
                story == null -> {}
                f != null && story.isVideo -> androidx.compose.runtime.key(story.id) { LoopingVideo(Uri.fromFile(f), loop = false) { step(1) } }
                f != null -> remember(f) { BitmapFactory.decodeFile(f.absolutePath) }?.let {
                    Image(it.asImageBitmap(), null, Modifier.fillMaxSize(), contentScale = ContentScale.Fit)
                }
                failed -> Text(tr("Story nicht verfügbar"), Modifier.align(Alignment.Center), color = Color.White)
                else -> CircularProgressIndicator(Modifier.align(Alignment.Center), color = Color.White)
            }
            Row(Modifier.fillMaxSize()) {
                Box(Modifier.weight(1f).fillMaxSize().clickable(indication = null, interactionSource = null) { step(-1) })
                Box(Modifier.weight(1f).fillMaxSize().clickable(indication = null, interactionSource = null) { step(1) })
            }
            story?.let { s ->
                Column(Modifier.statusBarsPadding().navigationBarsPadding().padding(16.dp).fillMaxSize(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        stories.indices.forEach { i ->
                            Box(Modifier.weight(1f).height(3.dp).background(Color.White.copy(alpha = if (i <= index) 1f else 0.35f), RoundedCornerShape(2.dp)))
                        }
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Avatar(s.userId, s.displayName, 36.dp)
                        Column(Modifier.weight(1f).padding(start = 10.dp)) {
                            Text(if (s.userId == AppState.myId) tr("Du") else s.displayName, color = Color.White, fontWeight = FontWeight.SemiBold)
                            Text(listOfNotNull(s.placeName, runCatching { clockAt(java.time.Instant.parse(s.createdAt)) }.getOrNull()).joinToString(" · "),
                                color = Color.White.copy(alpha = 0.8f), style = MaterialTheme.typography.bodySmall)
                        }
                        if (s.userId == AppState.myId) IconButton(onClick = {
                            scope.launch { StoriesStore.delete(s); if (index >= stories.size - 1) onDismiss() }
                        }) { Icon(Icons.Default.Delete, tr("Story löschen"), tint = Color.White) }
                        IconButton(onClick = onDismiss) { Icon(Icons.Default.Close, tr("Schließen"), tint = Color.White) }
                    }
                    Spacer(Modifier.weight(1f))
                    s.caption?.let {
                        Text(it, Modifier.fillMaxWidth().background(Color.Black.copy(alpha = 0.5f), RoundedCornerShape(12.dp)).padding(12.dp),
                            color = Color.White, fontWeight = FontWeight.Medium)
                    }
                    viewers?.let { v ->
                        TextButton(onClick = { showViewers = true }, enabled = v.isNotEmpty()) {
                            Icon(Icons.Default.Visibility, null, tint = Color.White, modifier = Modifier.size(18.dp)); Spacer(Modifier.width(8.dp))
                            Text(tr("Gesehen von %lld", v.size), color = Color.White, fontWeight = FontWeight.SemiBold)
                        }
                    }
                    OutlinedButton(onClick = { onDismiss(); onNavigate(s.placeName ?: tr("Story-Ort"), s.lat, s.lng) }, Modifier.fillMaxWidth()) {
                        Text(tr("Hin navigieren"), color = Color.White)
                    }
                }
            }
            if (showViewers) viewers?.let { v ->
                Surface(Modifier.align(Alignment.BottomCenter).fillMaxWidth().navigationBarsPadding(),
                    shape = RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp), color = MaterialTheme.colorScheme.background) {
                    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Box(Modifier.fillMaxWidth()) {
                            Text(tr("Gesehen von"), Modifier.align(Alignment.Center), style = MaterialTheme.typography.titleMedium)
                            TextButton(onClick = { showViewers = false }, modifier = Modifier.align(Alignment.CenterEnd)) { Text(tr("Fertig")) }
                        }
                        LazyColumn(Modifier.heightIn(max = 360.dp)) {
                            items(v, key = { it.viewer }) { w ->
                                val f = friends.firstOrNull { it.friendId == w.viewer }
                                Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                                    Avatar(w.viewer, f?.displayName ?: "?", 36.dp)
                                    Text(f?.displayName ?: tr("Jemand"), Modifier.weight(1f).padding(start = 12.dp))
                                    Text(runCatching { clockAt(java.time.Instant.parse(w.seenAt)) }.getOrDefault(""),
                                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/** Kartenpin mit Akzent-Ring für ungesehene Stories (wie AvatarRenderer story: auf iOS) */
internal fun storyRing(pin: Bitmap): Bitmap {
    val pad = 10
    val out = Bitmap.createBitmap(pin.width + 2 * pad, pin.height + 2 * pad, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(out)
    canvas.drawBitmap(pin, pad.toFloat(), pad.toFloat(), null)
    canvas.drawCircle(out.width / 2f, out.height / 2f, out.width / 2f - 4, Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = MeeterzColors.mint.toArgb(); style = Paint.Style.STROKE; strokeWidth = 7f
    })
    return out
}

/** Fahrten (wie iOS TripsView): laufender Konvoi-Feed oben, frühere Fahrten darunter */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TripsSheet(onDismiss: () -> Unit) {
    val current by ConvoyFeed.key.collectAsState()
    val trips by ConvoyFeed.trips.collectAsState()
    val friends by AppState.friends.collectAsState()
    var open by remember { mutableStateOf<Pair<String, String>?>(null) }
    LaunchedEffect(Unit) { ConvoyFeed.loadTrips() }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = MaterialTheme.colorScheme.background) {
        Column(Modifier.navigationBarsPadding().padding(horizontal = 16.dp).padding(bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            val o = open
            if (o != null) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = { open = null }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, tr("Zurück"), tint = MaterialTheme.colorScheme.primary) }
                    Text(o.second, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                }
                ConvoyFeedList(o.first)
                return@Column
            }
            Box(Modifier.fillMaxWidth()) {
                Text(tr("Fahrten"), Modifier.align(Alignment.Center), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                TextButton(onClick = onDismiss, modifier = Modifier.align(Alignment.CenterEnd)) { Text(tr("Fertig")) }
            }
            current?.let { k ->
                Text(tr("Jetzt"), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                TripRow(tr("Konvoi-Feed"), null) { open = k to tr("Konvoi") }
            }
            Text(tr("Fahrten"), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (trips.isEmpty()) Text(tr("Noch keine gemeinsamen Fahrten. Fährst du mit Freunden zum selben Ziel, entsteht hier eine Chronik."),
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                items(trips, key = { it.convoyKey }) { t ->
                    val names = t.members.mapNotNull { id -> friends.firstOrNull { it.friendId == id }?.firstName }.joinToString(", ")
                    val start = runCatching {
                        java.time.format.DateTimeFormatter.ofLocalizedDateTime(java.time.format.FormatStyle.MEDIUM, java.time.format.FormatStyle.SHORT)
                            .format(java.time.Instant.parse(t.startedAt).atZone(java.time.ZoneId.systemDefault()))
                    }.getOrDefault("")
                    TripRow(t.destName ?: tr("Fahrt"), tr("%@ · %@", start, names)) { open = t.convoyKey to (t.destName ?: tr("Fahrt")) }
                }
            }
        }
    }
}

@Composable
private fun TripRow(title: String, subtitle: String?, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surface, RoundedCornerShape(12.dp)).clickable(onClick = onClick).padding(12.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, fontWeight = FontWeight.SemiBold)
            subtitle?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1) }
        }
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun ConvoyFeedList(key: String) {
    val entries by ConvoyFeed.entries.collectAsState()
    val shown by ConvoyFeed.shownKey.collectAsState()
    val stories by StoriesStore.stories.collectAsState()
    androidx.compose.runtime.DisposableEffect(key) {
        AppState.scope.launch { ConvoyFeed.show(key) }
        onDispose { AppState.scope.launch { ConvoyFeed.show(null) } }
    }
    // ponytail: alle 15 s neu laden statt Live-Kanal
    LaunchedEffect(key) { while (true) { delay(15_000); ConvoyFeed.load(key) } }
    if (shown == key && entries.isEmpty()) { CircularProgressIndicator(Modifier.padding(24.dp)); return }
    LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        items(if (shown == key) entries else emptyList(), key = { it.id }) { e ->
            Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(when (e.kind) {
                    "joined" -> Icons.Default.DirectionsCar
                    "pause" -> Icons.Default.Coffee
                    "charge" -> Icons.Default.BatteryChargingFull
                    "message" -> Icons.AutoMirrored.Filled.Chat
                    "story" -> Icons.Default.PhotoCamera
                    else -> Icons.Default.Flag
                }, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(20.dp))
                Column(Modifier.weight(1f).padding(start = 12.dp)) {
                    Text(ConvoyFeed.describe(e), style = MaterialTheme.typography.bodyMedium)
                    Text(runCatching { clockAt(java.time.Instant.parse(e.createdAt)) }.getOrDefault(""),
                        style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                if (e.kind == "story") {
                    val s = stories.firstOrNull { it.id == e.storyId }
                    if (s != null) TextButton(onClick = { StoriesStore.viewing.value = listOf(s) }) { Text(tr("Ansehen")) }
                    else Text(tr("abgelaufen"), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
}
