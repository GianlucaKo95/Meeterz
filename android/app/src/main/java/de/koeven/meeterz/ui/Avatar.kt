package de.koeven.meeterz.ui

import de.koeven.meeterz.tr
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.koeven.meeterz.data.AvatarStore
import de.koeven.meeterz.data.Profile
import kotlinx.coroutines.launch

/** Profilbild oder Initialen im Kreis (wie AvatarView auf iOS) */
@Composable
fun Avatar(userId: String, name: String, size: Dp = 40.dp) {
    val images by AvatarStore.images.collectAsState()
    val image = images[userId]
    Box(Modifier.size(size).clip(CircleShape).background(MeeterzColors.mint), contentAlignment = Alignment.Center) {
        if (image != null) {
            Image(image.asImageBitmap(), name, Modifier.size(size), contentScale = ContentScale.Crop)
        } else {
            val initials = name.split(" ").filter { it.isNotBlank() }.take(2).joinToString("") { it.take(1).uppercase() }
            Text(initials, color = MeeterzColors.petrol, fontWeight = FontWeight.Bold, fontSize = (size.value * 0.38).sp)
        }
    }
}

/** Eigenes Profilbild: antippen = aus der Galerie wählen, „Entfernen“ = Initialen */
@Composable
fun AvatarEditor(p: Profile) {
    val scope = rememberCoroutineScope()
    val busy by AvatarStore.busy.collectAsState()
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) scope.launch { AvatarStore.setMine(uri) }
    }
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.clickable(enabled = !busy) {
            picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
        }) { Avatar(p.id, p.displayName, 64.dp) }
        if ((p.avatarVersion ?: 0) > 0) TextButton(enabled = !busy, onClick = { scope.launch { AvatarStore.removeMine() } }) { Text(tr("Entfernen")) }
    }
}
