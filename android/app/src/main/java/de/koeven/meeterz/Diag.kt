package de.koeven.meeterz

import android.content.Context
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Diagnoseprotokoll (wie Diag auf iOS): die letzten 1500 Zeilen, in den Einstellungen einsehbar und teilbar –
 * für Fehler, die nur im Auto auftreten. Schreibt zusätzlich ins Logcat.
 */
object Diag {
    private const val MAX = 1500
    private var file: File? = null
    private val lines = ArrayDeque<String>()
    private val format = SimpleDateFormat("dd.MM. HH:mm:ss", Locale.GERMANY)

    fun init(context: Context) {
        val f = File(context.filesDir, "diag.log")
        file = f
        synchronized(lines) { if (f.exists()) f.readLines().takeLast(MAX).forEach(lines::addLast) }
    }

    fun log(text: String) {
        Log.i("Meeterz", text)
        val line = "${format.format(Date())} $text"
        synchronized(lines) {
            lines.addLast(line)
            while (lines.size > MAX) lines.removeFirst()
            // Anhängen ist billig; alle 100 Zeilen die Datei auf die letzten 1500 kürzen
            runCatching {
                file?.appendText(line + "\n")
                if (lines.size % 100 == 0) file?.writeText(lines.joinToString("\n", postfix = "\n"))
            }
        }
    }

    val text: String get() = synchronized(lines) { lines.joinToString("\n") }

    fun clear() { synchronized(lines) { lines.clear(); runCatching { file?.writeText("") } } }
}
