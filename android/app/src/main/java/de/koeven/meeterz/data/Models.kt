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
)

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
