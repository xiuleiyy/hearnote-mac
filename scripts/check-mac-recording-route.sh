#!/bin/bash
set -euo pipefail
hearnote_project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$hearnote_project_root"
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "此检查需要 macOS AVFoundation；只用合成 PCM，不访问麦克风或模型。"
    exit 1
fi
hearnote_route_stage="$(mktemp -d "${TMPDIR:-/tmp}/hearnote-recording-route.XXXXXX")"
trap 'rm -rf "$hearnote_route_stage"' EXIT
xcrun swiftc -parse-as-library -O \
    -target "$(uname -m)-apple-macosx14.0" \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    Sources/HearNote/RecordingSink.swift scripts/check-mac-recording-route.swift \
    -o "$hearnote_route_stage/check-mac-recording-route"
"$hearnote_route_stage/check-mac-recording-route"
