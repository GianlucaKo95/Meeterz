package de.koeven.meeterz.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

// Feldnamen wie in der Datenbank bzw. wie die iOS-App sie sendet – beide Apps teilen Tabellen und Live-Kanäle.

@Serializable
data class Profile(
    val id: String,
    val handle: String,
    @SerialName("display_name") val displayName: String,
    @SerialName("sharing_enabled") val sharingEnabled: Boolean = true,
    @SerialName("sharing_until") val sharingUntil: String? = null,
    @SerialName("incognito_until") val incognitoUntil: String? = null,
    @SerialName("hide_routes") val hideRoutes: Boolean? = null,
    @SerialName("avatar_version") val avatarVersion: Int? = null,
) {
    private fun instant(s: String?) = s?.let { runCatching { java.time.Instant.parse(it) }.getOrNull() }
    val incognitoUntilInstant get() = instant(incognitoUntil)
    val sharingUntilInstant get() = instant(sharingUntil)
    val isIncognito get() = incognitoUntilInstant?.isAfter(java.time.Instant.now()) == true
    /** „Bis ich es ausschalte“ = in 50 Jahren (wie iOS) */
    val isIncognitoIndefinitely get() = incognitoUntilInstant?.isAfter(java.time.Instant.now().plusSeconds(10L * 365 * 86400)) == true
    val routesHidden get() = hideRoutes == true
    /** Freunde sehen mich gerade (an, nicht abgelaufen, nicht inkognito) */
    val isSharingNow get() = sharingEnabled && (sharingUntilInstant?.isAfter(java.time.Instant.now()) ?: true) && !isIncognito
}

/** Zeile aus RPC `my_friends()` */
@Serializable
data class FriendRow(
    @SerialName("friendship_id") val friendshipId: String,
    @SerialName("friend_id") val friendId: String,
    val handle: String,
    @SerialName("display_name") val displayName: String,
    val status: String,
    val incoming: Boolean,
    val lat: Double? = null,
    val lng: Double? = null,
    val heading: Double? = null,
    val speed: Double? = null,
    @SerialName("location_updated_at") val locationUpdatedAt: String? = null,
    @SerialName("avatar_version") val avatarVersion: Int? = null,
) {
    val isAccepted get() = status == "accepted"
    val firstName get() = displayName.split(" ").firstOrNull() ?: displayName
    val initials get() = displayName.split(" ").take(2).mapNotNull { it.firstOrNull()?.toString() }.joinToString("").uppercase()
}

/** Live-Position im Kanal „loc:<id>“ (Schlüssel wie iOS: userId, lat, lng, heading, speed, ts in Sekunden) */
@Serializable
data class LivePosition(
    val userId: String,
    val lat: Double,
    val lng: Double,
    val heading: Double? = null,
    val speed: Double? = null,
    val ts: Double,
) {
    val ageSeconds get() = System.currentTimeMillis() / 1000.0 - ts
}

@Serializable
data class Gone(val userId: String)
