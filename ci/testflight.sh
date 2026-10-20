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

# Nur Release-Versionen: Apple lehnt Builds ab, die mit einer Beta-Xcode gebaut wurden
XCODE=$(ls -d /Applications/Xcode_27* 2>/dev/null | grep -viE "beta|candidate|_RC" | sort -V | tail -1)
[ -n "$XCODE" ] || XCODE=$(ls -d /Applications/Xcode_27* 2>/dev/null | sort -V | tail -1)
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

KEYDIR="$HOME/.appstoreconnect/private_keys"
mkdir -p "$KEYDIR"
printf "%s\n" "$ASC_KEY_P8" > "$KEYDIR/AuthKey_${ASC_KEY_ID}.p8"
export ASC_KEY_PATH="$KEYDIR/AuthKey_${ASC_KEY_ID}.p8"

# Manuelle Signierung: Zertifikat und Profil über die API erzeugen (und am Ende wieder löschen)
mkdir -p build
WORK="$PWD/build/signing"
PROFILE_NAME="Meeterz CI ${GITHUB_RUN_NUMBER:-0}-$(date +%s)"
KC="$PWD/build/ci.keychain-db"
cleanup() {
  python3 ci/asc.py cleanup "$WORK" 2>&1 | tee -a "$REPORT"
  security delete-keychain "$KC" >/dev/null 2>&1
}
trap cleanup EXIT

log ""
log "== Zertifikat und Profil erzeugen =="
python3 ci/asc.py create "$WORK" de.koeven.meeterz "$PROFILE_NAME" 2>&1 | tee -a "$REPORT"
[ -f "$WORK/ids.json" ] || { log "!! Zertifikat/Profil konnten nicht erzeugt werden"; exit 33; }
PROFILE_UUID=$(python3 -c "import json;print(json.load(open('$WORK/ids.json'))['uuid'])")

openssl x509 -inform DER -in "$WORK/cert.der" -out "$WORK/cert.pem"
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/sign.p12" -passout pass:ci -legacy >/dev/null 2>&1 \
  || openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/sign.p12" -passout pass:ci
security create-keychain -p ci "$KC"
security set-keychain-settings -lut 21600 "$KC"
security unlock-keychain -p ci "$KC"
for url in https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer https://www.apple.com/certificateauthority/AppleWWDRCAG6.cer; do
  curl -sfL "$url" -o "$WORK/ca.cer" && security import "$WORK/ca.cer" -k "$KC" -T /usr/bin/codesign >/dev/null 2>&1
done
security import "$WORK/sign.p12" -k "$KC" -P ci -T /usr/bin/codesign -T /usr/bin/security 2>&1 | tee -a "$REPORT"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k ci "$KC" >/dev/null 2>&1
security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
security find-identity -v -p codesigning "$KC" 2>&1 | tee -a "$REPORT"

mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
cp "$WORK/profile.mobileprovision" "$HOME/Library/MobileDevice/Provisioning Profiles/$PROFILE_UUID.mobileprovision"
cp "$WORK/profile.mobileprovision" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/$PROFILE_UUID.mobileprovision"

# App-Target auf manuelle Signierung mit diesem Profil stellen
python3 - "$PROFILE_NAME" <<'PY'
import sys
name = sys.argv[1]
s = open("project.yml").read()
s = s.replace("CODE_SIGN_STYLE: Automatic",
              f'CODE_SIGN_STYLE: Manual\n        CODE_SIGN_IDENTITY: "Apple Distribution"\n        PROVISIONING_PROFILE_SPECIFIER: "{name}"', 1)
open("project.yml", "w").write(s)
PY
xcodegen generate 2>&1 | tee -a "$REPORT"

log ""
log "== Archivieren =="
xcodebuild archive \
  -project Meeterz.xcodeproj -scheme Meeterz -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/Meeterz.xcarchive \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" > archive.log 2>&1
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
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>provisioningProfiles</key><dict><key>de.koeven.meeterz</key><string>${PROFILE_NAME}</string></dict>
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
  -exportPath build/export > export.log 2>&1
RES=$?
grep -iE "error|warning: |sign|certificate|profile|EXPORT" export.log | sort -u | head -40 | tee -a "$REPORT"
[ $RES -eq 0 ] || { log "!! Export fehlgeschlagen ($RES)"; exit 31; }
IPA=$(ls build/export/*.ipa | head -1)
log "IPA: $IPA"
rm -rf build/ipa-check && mkdir -p build/ipa-check && unzip -q "$IPA" -d build/ipa-check
codesign -dvv build/ipa-check/Payload/*.app 2>&1 | grep -E "Authority|TeamIdentifier" | tee -a "$REPORT"
codesign -dvv build/ipa-check/Payload/*.app/Frameworks/MapboxCommon.framework 2>&1 | grep -E "Authority|TeamIdentifier" | tee -a "$REPORT"
codesign --verify --deep --strict --verbose=2 build/ipa-check/Payload/*.app 2>&1 | tail -5 | tee -a "$REPORT"
codesign -dvvv build/ipa-check/Payload/*.app 2>&1 | grep -E "Timestamp|flags|Format|CDHash|Runtime" | tee -a "$REPORT"
log "-- Provisioning-Profil im IPA --"
security cms -D -i build/ipa-check/Payload/*.app/embedded.mobileprovision 2>/dev/null > build/profile.plist
for k in Name TeamName CreationDate ExpirationDate ProvisionsAllDevices; do
  printf "%s: " "$k" | tee -a "$REPORT"; /usr/libexec/PlistBuddy -c "Print :$k" build/profile.plist 2>&1 | tee -a "$REPORT"
done
/usr/libexec/PlistBuddy -c "Print :Entitlements" build/profile.plist 2>&1 | tee -a "$REPORT"

log ""
log "== Hochladen zu TestFlight (altool) =="
xcrun altool --upload-app -f "$IPA" -t ios \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" > upload.log 2>&1
RES=$?
tail -30 upload.log | tee -a "$REPORT"
[ $RES -eq 0 ] || { log "!! Upload fehlgeschlagen ($RES)"; exit 32; }
log "Hochgeladen: Version $(grep MARKETING_VERSION project.yml | head -1 | sed 's/.*: *//; s/\"//g') Build ${GITHUB_RUN_NUMBER:-1}"
