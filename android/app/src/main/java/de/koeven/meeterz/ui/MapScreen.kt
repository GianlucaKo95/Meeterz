package de.koeven.meeterz.ui

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import com.mapbox.geojson.Point
import com.mapbox.maps.CameraOptions
import com.mapbox.maps.MapView
import com.mapbox.maps.Style
import com.mapbox.maps.plugin.annotation.annotations
import com.mapbox.maps.plugin.annotation.generated.PointAnnotationManager
import com.mapbox.maps.plugin.annotation.generated.PointAnnotationOptions
import com.mapbox.maps.plugin.annotation.generated.createPointAnnotationManager
import com.mapbox.maps.plugin.locationcomponent.createDefault2DPuck
import com.mapbox.maps.plugin.locationcomponent.location
import com.mapbox.maps.plugin.viewport.viewport
import de.koeven.meeterz.AppState

/** Karte mit eigener Position und den Freunden (Live-Position, sonst letzte bekannte) */
@Composable
fun MapScreen() {
    val context = LocalContext.current
    val friends by AppState.friends.collectAsState()
    val live by AppState.hub.positions.collectAsState()
    val mapView = remember {
        MapView(context).apply {
            mapboxMap.loadStyle(Style.STANDARD)
            mapboxMap.setCamera(CameraOptions.Builder().zoom(13.0).build())
            location.updateSettings {
                enabled = true
                locationPuck = createDefault2DPuck(withBearing = true)
            }
            viewport.transitionTo(viewport.makeFollowPuckViewportState())
        }
    }
    val annotations: PointAnnotationManager = remember { mapView.annotations.createPointAnnotationManager() }

    LaunchedEffect(friends, live) {
        annotations.deleteAll()
        for (f in friends.filter { it.isAccepted }) {
            val pos = live[f.friendId]
            val lat = pos?.lat ?: f.lat ?: continue
            val lng = pos?.lng ?: f.lng ?: continue
            annotations.create(
                PointAnnotationOptions()
                    .withPoint(Point.fromLngLat(lng, lat))
                    .withIconImage(initialsBubble(f.initials))
                    .withTextField(f.firstName)
                    .withTextOffset(listOf(0.0, 2.2))
                    .withTextSize(12.0)
            )
        }
    }

    AndroidView(factory = { mapView }, modifier = Modifier.fillMaxSize())
}

/** Runder Mint-Kreis mit Initialen (wie die Freundes-Pins auf iOS, ohne Profilbild) */
private fun initialsBubble(initials: String): Bitmap {
    val size = 96
    val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = MeeterzColors.mint.toArgb() }
    val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = android.graphics.Color.WHITE; style = Paint.Style.STROKE; strokeWidth = 6f }
    canvas.drawCircle(size / 2f, size / 2f, size / 2f - 4, fill)
    canvas.drawCircle(size / 2f, size / 2f, size / 2f - 4, ring)
    val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = MeeterzColors.petrol.toArgb()
        textSize = 36f
        textAlign = Paint.Align.CENTER
        isFakeBoldText = true
    }
    canvas.drawText(initials, size / 2f, size / 2f - (text.descent() + text.ascent()) / 2, text)
    return bitmap
}
