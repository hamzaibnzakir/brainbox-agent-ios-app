#!/usr/bin/env bash
# Verifies an .ipa's structure and build metadata and reports, honestly,
# whether it is signed. Runs on the macOS runner (plutil, lipo, codesign).
#
# usage: scripts/ci/verify-ipa.sh <file.ipa> [expect-signed|expect-unsigned]
set -euo pipefail
IPA="${1:?ipa path}"
EXPECT="${2:-expect-unsigned}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail() { echo "::error title=IPA verification failed::$1"; exit 1; }

[ -s "$IPA" ] || fail "$IPA is missing or empty"
unzip -q "$IPA" -d "$WORK" || fail "not a valid zip archive"
APP=$(find "$WORK/Payload" -maxdepth 1 -name "*.app" -type d | head -n 1)
[ -n "$APP" ] || fail "no Payload/*.app inside the IPA"
PLIST="$APP/Info.plist"
[ -f "$PLIST" ] || fail "Info.plist missing"

read_key() { plutil -extract "$1" raw -o - "$PLIST" 2>/dev/null || echo ""; }
BUNDLE_ID=$(read_key CFBundleIdentifier)
VERSION=$(read_key CFBundleShortVersionString)
BUILD=$(read_key CFBundleVersion)
EXEC=$(read_key CFBundleExecutable)
MIN_OS=$(read_key MinimumOSVersion)
PLATFORM=$(read_key DTPlatformName)

[ -n "$BUNDLE_ID" ] || fail "CFBundleIdentifier missing"
[ -n "$EXEC" ] && [ -f "$APP/$EXEC" ] || fail "main executable '$EXEC' missing"
[ "$PLATFORM" = "iphoneos" ] || fail "built for '$PLATFORM', expected iphoneos (device)"
ARCHS=$(lipo -archs "$APP/$EXEC" 2>/dev/null || echo "?")
case "$ARCHS" in *arm64*) ;; *) fail "executable architectures '$ARCHS' do not include arm64";; esac
[ -d "$APP/Assets.car" ] || [ -f "$APP/Assets.car" ] || echo "::warning title=IPA::Assets.car not found (icons may be missing)"
if [ -d "$APP/PlugIns/BrainboxWidgets.appex" ]; then echo "::notice title=IPA::widget + Live Activity extension embedded"; else echo "::warning title=IPA::widget extension not embedded"; fi

SIGNED=no
if codesign -v "$APP" >/dev/null 2>&1 && [ -f "$APP/embedded.mobileprovision" ]; then SIGNED=yes; fi

SIZE=$(du -h "$IPA" | cut -f1)
echo "::notice title=IPA verified::$BUNDLE_ID $VERSION ($BUILD) · min iOS $MIN_OS · $ARCHS · $SIZE · signed=$SIGNED"

if [ "$EXPECT" = "expect-signed" ] && [ "$SIGNED" != "yes" ]; then
  fail "expected a signed IPA (embedded.mobileprovision + valid signature) but it is not signed"
fi
if [ "$EXPECT" = "expect-unsigned" ] && [ "$SIGNED" = "yes" ]; then
  echo "::warning title=IPA::expected unsigned but a signature was found"
fi
if [ "$SIGNED" = "no" ]; then
  echo "::notice title=Unsigned IPA::This IPA is NOT signed. Install it with Sideloadly/AltStore/SideStore (they sign it with your Apple ID), or run the Signed IPA workflow with signing secrets."
fi
