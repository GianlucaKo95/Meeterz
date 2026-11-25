#!/bin/bash
# Kino-Builds (nur intern): IPTV-Anbieter liefern meist nur http – App Transport Security nur in diesen Builds öffnen.
# Erste Fundstelle = App (nicht das Widget). Im normalen Build bleibt ATS unverändert.
perl -0pi -e 's/(      properties:\n        CFBundleDisplayName: Meeterz\n)/$1        NSAppTransportSecurity:\n          NSAllowsArbitraryLoads: true\n/' project.yml
grep -q "NSAllowsArbitraryLoads" project.yml || { echo "!! ATS-Ausnahme nicht gesetzt"; exit 30; }
