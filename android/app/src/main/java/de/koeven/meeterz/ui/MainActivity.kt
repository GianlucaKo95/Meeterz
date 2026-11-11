package de.koeven.meeterz.ui

import de.koeven.meeterz.tr
import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import com.mapbox.navigation.core.lifecycle.MapboxNavigationApp
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import de.koeven.meeterz.AppState
import de.koeven.meeterz.auth.AuthRepository
import de.koeven.meeterz.data.Profile
import de.koeven.meeterz.live.LocationSharingService
import de.koeven.meeterz.nav.NavigationController
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    companion object {
        /** App öffnen und Route zu diesem Ort zeigen (Losfahr-Erinnerung, Widget „Nächstes Ziel“) */
        fun planIntent(c: Context, name: String, lat: Double, lng: Double) = android.content.Intent(c, MainActivity::class.java)
            .setFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK or android.content.Intent.FLAG_ACTIVITY_CLEAR_TOP)
            .putExtra("plan_name", name).putExtra("plan_lat", lat).putExtra("plan_lng", lng)
    }

    private fun handle(intent: android.content.Intent?) {
        intent?.getStringExtra("action")?.let { action ->
            intent.removeExtra("action")
            AppState.scope.launch {
                when (action) {
                    "share" -> AppState.shareLocation(AppState.sharingMode)
                    "pause" -> AppState.setSharing(false)
                    "incognito" -> AppState.startIncognito(3600)
                }
            }
            return
        }
        intent?.getStringExtra("friend_id")?.let { id ->
            intent.removeExtra("friend_id")
            val f = AppState.friends.value.firstOrNull { it.friendId == id }
            val p = AppState.hub.positions.value[id]
            if (f != null && p != null) AppState.openPlace.value = NavigationController.Destination(f.displayName, p.lat, p.lng)
            return
        }
        val name = intent?.getStringExtra("plan_name") ?: return
        AppState.openPlace.value = NavigationController.Destination(name, intent.getDoubleExtra("plan_lat", 0.0), intent.getDoubleExtra("plan_lng", 0.0))
        intent.removeExtra("plan_name")
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handle(intent)
        MapboxNavigationApp.attach(this)
        lifecycle.addObserver(object : androidx.lifecycle.DefaultLifecycleObserver {
            override fun onStart(owner: androidx.lifecycle.LifecycleOwner) {
                AppState.foreground = true
                AppState.scope.launch { AppState.refreshFriends() }
            }
            override fun onStop(owner: androidx.lifecycle.LifecycleOwner) { AppState.foreground = false }
        })
        setContent {
            MeeterzTheme {
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) { Root() }
            }
        }
    }
}

@Composable
private fun Root() {
    val state by AppState.auth.state.collectAsState()
    when (val s = state) {
        AuthRepository.State.Loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
        AuthRepository.State.SignedOut -> LoginScreen()
        is AuthRepository.State.NeedsProfile -> OnboardingScreen(s.userId, s.suggestedName)
        is AuthRepository.State.Ready -> {
            LaunchedEffect(s.profile.id) { AppState.startSession(s.profile.id) }
            LocationPublisher(s.profile)
            MapScreen()
        }
    }
}

@Composable
private fun LoginScreen() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val error by AppState.auth.error.collectAsState()
    Column(
        Modifier.fillMaxSize().padding(32.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(tr("Meeterz"), style = MaterialTheme.typography.headlineLarge)
        Text(tr("Sieh, wo deine Freunde gerade sind, und trefft euch auf dem Weg."), style = MaterialTheme.typography.bodyLarge)
        Button(onClick = { scope.launch { AppState.auth.signInWithGoogle(context) } }, Modifier.fillMaxWidth()) {
            Text(tr("Mit Google anmelden"))
        }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
    }
}

@Composable
private fun OnboardingScreen(userId: String, suggestedName: String?) {
    val scope = rememberCoroutineScope()
    var name by remember { mutableStateOf(suggestedName ?: "") }
    var handle by remember { mutableStateOf("") }
    val error by AppState.auth.error.collectAsState()
    Column(Modifier.fillMaxSize().padding(32.dp), verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically)) {
        Text(tr("Profil anlegen"), style = MaterialTheme.typography.headlineMedium)
        OutlinedTextField(name, { name = it }, label = { Text(tr("Name")) }, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(handle, { handle = it }, label = { Text(tr("Benutzername")) }, modifier = Modifier.fillMaxWidth())
        Button(
            onClick = { scope.launch { AppState.auth.createProfile(userId, handle, name) } },
            enabled = name.isNotBlank() && handle.length >= 3,
            modifier = Modifier.fillMaxWidth(),
        ) { Text(tr("Weiter")) }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
    }
}

/** Nach der Erlaubnis den Dienst starten, der den Standort auch im Hintergrund sendet */
@Composable
private fun LocationPublisher(profile: Profile) {
    val context = LocalContext.current
    var granted by remember { mutableStateOf(hasLocation(context)) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
        granted = result[Manifest.permission.ACCESS_FINE_LOCATION] == true || result[Manifest.permission.ACCESS_COARSE_LOCATION] == true
    }
    LaunchedEffect(Unit) {
        if (!granted) {
            val wanted = mutableListOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
            if (Build.VERSION.SDK_INT >= 33) wanted += Manifest.permission.POST_NOTIFICATIONS
            launcher.launch(wanted.toTypedArray())
        }
    }
    LaunchedEffect(granted, profile.id) {
        if (granted) LocationSharingService.start(context)
    }
}

private fun hasLocation(context: Context) =
    ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
