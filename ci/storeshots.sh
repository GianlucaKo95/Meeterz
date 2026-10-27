#!/bin/bash
# App-Store-Screenshots mit erfundenen Daten (MeeterzStoreShots) in mehreren Sprachen und zwei Displaygrößen.
# Ergebnis: storeshots/<pro|promax>/<sprache>/NN-name.png
REPORT="${REPORT:-report.txt}"
log() { echo "$@" | tee -a "$REPORT"; }
LANGS="${SHOT_LANGS:-de en fr es pt tr it}"
SIZES="${SHOT_SIZES:-pro promax}"

log ""
log "== App-Store-Screenshots: $LANGS / $SIZES =="
[ -n "$SUPABASE_ANON_KEY" ] || { log "!! SUPABASE_ANON_KEY fehlt"; exit 30; }

xcodebuild build-for-testing \
  -project Meeterz.xcodeproj -scheme Meeterz \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/dd \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES > bft.log 2>&1
RC=$?
log "build-for-testing: $RC"
[ $RC -eq 0 ] || { grep -E -A6 "error:" bft.log | head -60 | tee -a "$REPORT"; exit 31; }

export TEST_RUNNER_SB_URL="https://${CI_SUPABASE_REF}.supabase.co"
export TEST_RUNNER_SB_KEY="$SUPABASE_ANON_KEY"
export TEST_RUNNER_SHOT_DIR="$PWD/screenshots"
FAILED=0

for SIZE in $SIZES; do
  UDID=$(xcrun simctl list devices available -j | SIZE=$SIZE python3 -c '
import json, os, sys
want_max = os.environ["SIZE"] == "promax"
best = ""
for rt, devs in json.load(sys.stdin)["devices"].items():
    if "iOS" not in rt: continue
    for x in devs:
        n = x["name"]
        if "iPhone" in n and "Pro" in n and ("Max" in n) == want_max: best = x["udid"]; name = n
print(best)')
  [ -n "$UDID" ] || { log "!! Kein Simulator für $SIZE"; FAILED=1; continue; }
  log "Simulator $SIZE: $(xcrun simctl list devices | grep "$UDID" | sed 's/(.*//' | xargs)"
  xcrun simctl boot "$UDID" > /dev/null 2>&1
  xcrun simctl bootstatus "$UDID" -b > /dev/null 2>&1
  # Erst installieren, dann Rechte geben – für eine noch nicht installierte App greift „privacy grant“ nicht
  APP=$(ls -d build/dd/Build/Products/*-iphonesimulator/Meeterz.app 2>/dev/null | head -1)
  xcrun simctl install "$UDID" "$APP" >> "$REPORT" 2>&1 || log "!! Installation fehlgeschlagen ($APP)"
  for S in location-always location; do
    xcrun simctl privacy "$UDID" grant $S de.koeven.meeterz >> "$REPORT" 2>&1 || true
  done
  xcrun simctl status_bar "$UDID" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 > /dev/null 2>&1 || true

  for L in $LANGS; do
    # Schauplatz je Sprache (muss zu MeeterzStoreShots.scenario passen)
    case $L in
      en) POS=40.7580,-73.9855 ;;   # New York, Times Square
      fr) POS=48.8584,2.3470 ;;     # Paris, Châtelet
      es) POS=40.4169,-3.7035 ;;    # Madrid, Puerta del Sol
      pt) POS=38.7139,-9.1394 ;;    # Lissabon, Rossio
      tr) POS=41.0370,28.9850 ;;    # Istanbul, Taksim
      it) POS=41.8960,12.4823 ;;    # Rom, Piazza Venezia
      *)  POS=50.9360,6.9475 ;;     # Köln, Neumarkt (nicht am Dom: dort führt die Route sofort in den Tunnel am Hbf)
    esac
    xcrun simctl location "$UDID" set "$POS" > /dev/null 2>&1
    export TEST_RUNNER_SHOT_LANG="$L"
    export TEST_RUNNER_STORE_SHOT_DIR="$PWD/storeshots/$SIZE"
    xcodebuild test-without-building \
      -project Meeterz.xcodeproj -scheme Meeterz \
      -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath build/dd \
      -resultBundlePath "build/shots-$SIZE-$L.xcresult" \
      -only-testing:MeeterzUITests/MeeterzStoreShots -collect-test-diagnostics never \
      CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES > "shots-$SIZE-$L.log" 2>&1
    R=$?
    N=$(ls "storeshots/$SIZE/$L" 2>/dev/null | wc -l | xargs)
    log "  $SIZE/$L: Rückgabewert $R, $N Bilder"
    if [ $R -ne 0 ]; then
      FAILED=1
      grep -E "error:|Element nicht|failed" "shots-$SIZE-$L.log" | sed 's#/Users/runner/work/[^/]*/[^/]*/##' | head -8 | tee -a "$REPORT"
    fi
  done
  xcrun simctl shutdown "$UDID" > /dev/null 2>&1
done
exit $FAILED
