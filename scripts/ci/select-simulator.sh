#!/usr/bin/env bash
# Prints the UDID of the newest available iPhone simulator.
# Runner images change their simulator set over time, so we never
# hard-code a device name.
set -euo pipefail
xcrun simctl list devices available -j | python3 -c '
import json, re, sys
data = json.load(sys.stdin)["devices"]
best = None
for runtime, devices in data.items():
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not m:
        continue
    version = (int(m.group(1)), int(m.group(2)))
    for d in devices:
        if d.get("isAvailable") and d["name"].startswith("iPhone"):
            # prefer newest runtime, then non-"SE"/"mini" models
            score = (version, "Pro" in d["name"], "SE" not in d["name"])
            if best is None or score > best[0]:
                best = (score, d["udid"], d["name"], runtime)
if best is None:
    sys.exit("No available iPhone simulator found")
print(best[1])
print(f"Selected {best[2]} on {best[3]}", file=sys.stderr)
'
