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
  UDID=$(SIZE=$SIZE xcrun simctl list devices available -j | python3 -c '
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
  xcrun simctl location "$UDID" set 50.9413,6.9583 > /dev/null 2>&1   # Köln, Dom (erfundener Standort)
  xcrun simctl privacy "$UDID" grant location de.koeven.meeterz > /dev/null 2>&1 || true
  xcrun simctl privacy "$UDID" grant location-always de.koeven.meeterz > /dev/null 2>&1 || true
  xcrun simctl status_bar "$UDID" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 > /dev/null 2>&1 || true

  for L in $LANGS; do
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
