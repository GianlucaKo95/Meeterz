# TestFlight ohne Mac – Schritt für Schritt

Der Workflow `TestFlight` (GitHub → Actions → „TestFlight“ → Run workflow) baut Meeterz als Release, signiert automatisch und lädt es zu TestFlight hoch. Dafür einmalig:

## 1. Developer-Account
1. https://developer.apple.com/programs/enroll/ → als Privatperson anmelden (99 €/Jahr).
2. Nach der Freigabe: **Team-ID** notieren (developer.apple.com → Account → Mitgliedschaft → „Team-ID“, 10 Zeichen).

## 2. App-ID anlegen (developer.apple.com → Certificates, IDs & Profiles → Identifiers → +)
- Typ **App IDs → App**, Bundle ID **explizit** `de.koeven.meeterz`
- Capabilities anhaken: **Sign In with Apple**, **Push Notifications**
- (CarPlay erst nach Freigabe durch Apple, siehe `docs/carplay-entitlement-request.md`)

## 3. App in App Store Connect anlegen (appstoreconnect.apple.com → Apps → +  → Neue App)
- Plattform iOS, Name „Meeterz“ (falls vergeben, anderen Namen wählen – er kann später geändert werden), Primärsprache Deutsch
- Bundle ID `de.koeven.meeterz`, SKU frei wählbar (z. B. `meeterz-001`)

## 4. API-Schlüssel erzeugen (App Store Connect → Benutzer und Zugriff → Integrationen → App Store Connect API → +)
- Name „GitHub CI“, Zugriff **Admin** (nötig, damit Xcode in der Cloud Zertifikate und Profile selbst anlegen darf)
- Notieren: **Issuer-ID** (oben auf der Seite) und **Schlüssel-ID**
- Die `.p8`-Datei **einmalig** herunterladen (sie ist später nicht mehr abrufbar)

## 5. GitHub-Secrets (Repo → Settings → Secrets and variables → Actions → New repository secret)
| Name | Inhalt |
|---|---|
| `APPLE_TEAM_ID` | Team-ID aus Schritt 1 |
| `ASC_KEY_ID` | Schlüssel-ID aus Schritt 4 |
| `ASC_ISSUER_ID` | Issuer-ID aus Schritt 4 |
| `ASC_KEY_P8` | kompletter Inhalt der `.p8`-Datei inkl. `-----BEGIN PRIVATE KEY-----` |

Bereits vorhanden: `MAPBOX_DOWNLOADS_TOKEN`, `MAPBOX_PUBLIC_TOKEN`, `SUPABASE_ANON_KEY`.

## 6. Anmeldung mit Apple in Supabase aktivieren
Supabase → Authentication → Providers → **Apple** → einschalten, bei **Client IDs** `de.koeven.meeterz` eintragen, speichern. (Für die native App-Anmeldung ist kein Secret nötig.)
Im Release-Build gibt es nur noch „Mit Apple anmelden“; der E-Mail-Testlogin ist nicht mehr enthalten.

## 7. Hochladen
Actions → **TestFlight** → Run workflow. Das Ergebnis steht danach auf dem Branch `testflight-report` (Datei `report.txt`). Nach ca. 10–30 Minuten erscheint der Build in App Store Connect → TestFlight (Verarbeitung durch Apple).

## 8. Tester einladen
App Store Connect → TestFlight → Interne Tester (bis zu 100 Personen mit Rolle im Team, ohne Prüfung durch Apple) oder Externe Tester (Link, erfordert kurze Beta-Prüfung). Tester installieren die App über die TestFlight-App.

## Hinweise
- Jeder Lauf bekommt automatisch eine neue Build-Nummer (Workflow-Laufnummer).
- **Push-Benachrichtigungen** sind in der App vorbereitet; die Server-Funktion `notify` (APNs-Schlüssel) ist noch nicht eingerichtet.
- **Datenschutz-Angaben** in App Store Connect: Standort (genau), Name, E-Mail, Fotos, Audio, Nutzer-ID – alle „mit der Identität verknüpft“, **nicht** zum Tracking, Zweck „App-Funktionalität“ (entspricht `PrivacyInfo.xcprivacy`). Datenschutz-URL: https://gianlucako95.github.io/Meeterz/datenschutz
- **CarPlay:** Nach Freigabe das Entitlement-Profil neu erzeugen lassen und den Workflow mit „carplay“ = an starten.
