#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
binary="$(mktemp /tmp/voiceink-outputfilter.XXXXXXXX)"
trap 'rm -f "$binary"' EXIT
swiftc -O \
  VoiceInk/Features/Recording/Processing/TranscriptionOutputFilter.swift \
  VoiceInk/Features/Enhancement/State/FillerWordManager.swift \
  Tests/OutputFilter/main.swift -o "$binary"
"$binary" "$@"
