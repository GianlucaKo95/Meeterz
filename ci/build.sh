#!/bin/bash
# Baut Meeterz für den iOS-Simulator und schreibt alles Wichtige in report.txt.
# Rückgabewert = Ergebnis des Builds.

REPORT="${REPORT:-report.txt}"
: > "$REPORT"
log() { echo "$@" | tee -a "$REPORT"; }

log "== Umgebung =="
sw_vers 2>&1 | tee -a "$REPORT"
log "Installierte Xcode-Versionen:"
ls -d /Applications/Xcode* 2>&1 | tee -a "$REPORT"

XCODE=$(ls -d /Applications/Xcode_27* 2>/dev/null | sort -V | tail -1)
if [ -z "$XCODE" ] && /usr/bin/xcodebuild -version 2>/dev/null | grep -q "^Xcode 27"; then
  XCODE=$(dirname "$(dirname "$(xcode-select -p)")")
fi
if [ -z "$XCODE" ]; then
  log "!! Kein Xcode 27 gefunden"
  exit 10
fi
sudo xcode-select -s "$XCODE" 2>&1 | tee -a "$REPORT"
xcodebuild -version 2>&1 | tee -a "$REPORT"
log "iOS-Simulator-SDK: $(xcrun --sdk iphonesimulator --show-sdk-version 2>&1)"

log ""
log "== Mapbox-Zugang =="
if [ -z "$MAPBOX_DOWNLOADS_TOKEN" ]; then
  log "!! Secret MAPBOX_DOWNLOADS_TOKEN fehlt"
  exit 11
fi
printf "machine api.mapbox.com\n  login mapbox\n  password %s\n" "$MAPBOX_DOWNLOADS_TOKEN" > ~/.netrc
chmod 0600 ~/.netrc
log "ok"

log ""
log "== Projekt erzeugen =="
brew list xcodegen >/dev/null 2>&1 || brew install xcodegen 2>&1 | tail -3 | tee -a "$REPORT"
cp Config.example.xcconfig Config.xcconfig
sed -i '' 's#DEIN-PROJEKT#ci-platzhalter#; s#DEIN_PUBLISHABLE_KEY#ci-platzhalter#; s#pk.DEIN_MAPBOX_PUBLIC_TOKEN#pk.ci-platzhalter#; s#DEINE_TEAM_ID##' Config.xcconfig
xcodegen generate 2>&1 | tee -a "$REPORT"
[ -d Meeterz.xcodeproj ] || { log "!! xcodegen hat kein Projekt erzeugt"; exit 12; }

log ""
log "== Pakete laden =="
xcodebuild -resolvePackageDependencies -project Meeterz.xcodeproj -scheme Meeterz > resolve.log 2>&1
RES=$?
tail -25 resolve.log | tee -a "$REPORT"
[ $RES -eq 0 ] || { log "!! Paketauflösung fehlgeschlagen ($RES)"; exit 13; }

log ""
log "== Bauen =="
xcodebuild build \
  -project Meeterz.xcodeproj -scheme Meeterz \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO > build.log 2>&1
RC=$?
log "xcodebuild Rückgabewert: $RC"
if [ $RC -ne 0 ]; then
  log "== Fehler =="
  grep -E "error:" build.log | sed 's#/Users/runner/work/[^/]*/[^/]*/##' | awk '!seen[$0]++' | head -120 | tee -a "$REPORT"
  log "== Letzte Zeilen =="
  tail -15 build.log | tee -a "$REPORT"
fi
log ""
log "== Warnungen (Auswahl) =="
grep -E "warning:" build.log | sed 's#/Users/runner/work/[^/]*/[^/]*/##' | awk '!seen[$0]++' | head -30 >> "$REPORT"
exit $RC
