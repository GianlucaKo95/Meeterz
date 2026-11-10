package de.koeven.meeterz.nav

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import java.util.Locale
import java.util.UUID

/**
 * Sprachausgabe der Navigation (iOS: MeeterzSpeechSynthesizer). Musik wird währenddessen leiser („Ducking“) und
 * danach wieder laut; eine neue Abbiegeansage ersetzt eine laufende.
 */
class Speaker(context: Context) {
    private val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val attributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
        .build()
    private val focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
        .setAudioAttributes(attributes)
        .build()
    private var ready = false
    private val pending = mutableListOf<String>()
    var muted = false

    private lateinit var tts: TextToSpeech

    init {
        tts = TextToSpeech(context.applicationContext) { status ->
            ready = status == TextToSpeech.SUCCESS
            if (ready) {
                tts.language = Locale.GERMANY
                tts.setAudioAttributes(attributes)
                pending.forEach { speakNow(it) }
            }
            pending.clear()
        }
        tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) = Unit
            // Erst wenn nichts mehr gesprochen wird, die Musik wieder laut
            override fun onDone(utteranceId: String?) { if (!tts.isSpeaking) audio.abandonAudioFocusRequest(focus) }
            @Deprecated("Deprecated in Java")
            override fun onError(utteranceId: String?) { audio.abandonAudioFocusRequest(focus) }
        })
    }

    /** Abbiegeansage: ersetzt eine laufende */
    fun say(text: String) {
        if (muted) return
        Log.i("Meeterz", "Ansage: $text")
        if (!ready) { pending.clear(); pending += text; return }
        speakNow(text)
    }

    /** Hinweis (z. B. Nachricht eines Freundes): hinten anstellen, keine Abbiegeansage abbrechen */
    fun announce(text: String) {
        if (muted || !ready) return
        speakNow(text, TextToSpeech.QUEUE_ADD)
    }

    private fun speakNow(text: String, mode: Int = TextToSpeech.QUEUE_FLUSH) {
        audio.requestAudioFocus(focus)
        val params = Bundle().apply { putInt(TextToSpeech.Engine.KEY_PARAM_STREAM, AudioManager.STREAM_MUSIC) }
        tts.speak(text, mode, params, UUID.randomUUID().toString())
    }

    fun stop() {
        tts.stop()
        audio.abandonAudioFocusRequest(focus)
    }
}
