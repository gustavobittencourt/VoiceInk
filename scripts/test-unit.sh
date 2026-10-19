#!/usr/bin/env bash
# Roda os testes unitários de lógica pura (sem AppKit, sem SwiftData) fora do
# host app: o target VoiceInkTests do Xcode usa o VoiceInk Dev.app como
# TEST_HOST, o que abriria o app inteiro (atalhos globais, microfone).
# Aqui as fontes puras e os testes viram um bundle .xctest rodado pelo xctest.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOWS="$ROOT/VoiceInk/Features/Recording/Workflows"

SOURCES=()
for f in "$WORKFLOWS/RecordingJobQueue.swift" "$WORKFLOWS/PasteTargetPolicy.swift"; do
    [ -f "$f" ] && SOURCES+=("$f")
done
TESTS=("$ROOT"/VoiceInkTests/*.swift)

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
BUNDLE="$OUT/VoiceInkUnitTests.xctest"
mkdir -p "$BUNDLE/Contents/MacOS"
cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>VoiceInkUnitTests</string>
    <key>CFBundleIdentifier</key><string>com.prakashjoshipax.VoiceInkUnitTests</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
</dict>
</plist>
PLIST

FW="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer"
xcrun swiftc -swift-version 5 -parse-as-library -emit-library -Xlinker -bundle \
    -o "$BUNDLE/Contents/MacOS/VoiceInkUnitTests" \
    ${SOURCES[@]+"${SOURCES[@]}"} "${TESTS[@]}" \
    -F "$FW/Library/Frameworks" -I "$FW/usr/lib" -L "$FW/usr/lib" \
    -Xlinker -rpath -Xlinker "$FW/Library/Frameworks" \
    -Xlinker -rpath -Xlinker "$FW/usr/lib" \
    -framework XCTest

xcrun xctest "$BUNDLE"
