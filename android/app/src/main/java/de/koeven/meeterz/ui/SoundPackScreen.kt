package de.koeven.meeterz.ui

import de.koeven.meeterz.tr
import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import de.koeven.meeterz.AppState
import de.koeven.meeterz.sound.SoundMoment
import de.koeven.meeterz.sound.SoundStore
import kotlinx.coroutines.launch

/**
 * Sound-Pack (iOS: Abschnitt in FriendsView): eigene Schnipsel je Moment aufnehmen (bis 5 s), anhören, löschen.
 * Freunde hören sie zum passenden Moment – auch im Auto. Ohne Aufnahme sagt die Sprachausgabe Bescheid.
 */
@Composable
fun SoundPackScreen(onClose: () -> Unit) {
    BackHandler(onBack = onClose)
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val versions by SoundStore.versions.collectAsState()
    val recording by SoundStore.recording.collectAsState()
    val busy by SoundStore.busy.collectAsState()
    var enabled by remember { mutableStateOf(SoundStore.enabled) }
    var pending by remember { mutableStateOf<SoundMoment?>(null) }
    val me = AppState.myId
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        val m = pending
        pending = null
        if (granted && m != null) SoundStore.startRecording(m)
    }
    fun record(m: SoundMoment) {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            SoundStore.startRecording(m)
        } else {
            pending = m
            permission.launch(Manifest.permission.RECORD_AUDIO)
        }
    }

    Surface(Modifier.fillMaxSize()) {
        Column(Modifier.statusBarsPadding()) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, tr("Zurück")) }
                Text(tr("Sound-Pack"), style = MaterialTheme.typography.titleLarge)
            }
            LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                item {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(tr("Schnipsel der Freunde abspielen"), fontWeight = FontWeight.SemiBold)
                            Text(tr("Zum passenden Moment, auch im Auto – Musik wird kurz leiser"), style = MaterialTheme.typography.bodySmall)
                        }
                        Switch(enabled, { enabled = it; SoundStore.enabled = it })
                    }
                    HorizontalDivider()
                    Text(tr("Deine Schnipsel"), fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 8.dp))
                    Text(tr("Nimm bis zu 5 Sekunden auf. Nur Freunde, deren Anfrage du angenommen hast, hören sie. Ohne Aufnahme sagt die Sprachausgabe Bescheid."),
                        style = MaterialTheme.typography.bodySmall)
                }
                items(SoundMoment.entries) { m ->
                    val has = me != null && (versions[me]?.get(m) ?: 0) > 0
                    val isRecording = recording == m
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(m.title, fontWeight = FontWeight.SemiBold)
                            Text(if (isRecording) tr("Nimmt auf … (tippen zum Beenden)") else if (has) tr("Aufgenommen") else "z. B. ${m.example}",
                                style = MaterialTheme.typography.bodySmall, color = if (isRecording) Color(0xFFD92E36) else Color.Unspecified)
                        }
                        if (has && !isRecording) {
                            IconButton(onClick = { scope.launch { SoundStore.preview(me!!, m) } }) { Icon(Icons.Default.PlayArrow, tr("Anhören")) }
                            IconButton(enabled = !busy, onClick = { scope.launch { SoundStore.removeMine(m) } }) { Icon(Icons.Default.Delete, tr("Löschen")) }
                        }
                        IconButton(enabled = !busy && (recording == null || isRecording),
                            onClick = { if (isRecording) SoundStore.stopRecording() else record(m) }) {
                            Icon(if (isRecording) Icons.Default.Stop else Icons.Default.Mic, if (isRecording) tr("Stopp") else "Aufnehmen",
                                tint = if (isRecording) Color(0xFFD92E36) else MaterialTheme.colorScheme.primary)
                        }
                    }
                }
            }
        }
    }
}
