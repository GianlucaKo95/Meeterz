#!/bin/bash
# Unit-Tests (z. B. Ladeplanung) im Simulator – schnell, ohne Netz. Läuft auch beim reinen Compile-Check.
REPORT="${REPORT:-report.txt}"
log() { echo "$@" | tee -a "$REPORT"; }
log ""
log "== Unit-Tests =="
UDID=$(xcrun simctl list devices available -j | python3 -c '
import json,sys
d=json.load(sys.stdin)["devices"]
best=""
for rt,devs in d.items():
    if "iOS" not in rt: continue
    for x in devs:
        if "iPhone" in x["name"]: best=x["udid"]
print(best)
')
[ -n "$UDID" ] || { log "!! Kein Simulator"; exit 1; }
rm -rf build/unit.xcresult
xcodebuild test \
  -project Meeterz.xcodeproj -scheme Meeterz \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath build/dd -resultBundlePath build/unit.xcresult \
  -only-testing:MeeterzTests -collect-test-diagnostics never \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES > unittest.log 2>&1
RC=$?
log "xcodebuild test Rückgabewert: $RC"
grep -E "Test Case|error:|XCTAssert|Executed|Plan " unittest.log | sed 's#/Users/runner/work/[^/]*/[^/]*/##' | head -40 | tee -a "$REPORT"
[ $RC -eq 0 ] || { log "== Letzte Zeilen =="; tail -25 unittest.log | tee -a "$REPORT"; }
exit $RC
