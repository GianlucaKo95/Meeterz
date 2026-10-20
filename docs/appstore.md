# App Store Connect – Unterlagen für Meeterz

Alle Texte zum Einfügen in App Store Connect. Stand: Oktober 2026.

## App-Informationen

| Feld | Wert |
|---|---|
| Name | Meeterz |
| Untertitel (max. 30 Zeichen) | Freunde live treffen |
| Kategorie | Navigation (sekundär: Soziale Netzwerke) |
| Altersfreigabe | 4+ (keine nutzergenerierten öffentlichen Inhalte; Inhalte nur zwischen angenommenen Freunden) |
| Support-URL | https://gianlucako95.github.io/Meeterz/ |
| Datenschutz-URL | https://gianlucako95.github.io/Meeterz/datenschutz |
| Bundle-ID | de.koeven.meeterz |
| Copyright | © 2026 Gianluca Köhni |

## Werbetext (max. 170 Zeichen)

Sieh, wo deine Freunde unterwegs sind, und triff sie auf dem Weg: Live-Standort, Navigation und Treffpunkte, wo sich eure Routen kreuzen.

## Beschreibung

Meeterz zeigt dir, wo deine Freunde gerade unterwegs sind, und hilft euch, euch unterwegs zu treffen.

**Live-Karte**
Sieh angenommene Freunde in Echtzeit auf einer Satellitenkarte mit 3D-Gebäuden oder auf der klassischen Karte.

**Navigation mit Verkehrslage**
Routen mit aktueller Verkehrslage, Sprachansagen auf Deutsch und Unterstützung für Zwischenstopps. Zuhause, Arbeit und eigene Favoriten sind mit einem Tipp erreichbar.

**Treffpunkte auf dem Weg**
Meeterz erkennt, wo sich eure Routen kreuzen, und schlägt einen Treffpunkt vor. Lade Freunde zu einem Ziel ein und sieh, wann sie ankommen.

**Du entscheidest, was geteilt wird**
Standort nur für Freunde, die du angenommen hast. Teilen pausieren, zeitlich begrenzen oder mit dem Inkognito-Modus kurz unsichtbar werden – Freunde erfahren das nicht. Routen lassen sich dauerhaft verbergen.

**Sound-Pack**
Nimm kurze Sprachschnipsel auf, die deine Freunde hören, wenn du an ihnen vorbeifährst oder ankommst.

**Akkuschonend**
Volle Ortungsgenauigkeit nur bei offener Karte, Navigation und CarPlay, sonst sparsam im Hintergrund.

Anmeldung mit Apple. Keine Werbung, kein Tracking.

## Keywords (max. 100 Zeichen)

freunde,standort,teilen,navigation,treffen,karte,live,route,carplay,unterwegs,konvoi

## Datenschutz-Angaben („App-Datenschutz“)

Keine Daten werden zum Tracking verwendet. Alle Daten sind mit dem Nutzer verknüpft und dienen der **App-Funktionalität**:

| Datentyp | Erfasst | Verknüpft | Tracking |
|---|---|---|---|
| Genauer Standort | ja | ja | nein |
| Name (Anzeigename) | ja | ja | nein |
| E-Mail-Adresse (Apple-Relay) | ja | ja | nein |
| Fotos (Profilbild) | ja | ja | nein |
| Audiodaten (Sound-Pack, max. 5 s) | ja | ja | nein |
| Nutzer-ID | ja | ja | nein |
| Gerätekennung (Push-Token) | ja | ja | nein |

Entspricht der Datei `Meeterz/PrivacyInfo.xcprivacy`. Favoriten liegen nur auf dem Gerät und werden nicht erfasst.

## Exportvorschriften

Verschlüsselung: nur standardmäßige, in iOS enthaltene (HTTPS). `ITSAppUsesNonExemptEncryption` ist auf *false* gesetzt, die Frage entfällt.

## Hinweise für die App-Prüfung (App Review)

> Meeterz nutzt „Mit Apple anmelden“. Zum Testen werden zwei Konten benötigt, die sich gegenseitig als Freunde annehmen (Profil → Freund hinzufügen → Benutzername). Die Ortung läuft im Hintergrund (UIBackgroundModes: location), weil Freunde den Live-Standort auch bei geschlossener App sehen sollen, solange der Nutzer das Teilen eingeschaltet hat; die App zeigt dafür den Hintergrund-Ortungshinweis von iOS. Mikrofon: nur für kurze Sprachschnipsel (Sound-Pack) auf ausdrückliche Aktion des Nutzers. Audio-Hintergrundmodus: Sprachansagen der Navigation. Remote-Notification-Hintergrundmodus: Push-Benachrichtigungen und der stille Push, mit dem ein Freund den aktuellen Standort anfragt.

Falls Apple ein Demo-Konto verlangt: bitte Kontakt über gk@koeven.de, ein Testpaar wird bereitgestellt.

## Screenshots

Erforderlich: 6,9 Zoll (1320 × 2868 px). Erzeugen: GitHub → Actions → **Build** → *Run workflow* → Haken bei **„Auf einem iPhone Pro Max laufen lassen“**. Die Bilder liegen danach im Branch `ci-report` unter `screenshots/` (Karte, Freunde, Navigation, Favoriten, Einstellungen). Eigene Aufnahmen vom iPhone (Statusleiste mit vollem Akku) wirken meist besser; geeignet sind: Karte mit Freunden, Routenvorschau, Navigation, Treffpunkt-Vorschlag, Inkognito.

## Vor dem Einreichen

- [ ] Build in TestFlight auf dem iPhone getestet (zwei Konten, Hintergrund, Navigation)
- [ ] Datenschutz-Angaben und Altersfreigabe in App Store Connect ausgefüllt
- [ ] Screenshots hochgeladen
- [ ] Version 1.0 mit dem getesteten Build verknüpft
- [ ] CarPlay-Berechtigung (falls erteilt) im Build aktiviert: `Meeterz-CarPlay.entitlements`, siehe `ci/TESTFLIGHT.md`
