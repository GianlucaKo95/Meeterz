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

@Composable
fun MeeterzTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    MaterialTheme(
        colorScheme = if (dark) darkColorScheme(primary = MeeterzColors.mint, background = MeeterzColors.petrol, surface = Color(0xFF0B3740))
        else lightColorScheme(primary = MeeterzColors.mintLight),
        content = content,
    )
}
