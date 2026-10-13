# Meeterz

Live-Standorte von Freunden, Navigation mit Live-Traffic, geteilte Routen und Treffpunkte – auf iPhone und CarPlay.


## Stand: Phase 1

- Login per E-Mail-Code (Supabase Auth)
- Profil mit Benutzername, Freundschaftsanfragen per @handle
- Eigener Standort (auch im Hintergrund), adaptiv gesendet: in Fahrt ~5 s, im Stand ≤ 1/min
- Live-Positionen der Freunde über private Supabase-Realtime-Kanäle (`loc:<user_id>`), abgesichert per RLS
- Letzte bekannte Position (alle 2 Min. gespeichert) für den App-Start
- Mapbox-Karte mit Freunde-Markern und Aktualitätsanzeige („live", „vor 3 Min.", ab 5 Min. ausgegraut)
- Teilen pausieren/fortsetzen

## Roadmap

| Phase | Inhalt |
|---|---|
| 1 ✅ | Login, Freunde, Live-Standorte |
| 2 | Mapbox Navigation SDK v3: Turn-by-Turn, Live-Traffic, Routen teilen, Treffpunkt-Erkennung |
| 3 | CarPlay (`CarPlayManager`) mit Freunde- und Routen-Layern |
| 4 | Akku-Feinschliff, Datenschutz/DSGVO, TestFlight |

## Setup

### 1. Supabase
1. Neues Projekt anlegen (Region Frankfurt).
2. `supabase/migrations/20261013000000_phase1.sql` im SQL Editor ausführen.
3. **Authentication → Email Templates → Magic Link**: `{{ .Token }}` in die Vorlage aufnehmen, damit ein 6-stelliger Code verschickt wird.
4. **Realtime → Settings**: „Allow public access" deaktivieren, damit nur private Kanäle erlaubt sind.
5. URL und Publishable Key unter *Project Settings → API* kopieren.

### 2. Mapbox
Account auf mapbox.com anlegen und den **Default Public Token** (`pk.…`) kopieren.

### 3. Xcode-Projekt
```bash
brew install xcodegen
cp Config.example.xcconfig Config.xcconfig   # Werte eintragen
xcodegen generate
open Meeterz.xcodeproj
```
Danach auf einem echten iPhone starten. Im Simulator kann man unter *Features → Location → Freeway Drive* eine Fahrt simulieren.

### Testen mit zwei Geräten
Zweites Gerät (oder Simulator) mit anderer E-Mail anmelden, gegenseitig per Benutzername hinzufügen, annehmen – die Marker erscheinen sofort.

## Architektur

```
Meeterz/
├── App/MeeterzApp.swift          Einstieg, Supabase-Client, Config
├── Models/Models.swift          Profile, FriendRow, LivePosition
├── Services/
│   ├── AuthStore.swift          Login, Profil, Teilen an/aus
│   ├── FriendsStore.swift       Freunde & Anfragen (RPCs)
│   ├── LocationService.swift    CoreLocation inkl. Hintergrund
│   └── LiveLocationHub.swift    Realtime senden/empfangen, Drosselung
└── Views/                       Root/SignIn/Onboarding, Karte, Freunde
supabase/migrations/             Schema, RPCs, RLS (inkl. realtime.messages)
```

**Datenschutz-Prinzipien:** Schreiben in `friendships`/`last_locations` nur über RPCs; Standorte nur für angenommene Freunde und nur wenn der Besitzer teilt; Senden nur in den eigenen Kanal.
