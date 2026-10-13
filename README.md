# Meeterz

Sieh, wo deine Freunde unterwegs sind – und triff sie auf dem Weg. iPhone + CarPlay.

## Funktionen

**Freunde & Standort**
- Anmeldung mit „Mit Apple anmelden" (Test-Login per E-Mail/Passwort für die kostenlose Apple-ID)
- Freunde per @Benutzername, Anfragen annehmen/ablehnen/zurückziehen
- Live-Standort über private Supabase-Realtime-Kanäle, abgesichert per RLS (nur angenommene Freunde, nur solange geteilt wird)
- Teilen pausieren oder begrenzen: Immer / 1 Std. / Bis Ankunft (+15 Min.)
- Sparsames Senden: in Fahrt ~5 s, im Stand ≤ 1/min; letzte Position alle 2 Min. gespeichert

**Karte (Nachtfahrt-Design)**
- Satellit oder klassisch, 3D oder 2D – je ein Tipp; 3D-Gelände und 3D-Gebäude
- Freunde live mit Aktualität („live", „vor 3 Min.", ab 5 Min. ausgegraut)
- Routen der Freunde als farbige Linien, mögliche Treffpunkte, vereinbarte Treffen
- Panel „Unterwegs": Freunde mit Ziel, Ankunftszeit und Entfernung; Route zum Freund oder zu seinem Ziel

**Navigation (Mapbox Navigation SDK 3.32.1)**
- Zielsuche (Mapbox Search Box), Schnellziele: Freunde und Treffpunkte
- Routenvorschau mit Ankunft, Dauer, Strecke – inkl. Live-Traffic
- Turn-by-Turn mit Sprachansagen (Apple-Stimmen, offline; Stimme unter Bedienungshilfen → Gesprochene Inhalte), Umleitung bei Stau, Satellitenstil
- Freunde und ihre Routen auch in der Navigationsansicht
- Eigene Route wird geteilt (Stützpunkte alle ~300 m mit Ankunftszeit, minütlich und bei Umleitung aktualisiert)

**Treffen**
- Automatische Erkennung: Wo seid ihr innerhalb von 1,5 km und ±20 Min. zur gleichen Zeit? Ohne eigene Route: Freund fährt an dir vorbei
- Treffen planen: Raststätte, Café, Essen, Tanken in der Nähe oder genau am Kreuzungspunkt
- Einladen ohne Überschneidung: beliebiges Ziel suchen → „Freunde einladen" (auch mehrere) oder in der Freundesliste wischen → „Einladen"
- Vorschlag senden → annehmen/ablehnen → als Zwischenstopp in die laufende Navigation
- Live-Aktualisierung der Vorschläge (Realtime) und Push-Benachrichtigungen

**CarPlay**
- Karte mit Freunden, Buttons: auf Live-Standort zentrieren, Freunde ein/aus, Zoom
- „Ziele": vereinbarte Treffpunkte und Freunde → Routenvorschau → Navigation
- „Suche": Ziel suchen – mit Tastatur im Stand, per Diktat beim Fahren (das entscheidet CarPlay selbst)
- „Einladen" (in Vorschau und Navigation): Freunde zum aktuellen Ziel einladen, einzeln oder alle
- Eingehende Einladungen erscheinen als Hinweis mit Annehmen/Ablehnen (und unter „Ziele → Einladungen")
- Übernimmt eine auf dem iPhone gestartete Navigation; Kartenstil (Satellit/Klassisch) in den iPhone-Einstellungen

**Konto**
- Konto löschen (inkl. aller Daten), Support- und Datenschutz-Seite über GitHub Pages (`docs/`, Entwurf)

## Als Nächstes: Sound-Pack (nach dem ersten erfolgreichen Test)

Jeder nimmt kurze Sprachschnipsel (max. 5 s) auf; Freunde hören sie im passenden Moment – auch während der Navigation und auf CarPlay:

| Moment | Beispiel |
|---|---|
| Freund fährt an dir vorbei (< 300 m, beide unterwegs) | „Hup mal, ich bin's!" |
| Freund ist noch 5 Min. vom Treffpunkt entfernt | „Bin gleich da, bestell schon mal!" |
| Freund ist am Treffpunkt angekommen | „Wo bleibst du denn?" |
| Freund nimmt deinen Treffen-Vorschlag an | „Deal, wir sehen uns!" |

- Speicherung in Supabase Storage, nur für angenommene Freunde abrufbar; lokal zwischengespeichert
- Musik wird kurz leiser, Navigationsansagen haben Vorrang
- Ohne Aufnahme: normale Apple-Ansage als Ersatz
- Einstellungen: „Stimmen von Freunden abspielen" und einzelne Freunde stummschalten

## Setup

### 1. Supabase
1. Migrationen aus `supabase/migrations/` der Reihe nach im SQL Editor ausführen (bzw. `supabase db push`).
2. **Authentication → Sign In / Providers → Apple**: aktivieren, Client ID `de.koeven.meeterz`.
3. Für den Test-Login: **Email**-Provider an, „Confirm email" aus. *Vor der Veröffentlichung wieder ausschalten.*
4. **Realtime → Settings**: „Allow public access" aus.
5. Push (nur mit bezahltem Account): Edge Function `supabase/functions/notify` deployen und Secrets `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_PRIVATE_KEY`, `APNS_BUNDLE_ID` setzen.

### 2. Mapbox
1. **Public Token** (`pk.…`) → `MAPBOX_ACCESS_TOKEN` in `Config.xcconfig`.
2. **Secret Token** mit Scope *Downloads:Read* anlegen – wird nur zum Herunterladen des Navigation SDK gebraucht. In `~/.netrc` auf dem Mac (nie ins Repo!):
   ```
   machine api.mapbox.com
     login mapbox
     password sk.DEIN_SECRET_TOKEN
   ```
   Danach `chmod 0600 ~/.netrc`.

### 3. Xcode-Projekt
```bash
brew install xcodegen
cp Config.example.xcconfig Config.xcconfig   # Werte und Modus eintragen
xcodegen generate
open Meeterz.xcodeproj
```

### Modus (in `Config.xcconfig`)
| Account | Login | Push | CarPlay |
|---|---|---|---|
| **A** Kostenlose Apple-ID | Test-Login | – | nur Simulator (*I/O → External Displays → CarPlay*) |
| **B** Bezahlter Account | Mit Apple | ✓ | – |
| **C** Bezahlt + CarPlay-Entitlement | Mit Apple | ✓ | ✓ im Auto |

Nach dem Umstellen `xcodegen generate` erneut ausführen. Ein Release-Build mit `DEV_LOGIN` bricht absichtlich ab.

## End-to-End-Test

Zwei Geräte (oder iPhone + Simulator), zwei Konten **A** und **B**.

1. **Login & Profil:** beide registrieren, Benutzernamen wählen.
2. **Freunde:** A fügt @B hinzu → B sieht die Anfrage (Badge) → annehmen. Beide erscheinen in „Deine Freunde".
3. **Live-Standort:** Simulator → *Features → Location → Freeway Drive*. Der Marker bewegt sich beim anderen Gerät (≈5 s). Teilen pausieren → Marker veraltet/verschwindet beim Freund.
4. **Teilen begrenzen:** „1 Std." wählen → Pill zeigt „bis HH:MM".
5. **Karte:** Satellit/Karte, 3D/2D, Zentrieren durchschalten.
6. **Navigation:** „Wohin?" → Ziel suchen → Vorschau → *Fahrt simulieren* (nur Debug) → Losfahren. Ansagen, Satellit, Freunde in der Navigation prüfen.
7. **Route teilen:** Gerät B sieht A's Route als Linie und im Panel „Nach … · an HH:MM".
8. **Treffpunkt:** Beide navigieren auf sich kreuzenden Strecken (oder B steht an A's Route) → Karte „… kreuzt deinen Weg" → Treffen planen → Ort wählen → vorschlagen.
9. **Einladung:** A sucht ein Ziel → Vorschau → „Freunde einladen" → B (und ggf. C) sehen die Einladung → Annehmen → Zwischenstopp/Ziel. Alternativ Freundesliste → wischen → „Einladen".
10. **Vorschlag:** B sieht ihn sofort → Annehmen → wird Zwischenstopp. A sieht „Treffen mit B".
11. **CarPlay (Simulator):** Karte mit Freunden, Zentrieren, Freunde ein/aus, „Ziele" → Freund → Route → Navigation. „Suche" → Ziel → Vorschau → „Einladen" → Freund. Einladung von Gerät B erscheint als Hinweis in CarPlay. Auf dem iPhone gestartete Navigation erscheint in CarPlay.
12. **Konto löschen:** in den Einstellungen → Konto ist weg, Freund sieht dich nicht mehr.

## Architektur

```
Meeterz/
├── App/            MeeterzApp (Einstieg, Push-Delegate), AppModel (zentrale Klammer)
├── Models/         Profile, FriendRow, LivePosition, FriendRoute, MeetupCandidate, Meetup, Place
├── Services/       Auth, Friends, Location, LiveLocationHub (Realtime), Routes, Meetups, Search, Push
├── Navigation/     NavigationCoordinator, RouteSampler, NavigationStyles, FriendOverlay
├── CarPlay/        CarPlaySceneDelegate, CarPlayController (Mapbox CarPlayManager)
├── Views/          Theme, Root/SignIn/Onboarding, Main (Karte), Social (Treffen), Search, Friends
└── Assets.xcassets App-Icon, Farben
supabase/
├── migrations/     Phase 1 (Freunde, Standorte), Phase 2 (Routen, Treffen, Push, Konto löschen)
└── functions/notify  Push über APNs
docs/               CarPlay-Antrag, Datenschutzerklärung (Entwurf)
```

**Datenschutz-Prinzipien:** Schreiben nur über RPCs; Standort und Routen nur für angenommene Freunde und nur solange geteilt wird; Senden nur in den eigenen Kanal; Hilfsfunktionen im nicht öffentlichen Schema `private`.
