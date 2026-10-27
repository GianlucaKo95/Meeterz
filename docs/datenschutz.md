# Datenschutzerklärung Meeterz
Stand: Oktober 2026 · [English version](privacy)

## 1. Verantwortlicher

Gianluca Köhni
Waldstrasse 1c
47199 Duisburg
Deutschland
E-Mail: gk@koeven.de

## 2. Welche Daten Meeterz verarbeitet

| Daten | Zweck | Rechtsgrundlage |
|---|---|---|
| Konto: Apple-ID-Kennung bzw. E-Mail-Adresse, Anzeigename, Benutzername | Anmeldung, damit Freunde dich finden | Art. 6 Abs. 1 lit. b DSGVO (Vertrag) |
| Freundschaften und Anfragen | Festlegen, wer deinen Standort sehen darf | Art. 6 Abs. 1 lit. b DSGVO |
| **Live-Standort** (Position, Richtung, Geschwindigkeit) | An angenommene Freunde senden, solange du teilst | Art. 6 Abs. 1 lit. a DSGVO (Einwilligung) |
| Letzte bekannte Position | Freunden beim Öffnen der App sofort anzeigen | Art. 6 Abs. 1 lit. a DSGVO |
| Aktive Route (Ziel, Strecke, Ankunftszeiten) | Freunden anzeigen und Treffpunkte finden | Art. 6 Abs. 1 lit. a DSGVO |
| Treffen-Vorschläge | Verabreden mit Freunden | Art. 6 Abs. 1 lit. b DSGVO |
| Profilbild (optional, auf 256 × 256 px verkleinert) | Freunden auf der Karte und in Listen anzeigen; nur angenommene Freunde können es abrufen | Art. 6 Abs. 1 lit. a DSGVO |
| Push-Token des Geräts | Benachrichtigungen über Anfragen und Treffen sowie Standort-Abruf (siehe unten) | Art. 6 Abs. 1 lit. a DSGVO |
| Inkognito-Einstellung (Zeitpunkt bis wann, „Routen verbergen“) | Dich für Freunde unsichtbar machen; Freunde erfahren nicht, dass du inkognito bist | Art. 6 Abs. 1 lit. a DSGVO |
| Favoriten (Zuhause, Arbeit, eigene Orte mit Namen) | Schnellziele für die Navigation. **Nur auf deinem Gerät gespeichert**, nicht auf unseren Servern | Art. 6 Abs. 1 lit. b DSGVO |
| Treffen-Vorschläge mit optionaler Uhrzeit | Verabreden; die Uhrzeit dient der Erinnerung ans Losfahren | Art. 6 Abs. 1 lit. b DSGVO |
| Kurznachrichten an Freunde (z. B. „Bin gleich da“) | Freunden unterwegs Bescheid geben | Art. 6 Abs. 1 lit. b DSGVO |
| Sprachschnipsel (optional, max. 5 Sekunden) | Werden bei bestimmten Momenten bei angenommenen Freunden abgespielt | Art. 6 Abs. 1 lit. a DSGVO |
| **Fahrzeugdaten** (optional, nur E-Auto mit eingerichteter Verbindung): Akkustand, Reichweite, Laden/Ladeleistung, Außentemperatur, Kilometerstand, Geschwindigkeit, geparkt ja/nein, Position des Autos | Ladeplanung, Ladeanzeige, Lernen des Verbrauchs, Erkennen des Parkplatzes. Nur für dich sichtbar, nie für Freunde | Art. 6 Abs. 1 lit. a DSGVO |
| Geparktes Auto (optional, „Geparktes Auto merken“) | Parkplatz merken; erkannt über Fahrzeugdaten, CarPlay-Trennung oder Bewegungsart (Auto → zu Fuß) des iPhones. **Nur auf deinem Gerät gespeichert** | Art. 6 Abs. 1 lit. a DSGVO |
| Gelernter Verbrauch je Tempobereich | Genauere Ladeplanung. **Nur auf deinem Gerät gespeichert** | Art. 6 Abs. 1 lit. b DSGVO |
| Diagnoseprotokoll (Abstürze, Hänger, technische Ereignisse) | Fehlersuche. **Nur auf deinem Gerät**; es verlässt das Gerät nur, wenn du es selbst teilst | Art. 6 Abs. 1 lit. f DSGVO (berechtigtes Interesse an einer funktionierenden App) |

### Standort im Hintergrund und Abruf durch Freunde

- Mit der Berechtigung „Immer“ kann Meeterz deinen Standort auch bei geschlossener App aktualisieren. Um Akku zu sparen, nutzt die App im Stand nur die grobe Überwachung großer Ortswechsel und schaltet bei Bewegung, Navigation und CarPlay auf genaue Ortung.
- Öffnet ein Freund die Karte und deine Position ist veraltet, sendet unser Server einen **stillen Push** an dein Gerät (über Apple Push). Dein Gerät sendet dann kurz deinen aktuellen Standort. Der Push enthält keinen Standort und keine Nachricht. Das geschieht nur für angenommene Freunde und nur, solange du teilst – nie im Inkognito-Modus oder bei pausiertem Teilen.
- Die **Sprachansagen** der Navigation werden vollständig auf deinem Gerät erzeugt (Systemstimmen von Apple). Es werden keine Sprachdaten übertragen.
- **Fahrzeugdaten** kommen nur, wenn du die Verbindung selbst einrichtest (z. B. über einen Home-Assistant-Dienst, der die Daten deines Autos mit einer geheimen Geräte-ID an Meeterz sendet). Du kannst die Verbindung in der App jederzeit trennen; dann werden die gespeicherten Fahrzeugdaten gelöscht.
- Für die **Live-Belegung von Ladesäulen** in der Schweiz ruft die App öffentliche Daten des Bundesamts für Energie ab. Dabei werden keine personenbezogenen Daten übermittelt.

Dein Standort wird **nur** an Personen übermittelt, deren Freundschaftsanfrage du angenommen hast (oder die deine angenommen haben), und nur solange das Teilen eingeschaltet ist. Du kannst das Teilen jederzeit pausieren oder zeitlich begrenzen („1 Std.", „Bis Ankunft").

## 3. Speicherdauer

- Live-Positionen werden nicht gespeichert, sondern direkt an Freunde weitergeleitet.
- Die letzte bekannte Position wird bei jedem Update überschrieben.
- Dein Profilbild liegt in einem privaten Speicher und wird beim Entfernen des Bildes oder beim Löschen des Kontos gelöscht. Freunde speichern es zur schnelleren Anzeige zwischen; der Zwischenspeicher wird bei einem neuen Bild ersetzt.
- Favoriten bleiben ausschließlich auf deinem Gerät und werden beim Löschen der App entfernt.
- Aktive Routen werden beim Beenden der Navigation gelöscht und nach spätestens 3 Stunden nicht mehr angezeigt.
- Treffen-Vorschläge ohne Uhrzeit werden nach 12 Stunden nicht mehr angezeigt, Treffen mit Uhrzeit bis 2 Stunden nach dem vereinbarten Zeitpunkt.
- Kurznachrichten werden 12 Stunden angezeigt.
- Fahrzeugdaten: Es wird nur der jeweils letzte Stand gespeichert (jede Meldung überschreibt die vorige). Beim Trennen der Verbindung werden sie gelöscht.
- Sprachschnipsel werden beim Entfernen oder beim Löschen des Kontos gelöscht.
- Mit **„Konto löschen"** in der App werden alle Daten sofort und endgültig gelöscht.

## 4. Dienstleister (Auftragsverarbeiter)

- **Supabase Inc.** – Datenbank, Anmeldung und Echtzeit-Übertragung. Server in London, Vereinigtes Königreich (AWS eu-west-2). Für das Vereinigte Königreich besteht ein Angemessenheitsbeschluss der EU-Kommission.
- **Mapbox Inc.** (USA) – Karten, Suche, Routen und Verkehrsdaten. Für Routen und Suche werden Standort- bzw. Zielkoordinaten an Mapbox übermittelt. Grundlage: EU-Standardvertragsklauseln bzw. EU-US Data Privacy Framework.
- **Apple Inc.** – „Mit Apple anmelden" und Push-Benachrichtigungen.

## 5. Deine Rechte

Du hast das Recht auf Auskunft, Berichtigung, Löschung, Einschränkung der Verarbeitung, Datenübertragbarkeit sowie Widerspruch und Widerruf erteilter Einwilligungen mit Wirkung für die Zukunft. Außerdem kannst du dich bei einer Datenschutzaufsichtsbehörde beschweren.

Die Standortfreigabe kannst du jederzeit in den iOS-Einstellungen unter *Datenschutz → Ortungsdienste → Meeterz* ändern.
