package de.koeven.meeterz.ui

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import androidx.activity.ComponentActivity
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
import androidx.compose.runtime.DisposableEffect
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
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
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
        Text("Meeterz", style = MaterialTheme.typography.headlineLarge)
        Text("Sieh, wo deine Freunde gerade sind, und trefft euch auf dem Weg.", style = MaterialTheme.typography.bodyLarge)
        Button(onClick = { scope.launch { AppState.auth.signInWithGoogle(context) } }, Modifier.fillMaxWidth()) {
            Text("Mit Google anmelden")
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
        Text("Profil anlegen", style = MaterialTheme.typography.headlineMedium)
        OutlinedTextField(name, { name = it }, label = { Text("Name") }, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(handle, { handle = it }, label = { Text("Benutzername") }, modifier = Modifier.fillMaxWidth())
        Button(
            onClick = { scope.launch { AppState.auth.createProfile(userId, handle, name) } },
            enabled = name.isNotBlank() && handle.length >= 3,
            modifier = Modifier.fillMaxWidth(),
        ) { Text("Weiter") }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
    }
}

/** Standort holen (nach Erlaubnis) und an die Freunde senden, solange die App offen ist */
@SuppressLint("MissingPermission")
@Composable
private fun LocationPublisher(profile: Profile) {
    val context = LocalContext.current
    var granted by remember { mutableStateOf(hasLocation(context)) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
        granted = result.values.any { it }
    }
    LaunchedEffect(Unit) {
        if (!granted) launcher.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION))
    }
    if (!granted) return
    DisposableEffect(profile.id) {
        val manager = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val listener = LocationListener { loc ->
            AppState.scope.launch { AppState.hub.publish(loc, profile.id, profile.sharingEnabled) }
        }
        val provider = if (manager.isProviderEnabled(LocationManager.GPS_PROVIDER)) LocationManager.GPS_PROVIDER else LocationManager.NETWORK_PROVIDER
        manager.requestLocationUpdates(provider, 2_000L, 5f, listener)
        onDispose { manager.removeUpdates(listener) }
    }
}

private fun hasLocation(context: Context) =
    ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
