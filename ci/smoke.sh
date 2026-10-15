#!/bin/bash
# Rauchtest: App im iOS-Simulator starten, Screenshot machen, auf Absturz prüfen.
# Schreibt in report.txt und legt Bilder unter screenshots/ ab.

REPORT="${REPORT:-report.txt}"
APP="build/dd/Build/Products/Debug-iphonesimulator/Meeterz.app"
BUNDLE="de.koeven.meeterz"
mkdir -p screenshots
log() { echo "$@" | tee -a "$REPORT"; }

log ""
log "== Rauchtest =="
[ -d "$APP" ] || { log "!! App nicht gefunden: $APP"; exit 1; }

# iPhone-Simulator mit dem neuesten iOS wählen
UDID=$(xcrun simctl list devices available -j | python3 -c '
import json,sys
d=json.load(sys.stdin)["devices"]
best=None
for rt,devs in d.items():
    if "iOS" not in rt: continue
    for x in devs:
        if "iPhone" in x["name"] and "Pro" in x["name"] and "Max" not in x["name"]:
            best=(rt,x["udid"],x["name"])
print(best[1] if best else "")
')
if [ -z "$UDID" ]; then
  log "!! Kein iPhone-Simulator gefunden"; xcrun simctl list devices available | head -30 | tee -a "$REPORT"; exit 1
fi
log "Simulator: $(xcrun simctl list devices | grep "$UDID" | head -1)"

xcrun simctl boot "$UDID" 2>&1 | tee -a "$REPORT"
xcrun simctl bootstatus "$UDID" -b > /dev/null 2>&1
xcrun simctl location "$UDID" set 51.4344,6.7623 2>&1 | tee -a "$REPORT"      # Duisburg
xcrun simctl privacy "$UDID" grant location "$BUNDLE" 2>&1 | tee -a "$REPORT"
xcrun simctl install "$UDID" "$APP" 2>&1 | tee -a "$REPORT"

log "Starte App …"
xcrun simctl launch "$UDID" "$BUNDLE" 2>&1 | tee -a "$REPORT"
sleep 10
xcrun simctl io "$UDID" screenshot screenshots/01-start.png 2>&1 | tee -a "$REPORT"

if xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep -q "$BUNDLE"; then
  log "App läuft nach 10 s: ja"
  ALIVE=0
else
  log "!! App läuft nicht mehr (Absturz?)"
  ALIVE=1
fi

# Absturzberichte
CRASHES=$(ls -t ~/Library/Logs/DiagnosticReports/Meeterz* 2>/dev/null | head -1)
if [ -n "$CRASHES" ]; then
  log "!! Absturzbericht: $CRASHES"
  head -60 "$CRASHES" | tee -a "$REPORT"
  ALIVE=1
fi

# Konsolenausgabe der App (kurz)
xcrun simctl spawn "$UDID" log show --last 1m --predicate "process == \\"Meeterz\\"" --style compact 2>/dev/null \
  | grep -iE "fatal|error|crash|assert" | head -20 | tee -a "$REPORT"

xcrun simctl shutdown "$UDID" > /dev/null 2>&1
exit $ALIVE
