package de.koeven.meeterz.ui

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Typeface

/** Verkehrszeichen 205 (Vorfahrt achten) und 206 (Stopp), selbst gezeichnet wie auf iOS (RightOfWaySigns.image) */
object RoadSigns {
    private val cache = mutableMapOf<Boolean, Bitmap>()

    fun bitmap(stop: Boolean): Bitmap = cache.getOrPut(stop) {
        val bmp = Bitmap.createBitmap(96, 96, Bitmap.Config.ARGB_8888)
        val c = Canvas(bmp)
        val red = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = android.graphics.Color.rgb(204, 20, 26) }
        val white = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = android.graphics.Color.WHITE }
        if (!stop) {
            c.drawPath(Path().apply { moveTo(4f, 10f); lineTo(92f, 10f); lineTo(48f, 90f); close() }, red)
            c.drawPath(Path().apply { moveTo(22f, 20f); lineTo(74f, 20f); lineTo(48f, 68f); close() }, white)
        } else {
            fun octagon(r: Float) = Path().apply {
                for (i in 0 until 8) {
                    val a = i * Math.PI / 4 + Math.PI / 8
                    val x = (48 + r * Math.cos(a)).toFloat(); val y = (48 + r * Math.sin(a)).toFloat()
                    if (i == 0) moveTo(x, y) else lineTo(x, y)
                }
                close()
            }
            c.drawPath(octagon(45f), white)
            c.drawPath(octagon(39.6f), red)
            val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = android.graphics.Color.WHITE; textSize = 25f; typeface = Typeface.DEFAULT_BOLD; textAlign = Paint.Align.CENTER
            }
            c.drawText("STOP", 48f, 48f - (text.descent() + text.ascent()) / 2, text)
        }
        bmp
    }
}
