#!/usr/bin/env bash
# Re-emits compiler errors and test failures from a log file as GitHub
# Actions annotations, so they are visible in the PR/checks UI (and via the
# checks API) without opening raw logs.
# usage: scripts/ci/annotate-log.sh <logfile> <title>
set -uo pipefail
LOG="${1:?log file}"
TITLE="${2:-Build}"
[ -f "$LOG" ] || exit 0
python3 - "$LOG" "$TITLE" <<'PY'
import re, sys
log, title = sys.argv[1], sys.argv[2]
lines = open(log, errors="replace").read().splitlines()
pat = re.compile(r"(error:|: error |XCTAssert|failed \(|Test Case .* failed|fatal error|Fatal error|Compiling .* failed|\*\* (BUILD|TEST|ARCHIVE) FAILED|Testing failed)")
hits, seen = [], set()
for l in lines:
    l = re.sub(r"^\d{4}-\d\d-\d\dT[\d:.]+Z ", "", l).strip()
    if pat.search(l) and l not in seen:
        seen.add(l); hits.append(l[:400])
if not hits:
    sys.exit(0)
def esc(s): return s.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
chunk = 40
for i in range(0, min(len(hits), chunk * 8), chunk):
    part = hits[i:i + chunk]
    print(f"::error title={title} ({i // chunk + 1})::" + esc("\n".join(part)))
PY
