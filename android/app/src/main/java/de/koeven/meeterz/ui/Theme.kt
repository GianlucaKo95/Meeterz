package de.koeven.meeterz.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/** Farben wie Theme.swift: Mint als Akzent, Petrol als Grund, Bernstein für „unterwegs/da“ */
object MeeterzColors {
    val mint = Color(0xFF6FF3DA)
    val mintLight = Color(0xFF0B7F70)
    val petrol = Color(0xFF062A32)
    val amber = Color(0xFFFFC857)
}

/**
 * Vollständiges Farbschema wie Theme.swift: neutrale Rampe mit leichtem Petrol-Stich, Mint als einziger Akzent.
 * Alle Rollen gesetzt, damit nichts aus dem lila Material-Standard durchscheint.
 */
private val Dark = darkColorScheme(
    primary = MeeterzColors.mint, onPrimary = Color(0xFF062A32),
    primaryContainer = Color(0xFF1F282A), onPrimaryContainer = Color(0xFFECF1F1),
    secondary = Color(0xFF8D9A9C), onSecondary = Color(0xFF111719),
    secondaryContainer = Color(0xFF283234), onSecondaryContainer = Color(0xFFECF1F1),
    tertiary = MeeterzColors.amber, onTertiary = Color(0xFF111719),
    background = Color(0xFF111719), onBackground = Color(0xFFECF1F1),
    surface = Color(0xFF182022), onSurface = Color(0xFFECF1F1),
    surfaceVariant = Color(0xFF1F282A), onSurfaceVariant = Color(0xFF8D9A9C),
    surfaceContainerLowest = Color(0xFF111719), surfaceContainerLow = Color(0xFF151C1E), surfaceContainer = Color(0xFF182022),
    surfaceContainerHigh = Color(0xFF1F282A), surfaceContainerHighest = Color(0xFF263033),
    surfaceTint = Color.Transparent,
    outline = Color(0xFF3A4547), outlineVariant = Color(0xFF283234),
    error = Color(0xFFFF5A5F), onError = Color(0xFF111719),
)

private val Light = lightColorScheme(
    primary = MeeterzColors.mintLight, onPrimary = Color.White,
    primaryContainer = Color(0xFFE9EEEE), onPrimaryContainer = Color(0xFF121A1C),
    secondary = Color(0xFF5A6769), onSecondary = Color.White,
    secondaryContainer = Color(0xFFE2E8E8), onSecondaryContainer = Color(0xFF121A1C),
    tertiary = Color(0xFFA86B00), onTertiary = Color.White,
    background = Color(0xFFF3F5F5), onBackground = Color(0xFF121A1C),
    surface = Color.White, onSurface = Color(0xFF121A1C),
    surfaceVariant = Color(0xFFE9EEEE), onSurfaceVariant = Color(0xFF5A6769),
    surfaceContainerLowest = Color.White, surfaceContainerLow = Color(0xFFF7F9F9), surfaceContainer = Color(0xFFF3F5F5),
    surfaceContainerHigh = Color(0xFFEDF1F1), surfaceContainerHighest = Color(0xFFE6EBEB),
    surfaceTint = Color.Transparent,
    outline = Color(0xFFB9C3C4), outlineVariant = Color(0xFFDCE2E2),
    error = Color(0xFFD92D35), onError = Color.White,
)

@Composable
fun MeeterzTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = if (isSystemInDarkTheme()) Dark else Light, content = content)
}
