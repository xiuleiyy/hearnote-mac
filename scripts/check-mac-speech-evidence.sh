#!/bin/bash
set -euo pipefail
hearnote_project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$hearnote_project_root"
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "此检查需要 macOS 的 AVFoundation；只使用合成 PCM，不访问麦克风或语音模型。"
    exit 1
fi
hearnote_binary_dir="$(swift build -c release --show-bin-path)"
hearnote_evidence_stage="$(mktemp -d "${TMPDIR:-/tmp}/hearnote-speech-evidence.XXXXXX")"
trap 'rm -rf "$hearnote_evidence_stage"' EXIT
hearnote_objects=()
while IFS= read -r -d '' hearnote_object; do
    hearnote_objects+=("$hearnote_object")
done < <(find "$hearnote_binary_dir/HearNoteCore.build" \
    "$hearnote_binary_dir/CSpeexDSP.build" -name '*.o' -type f -print0)
if [[ "${#hearnote_objects[@]}" -eq 0 ]]; then
    echo "未找到 Core 和 DSP 对象文件，请先运行 swift build -c release。"
    exit 1
fi
xcrun swiftc -parse-as-library -O \
    -target "$(uname -m)-apple-macosx14.0" \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -I "$hearnote_binary_dir/Modules" \
    -I "$hearnote_project_root/Sources/CSpeexDSP/include" \
    Sources/HearNote/AppleSpeechPCMScanner.swift \
    scripts/check-mac-speech-evidence.swift "${hearnote_objects[@]}" \
    -o "$hearnote_evidence_stage/check-mac-speech-evidence"
"$hearnote_evidence_stage/check-mac-speech-evidence"
