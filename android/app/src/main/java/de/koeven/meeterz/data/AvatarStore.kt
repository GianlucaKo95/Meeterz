package de.koeven.meeterz.data

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Shader
import android.net.Uri
import de.koeven.meeterz.AppState
import de.koeven.meeterz.Diag
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.storage.storage
import io.ktor.http.ContentType
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * Profilbilder (wie AvatarStore auf iOS): privater Bucket „avatars“, Pfad „<user_id>/avatar.jpg“ (Storage-Policy:
 * nur Freunde). Version aus profiles.avatar_version bzw. my_friends; lokal je Version zwischengespeichert.
 */
object AvatarStore {
    private const val BUCKET = "avatars"
    private lateinit var context: Context
    private val _images = MutableStateFlow<Map<String, Bitmap>>(emptyMap())
    val images: StateFlow<Map<String, Bitmap>> = _images
    private val versions = mutableMapOf<String, Int>()
    val busy = MutableStateFlow(false)

    fun init(context: Context) { this.context = context.applicationContext }

    private fun path(id: String) = "${id.lowercase()}/avatar.jpg"
    private fun cacheDir() = File(context.cacheDir, "avatars").apply { mkdirs() }
    private fun cacheFile(id: String, v: Int) = File(cacheDir(), "${id.lowercase()}-$v.jpg")

    /** Neue oder geänderte Bilder laden, Bilder ohne Freundschaft/Bild entfernen */
    suspend fun sync(friends: List<FriendRow>, me: Profile?) {
        val wanted = mutableMapOf<String, Int>()
        friends.filter { it.isAccepted && (it.avatarVersion ?: 0) > 0 }.forEach { wanted[it.friendId] = it.avatarVersion!! }
        me?.takeIf { (it.avatarVersion ?: 0) > 0 }?.let { wanted[it.id] = it.avatarVersion!! }
        val current = _images.value.toMutableMap()
        current.keys.filter { it !in wanted }.forEach { current.remove(it); versions.remove(it) }
        for ((id, v) in wanted) {
            if (versions[id] == v) continue
            load(id, v)?.let { current[id] = it; versions[id] = v }
        }
        _images.value = current
    }

    private suspend fun load(id: String, v: Int): Bitmap? = withContext(Dispatchers.IO) {
        val file = cacheFile(id, v)
        if (file.exists()) return@withContext BitmapFactory.decodeFile(file.absolutePath)
        val data = runCatching { Backend.client.storage.from(BUCKET).downloadAuthenticated(path(id)) }.getOrNull() ?: return@withContext null
        cacheDir().listFiles()?.filter { it.name.startsWith("${id.lowercase()}-") }?.forEach { it.delete() }
        file.writeBytes(data)
        BitmapFactory.decodeByteArray(data, 0, data.size)
    }

    /** Bild aus der Galerie: mittig quadratisch, 256 px, JPEG 80 – hochladen */
    suspend fun setMine(uri: Uri) {
        val me = AppState.profile?.id ?: return
        busy.value = true
        runCatching {
            val data = withContext(Dispatchers.IO) {
                val src = context.contentResolver.openInputStream(uri)!!.use { BitmapFactory.decodeStream(it) }
                val side = minOf(src.width, src.height)
                val square = Bitmap.createBitmap(src, (src.width - side) / 2, (src.height - side) / 2, side, side)
                val scaled = Bitmap.createScaledBitmap(square, 256, 256, true)
                ByteArrayOutputStream().also { scaled.compress(Bitmap.CompressFormat.JPEG, 80, it) }.toByteArray()
            }
            Backend.client.storage.from(BUCKET).upload(path(me), data) { upsert = true; contentType = ContentType.Image.JPEG }
            val v = Backend.client.postgrest.rpc("set_avatar_version").decodeAs<Int>()
            cacheFile(me, v).writeBytes(data)
            versions[me] = v
            _images.value = _images.value + (me to BitmapFactory.decodeByteArray(data, 0, data.size))
            AppState.auth.reload()
        }.onFailure { Diag.log("Profilbild nicht gespeichert: ${it.message}") }
        busy.value = false
    }

    suspend fun removeMine() {
        val me = AppState.profile?.id ?: return
        busy.value = true
        runCatching {
            Backend.client.storage.from(BUCKET).delete(listOf(path(me)))
            Backend.client.postgrest.rpc("set_avatar_version", buildJsonObject { put("remove", true) })
            versions.remove(me)
            _images.value = _images.value - me
            AppState.auth.reload()
        }.onFailure { Diag.log("Profilbild nicht entfernt: ${it.message}") }
        busy.value = false
    }

    /** Runder Kartenpin mit Profilbild und weißem Rand (Initialen, falls kein Bild) */
    fun pin(image: Bitmap, size: Int = 96): Bitmap {
        val out = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        val scaled = Bitmap.createScaledBitmap(image, size - 8, size - 8, true)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { shader = BitmapShader(scaled, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP) }
        canvas.translate(4f, 4f)
        canvas.drawCircle((size - 8) / 2f, (size - 8) / 2f, (size - 8) / 2f, paint)
        canvas.translate(-4f, -4f)
        canvas.drawCircle(size / 2f, size / 2f, size / 2f - 3, Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = android.graphics.Color.WHITE; style = Paint.Style.STROKE; strokeWidth = 6f
        })
        return out
    }
}
