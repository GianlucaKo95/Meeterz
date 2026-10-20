#!/bin/bash
# Baut Meeterz als Release, signiert mit dem App-Store-Connect-API-Schlüssel und lädt es zu TestFlight hoch.
# Benötigte Umgebungsvariablen (GitHub-Secrets, siehe docs/testflight-setup.md):
#   APPLE_TEAM_ID, ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8 (Inhalt der .p8-Datei),
#   MAPBOX_DOWNLOADS_TOKEN, MAPBOX_PUBLIC_TOKEN, SUPABASE_ANON_KEY, CI_SUPABASE_REF
# Optional: WITH_CARPLAY=1 (erst nach Freigabe des CarPlay-Entitlements durch Apple)

REPORT="${REPORT:-report.txt}"
: > "$REPORT"
log() { echo "$@" | tee -a "$REPORT"; }

for v in APPLE_TEAM_ID ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8 MAPBOX_DOWNLOADS_TOKEN MAPBOX_PUBLIC_TOKEN SUPABASE_ANON_KEY CI_SUPABASE_REF; do
  [ -n "${!v}" ] || { log "!! Secret/Variable $v fehlt"; exit 20; }
done

XCODE=$(ls -d /Applications/Xcode_27* 2>/dev/null | sort -V | tail -1)
[ -n "$XCODE" ] || { log "!! Kein Xcode 27 gefunden"; exit 10; }
sudo xcode-select -s "$XCODE" 2>&1 | tee -a "$REPORT"
xcodebuild -version 2>&1 | tee -a "$REPORT"

printf "machine api.mapbox.com\n  login mapbox\n  password %s\n" "$MAPBOX_DOWNLOADS_TOKEN" > ~/.netrc
chmod 0600 ~/.netrc

brew list xcodegen >/dev/null 2>&1 || brew install xcodegen 2>&1 | tail -3 | tee -a "$REPORT"

# Release-Konfiguration: kein Test-Login, Apple-Anmeldung, Push-Produktion
cp Config.example.xcconfig Config.xcconfig
ENT="Meeterz/Meeterz.entitlements"
[ "$WITH_CARPLAY" = "1" ] && ENT="Meeterz/Meeterz-CarPlay.entitlements"
sed -i '' "s#DEIN-PROJEKT#${CI_SUPABASE_REF}#; s#DEIN_PUBLISHABLE_KEY#${SUPABASE_ANON_KEY}#; s#pk.DEIN_MAPBOX_PUBLIC_TOKEN#${MAPBOX_PUBLIC_TOKEN}#; s#DEINE_TEAM_ID#${APPLE_TEAM_ID}#; s#MEETERZ_PUSH_ENV = development#MEETERZ_PUSH_ENV = production#" Config.xcconfig
# Modus A (Test-Login) entfernen, Modus B/C setzen
sed -i '' '/^MEETERZ_FLAGS = DEV_LOGIN/d; /^MEETERZ_ENTITLEMENTS =/d; /^MEETERZ_ENTITLEMENTS\[sdk/d' Config.xcconfig
printf "\nMEETERZ_FLAGS =\nMEETERZ_ENTITLEMENTS = %s\n" "$ENT" >> Config.xcconfig
grep -q "DEV_LOGIN" Config.xcconfig && { log "!! DEV_LOGIN ist noch aktiv"; exit 21; }
log "Entitlements: $ENT"

# Build-Nummer = fortlaufende Workflow-Nummer (TestFlight verlangt je Upload eine neue)
sed -i '' "s#CURRENT_PROJECT_VERSION: \"1\"#CURRENT_PROJECT_VERSION: \"${GITHUB_RUN_NUMBER:-1}\"#" project.yml
xcodegen generate 2>&1 | tee -a "$REPORT"

KEYDIR="$HOME/.appstoreconnect/private_keys"
mkdir -p "$KEYDIR"
printf "%s\n" "$ASC_KEY_P8" > "$KEYDIR/AuthKey_${ASC_KEY_ID}.p8"
AUTH=(-allowProvisioningUpdates
  -authenticationKeyPath "$KEYDIR/AuthKey_${ASC_KEY_ID}.p8"
  -authenticationKeyID "$ASC_KEY_ID"
  -authenticationKeyIssuerID "$ASC_ISSUER_ID")

log ""
log "== Archivieren =="
xcodebuild archive \
  -project Meeterz.xcodeproj -scheme Meeterz -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/Meeterz.xcarchive \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  "${AUTH[@]}" > archive.log 2>&1
RES=$?
grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)" archive.log | sort -u | head -30 | tee -a "$REPORT"
[ $RES -eq 0 ] || { tail -40 archive.log | tee -a "$REPORT"; log "!! Archivieren fehlgeschlagen ($RES)"; exit 30; }

cat > ExportOptions.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>${APPLE_TEAM_ID}</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><false/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PL

log ""
log "== Signatur im Archiv =="
APP_IN_ARCHIVE=$(ls -d build/Meeterz.xcarchive/Products/Applications/*.app | head -1)
codesign -dvv "$APP_IN_ARCHIVE" 2>&1 | grep -E "Authority|Identifier|TeamIdentifier|Signature" | tee -a "$REPORT"
security find-identity -v -p codesigning 2>&1 | tee -a "$REPORT"

log ""
log "== Exportieren (lokal, Verteilungs-Signatur) =="
xcodebuild -exportArchive \
  -archivePath build/Meeterz.xcarchive \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath build/export \
  "${AUTH[@]}" > export.log 2>&1
RES=$?
grep -iE "error|warning: |sign|certificate|profile|EXPORT" export.log | sort -u | head -40 | tee -a "$REPORT"
[ $RES -eq 0 ] || { log "!! Export fehlgeschlagen ($RES)"; exit 31; }
IPA=$(ls build/export/*.ipa | head -1)
log "IPA: $IPA"
rm -rf build/ipa-check && mkdir -p build/ipa-check && unzip -q "$IPA" -d build/ipa-check
codesign -dvv build/ipa-check/Payload/*.app 2>&1 | grep -E "Authority|TeamIdentifier" | tee -a "$REPORT"
codesign -dvv build/ipa-check/Payload/*.app/Frameworks/MapboxCommon.framework 2>&1 | grep -E "Authority|TeamIdentifier" | tee -a "$REPORT"
codesign --verify --deep --strict build/ipa-check/Payload/*.app 2>&1 | tee -a "$REPORT"

log ""
log "== Hochladen zu TestFlight (altool) =="
xcrun altool --upload-app -f "$IPA" -t ios \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" > upload.log 2>&1
RES=$?
tail -30 upload.log | tee -a "$REPORT"
[ $RES -eq 0 ] || { log "!! Upload fehlgeschlagen ($RES)"; exit 32; }
log "Hochgeladen: Version $(grep MARKETING_VERSION project.yml | head -1 | tr -d ' ') Build ${GITHUB_RUN_NUMBER:-1}"
