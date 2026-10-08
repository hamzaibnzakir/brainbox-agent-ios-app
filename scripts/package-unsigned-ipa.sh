#!/usr/bin/env bash
# Turns an unsigned .xcarchive into an unsigned .ipa (a zip with a Payload/
# folder). Sideloading tools such as Sideloadly, AltStore and SideStore sign
# it with your own Apple ID when installing.
#
# usage: scripts/package-unsigned-ipa.sh <path.xcarchive> <output.ipa>
set -euo pipefail
ARCHIVE="${1:?archive path}"
OUTPUT="${2:?output ipa path}"
APP=$(find "$ARCHIVE/Products/Applications" -maxdepth 1 -name "*.app" | head -n 1)
if [ -z "$APP" ]; then
  echo "No .app found in $ARCHIVE" >&2
  exit 1
fi
WORK=$(mktemp -d)
mkdir -p "$WORK/Payload"
cp -R "$APP" "$WORK/Payload/"
# Strip any leftover signature so tools re-sign cleanly
rm -rf "$WORK/Payload/$(basename "$APP")/_CodeSignature"
OUTPUT_ABS="$(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT")"
rm -f "$OUTPUT_ABS"
( cd "$WORK" && zip -qry "$OUTPUT_ABS" Payload )
rm -rf "$WORK"
echo "Created $OUTPUT_ABS ($(du -h "$OUTPUT_ABS" | cut -f1))"
unzip -l "$OUTPUT_ABS" | tail -n 3
