#!/bin/bash
# UI-Test im Simulator: Registrieren → Onboarding → Karte → Suche → Freunde/Einstellungen → Konto löschen.
# Braucht SUPABASE_ANON_KEY (öffentlicher Schlüssel); ohne wird übersprungen.

REPORT="${REPORT:-report.txt}"
log() { echo "$@" | tee -a "$REPORT"; }

log ""
log "== UI-Test =="
if [ -z "$SUPABASE_ANON_KEY" ]; then
  log "übersprungen: Secret SUPABASE_ANON_KEY fehlt"
  exit 0
fi

UDID=$(xcrun simctl list devices available -j | python3 -c '
import json,sys
d=json.load(sys.stdin)["devices"]
best=""
for rt,devs in d.items():
    if "iOS" not in rt: continue
    for x in devs:
        if "iPhone" in x["name"] and "Pro" in x["name"] and "Max" not in x["name"]:
            best=x["udid"]
print(best)
')
[ -n "$UDID" ] || { log "!! Kein Simulator"; exit 1; }

xcrun simctl boot "$UDID" > /dev/null 2>&1
xcrun simctl bootstatus "$UDID" -b > /dev/null 2>&1
xcrun simctl location "$UDID" set 51.4344,6.7623 > /dev/null 2>&1   # Duisburg

export TEST_RUNNER_SHOT_DIR="$PWD/screenshots"
export TEST_RUNNER_SB_URL="https://${CI_SUPABASE_REF}.supabase.co"
export TEST_RUNNER_SB_KEY="$SUPABASE_ANON_KEY"
rm -rf build/ui.xcresult
xcodebuild test \
  -project Meeterz.xcodeproj -scheme Meeterz \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath build/dd -resultBundlePath build/ui.xcresult \
  -only-testing:MeeterzUITests -collect-test-diagnostics never \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES > uitest.log 2>&1
RC=$?
log "xcodebuild test Rückgabewert: $RC"
grep -E "Test Case|error:|failed|XCTAssert|Executed|passed|Element nicht" uitest.log | sed 's#/Users/runner/work/[^/]*/[^/]*/##' | head -40 | tee -a "$REPORT"
if [ $RC -ne 0 ]; then
  log "== Letzte Zeilen =="
  tail -25 uitest.log | tee -a "$REPORT"
fi
xcrun simctl shutdown "$UDID" > /dev/null 2>&1
exit $RC
