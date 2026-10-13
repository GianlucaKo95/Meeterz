# Meeterz

Live-Standorte von Freunden, Navigation mit Live-Traffic, geteilte Routen und Treffpunkte – auf iPhone und CarPlay.


## Stand: Phase 1

- Login mit „Mit Apple anmelden" (Supabase Auth, nativer ID-Token-Flow)
- Profil mit Benutzername, Freundschaftsanfragen per @handle
- Eigener Standort (auch im Hintergrund), adaptiv gesendet: in Fahrt ~5 s, im Stand ≤ 1/min
- Live-Positionen der Freunde über private Supabase-Realtime-Kanäle (`loc:<user_id>`), abgesichert per RLS
- Letzte bekannte Position (alle 2 Min. gespeichert) für den App-Start
- Mapbox-Karte (Standard: Satellit + 3D-Verfolgerkamera mit Gelände und Gebäuden, umschaltbar) mit Freunde-Markern und Aktualitätsanzeige („live", „vor 3 Min.", ab 5 Min. ausgegraut)
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
3. **Authentication → Sign In / Providers → Apple**: aktivieren und unter *Client IDs* die Bundle-ID `de.koeven.meeterz` eintragen. Für den nativen iOS-Login ist kein Secret Key nötig.
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
Danach auf einem echten iPhone starten.

### Login-Modus (in `Config.xcconfig`)
| Account | Einstellung | Login in der App |
|---|---|---|
| Kostenlose Apple-ID (Personal Team) | `MEETERZ_FLAGS = DEV_LOGIN`, `MEETERZ_ENTITLEMENTS =` | Test-Login mit E-Mail + Passwort. In Supabase: Email-Provider an, „Confirm email" aus. App läuft 7 Tage, dann neu installieren. |
| Bezahlter Developer Account | `MEETERZ_FLAGS =`, `MEETERZ_ENTITLEMENTS = Meeterz/Meeterz.entitlements` | „Mit Apple anmelden" |

Nach dem Umstellen `xcodegen generate` erneut ausführen. Ein Release-Build mit `DEV_LOGIN` bricht absichtlich ab. Vor der Veröffentlichung in Supabase den Email-Provider wieder ausschalten. Im Simulator kann man unter *Features → Location → Freeway Drive* eine Fahrt simulieren.

### Testen mit zwei Geräten
Zweites Gerät mit einem anderen Konto anmelden, gegenseitig per Benutzername hinzufügen, annehmen – die Marker erscheinen sofort.

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
