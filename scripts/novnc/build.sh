#!/usr/bin/env bash
# Rebuilds BrainboxAgent/Resources/ScreenViewer/screen.html (noVNC + bridge, inlined) from a pinned noVNC release.
# noVNC is MPL-2.0 (https://github.com/novnc/noVNC); the bundle keeps its license header.
# Same version Hermes Desktop ships, so both viewers speak to Hermes' screen identically.
set -euo pipefail
NOVNC_VERSION=1.7.0
NOVNC_SHA256=32689f18d6abe96bc6530828a6bd0b9ae33bda07c083a6575ed255b5a8f2e903
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="$ROOT/BrainboxAgent/Resources/ScreenViewer"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
curl -sSfL -o "$WORK/novnc.tgz" "https://registry.npmjs.org/@novnc/novnc/-/novnc-$NOVNC_VERSION.tgz"
if [ -n "$NOVNC_SHA256" ]; then echo "$NOVNC_SHA256  $WORK/novnc.tgz" | sha256sum -c -; fi
tar -xzf "$WORK/novnc.tgz" -C "$WORK"
mkdir -p "$WORK/package/brainbox"
cp "$HERE/viewer-entry.js" "$WORK/package/brainbox/viewer-entry.js"
(cd "$WORK" && npm init -y >/dev/null && npm install --silent --no-audit --no-fund esbuild@0.24.2 >/dev/null)
mkdir -p "$OUT"
# ES module (noVNC 1.7 uses top-level await), inlined into the page: an inline module needs no
# fetch, so it runs from the app bundle without a URL scheme handler or a local server.
"$WORK/node_modules/.bin/esbuild" "$WORK/package/brainbox/viewer-entry.js" --bundle --format=esm \
  --target=safari16 --minify --legal-comments=none --log-level=warning --outfile="$WORK/bundle.js"
python3 - "$HERE/screen.template.html" "$WORK/bundle.js" "$OUT/screen.html" "$NOVNC_VERSION" <<'PY'
import sys
template, bundle, out, version = sys.argv[1:5]
code = open(bundle, encoding="utf-8").read().replace("</script", "<\\/script")
page = open(template, encoding="utf-8").read()
page = page.replace("/*NOVNC_VERSION*/", version).replace("/*BUNDLE*/", code)
open(out, "w", encoding="utf-8").write(page)
PY
cp "$WORK/package/LICENSE.txt" "$OUT/NOVNC-LICENSE.txt"
echo "wrote $OUT/screen.html ($(wc -c < "$OUT/screen.html") bytes)"
