# Antrag: CarPlay Navigation Entitlement

Einreichen unter https://developer.apple.com/contact/carplay (mit dem Apple-Developer-Account, der die App veröffentlicht).
Kategorie: **Navigation** (`com.apple.developer.carplay-maps`). Das Formular ist englisch – Text unten kann direkt übernommen werden.

---

**App name:** Meeterz
**Bundle ID:** de.koeven.meeterz
**Category:** Navigation
**Availability:** Germany first, then EU

**App description**

Meeterz is a turn-by-turn navigation app for drivers who travel in groups or want to meet friends on the way.
It provides full turn-by-turn route guidance with voice instructions, live traffic, traffic-aware rerouting and lane guidance, powered by the Mapbox Navigation SDK.

On top of navigation, Meeterz adds a social layer: users can share their live location with friends they have explicitly approved, and see friends' routes when those friends are navigating with Meeterz. The app detects where routes overlap in space and time and suggests a convenient meeting point (e.g. a rest area), which can be added as a waypoint to the active guidance with one tap.

**Planned CarPlay experience**

- CPMapTemplate with our own map, active route guidance, maneuvers, ETA and travel estimates
- Route preview with alternatives, destination search via CPSearchTemplate
- Friends' positions and shared routes drawn as map overlays; a single button toggles the friend layer to keep the screen uncluttered
- Meeting-point suggestions presented as a CPAlertTemplate/route option; no free-text input or messaging while driving
- Dashboard scene support (CPTemplateApplicationDashboardScene) and voice prompts via AVSpeechSynthesizer with audio session ducking

**Audio in the car**

Friends can record short (max. 5 seconds) voice clips that are played at defined moments, e.g. when a friend drives past or when the meeting point is reached. Clips are played through the app's audio session with ducking of other audio, like a spoken navigation prompt. They are short, friend-only, and can be muted per friend or switched off completely.

**Why CarPlay**

The core use case happens while driving: following guidance and seeing whether a friend's route crosses yours so you can meet on the way without picking up the phone.

**Driver safety**

All interactions in CarPlay use system templates. Location sharing settings, friend management and account features are only available on iPhone. No text entry or notifications that require reading longer content are shown while driving.

---

**Ablauf:** Direkt nach der Freigabe des Developer-Accounts einreichen (Bundle ID `de.koeven.meeterz` muss dazu in dem Account existieren). Die Bearbeitung kann dauern; währenddessen TestFlight ohne CarPlay nutzen. Nach der Freigabe das Entitlement-Profil neu erzeugen lassen und den Workflow „TestFlight“ mit „carplay“ = an starten (siehe `ci/TESTFLIGHT.md`). Screenshots aus dem CarPlay-Simulator kann man bei Rückfragen nachreichen.
