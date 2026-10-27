# Meeterz Privacy Policy
Last updated: October 2026 · [Deutsche Fassung](datenschutz) (the German version is legally binding)

## 1. Controller

Gianluca Köhni
Waldstrasse 1c
47199 Duisburg
Germany
Email: gk@koeven.de

## 2. What data Meeterz processes

| Data | Purpose | Legal basis |
|---|---|---|
| Account: Apple ID identifier or email address, display name, username | Sign-in, so friends can find you | Art. 6(1)(b) GDPR (contract) |
| Friendships and requests | Deciding who may see your location | Art. 6(1)(b) GDPR |
| **Live location** (position, heading, speed) | Sent to accepted friends while you share | Art. 6(1)(a) GDPR (consent) |
| Last known position | Shown to friends immediately when they open the app | Art. 6(1)(a) GDPR |
| Active route (destination, route, arrival times) | Shown to friends and used to find meeting points | Art. 6(1)(a) GDPR |
| Meetup proposals with optional time | Making plans; the time is used for the "time to leave" reminder | Art. 6(1)(b) GDPR |
| Short messages to friends (e.g. "Almost there") | Letting friends know while on the road | Art. 6(1)(b) GDPR |
| Voice clips (optional, max. 5 seconds) | Played for accepted friends at certain moments | Art. 6(1)(a) GDPR |
| Profile photo (optional, scaled to 256 × 256 px) | Shown to friends on the map and in lists; only accepted friends can access it | Art. 6(1)(a) GDPR |
| Device push token | Notifications about requests and meetups, and location requests (see below) | Art. 6(1)(a) GDPR |
| Incognito setting (until when, "hide routes") | Making you invisible to friends; friends are not told that you are incognito | Art. 6(1)(a) GDPR |
| Favorites (home, work, your own named places) | Quick destinations for navigation. **Stored on your device only**, not on our servers | Art. 6(1)(b) GDPR |
| **Vehicle data** (optional, EVs with a connection you set up): battery level, range, charging/charging power, outside temperature, odometer, speed, parked yes/no, car position | Charge planning, charging display, learning consumption, detecting your parking spot. Visible only to you, never to friends | Art. 6(1)(a) GDPR |
| Parked car (optional, "Remember parked car") | Remembering where you parked; detected via vehicle data, CarPlay disconnect or the iPhone's motion activity (car → walking). **Stored on your device only** | Art. 6(1)(a) GDPR |
| Learned consumption per speed range | More accurate charge planning. **Stored on your device only** | Art. 6(1)(b) GDPR |
| Diagnostic log (crashes, hangs, technical events) | Troubleshooting. **On your device only**; it only leaves the device if you share it yourself | Art. 6(1)(f) GDPR (legitimate interest in a working app) |

### Background location and requests from friends

- With the "Always" permission, Meeterz can update your location even when the app is closed. To save battery, the app only monitors significant location changes while you are stationary and switches to precise location when you move, navigate or use CarPlay.
- If a friend opens the map and your position is out of date, our server sends a **silent push** to your device (via Apple Push). Your device then briefly sends your current location. The push contains no location and no message. This only happens for accepted friends and only while you are sharing – never in incognito mode or while sharing is paused.
- Navigation **voice guidance** is generated entirely on your device (Apple system voices). No voice data is transmitted.
- **Vehicle data** is only received if you set up the connection yourself (e.g. via a Home Assistant service that sends your car's data to Meeterz using a secret device ID). You can disconnect at any time in the app; the stored vehicle data is then deleted.
- For **live charger availability** in Switzerland, the app retrieves public data from the Swiss Federal Office of Energy. No personal data is transmitted.

Your location is **only** shared with people whose friend request you accepted (or who accepted yours), and only while sharing is turned on. You can pause sharing or limit it in time at any time ("1 hr", "Until arrival").

## 3. Retention

- Live positions are not stored but forwarded directly to friends.
- The last known position is overwritten with every update.
- Your profile photo is kept in private storage and deleted when you remove the photo or delete your account. Friends cache it for faster display; the cache is replaced when you set a new photo.
- Favorites stay on your device only and are removed when you delete the app.
- Active routes are deleted when navigation ends and are no longer shown after 3 hours at the latest.
- Meetup proposals without a time are no longer shown after 12 hours; meetups with a time until 2 hours after the agreed time.
- Short messages are shown for 12 hours.
- Vehicle data: only the latest state is stored (each report overwrites the previous one). It is deleted when you disconnect.
- Voice clips are deleted when you remove them or delete your account.
- **"Delete account"** in the app deletes all data immediately and permanently.

## 4. Service providers (processors)

- **Supabase Inc.** – database, sign-in and real-time transmission. Servers in London, United Kingdom (AWS eu-west-2). The EU Commission has issued an adequacy decision for the United Kingdom.
- **Mapbox Inc.** (USA) – maps, search, routes and traffic data. For routes and search, location and destination coordinates are sent to Mapbox. Only if you turn on "Help Mapbox improve maps" in the settings (off by default) does the app additionally send de-identified location and usage data to Mapbox to improve its maps (Art. 6(1)(a) GDPR). Basis: EU standard contractual clauses or the EU-US Data Privacy Framework.
- **Apple Inc.** – "Sign in with Apple" and push notifications.

## 5. Your rights

You have the right of access, rectification, erasure, restriction of processing, data portability, objection, and to withdraw consent with effect for the future. You can also lodge a complaint with a data protection supervisory authority.

You can change location access at any time in iOS Settings under *Privacy & Security → Location Services → Meeterz*.
