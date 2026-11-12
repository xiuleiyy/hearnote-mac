#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "请在 macOS 14 或更高版本上构建。当前主机不是 Mac。"
    exit 1
fi
if ! xcrun --find swift >/dev/null 2>&1; then
    echo "未找到 Swift 编译器。请先运行 xcode-select --install，再重新构建。"
    exit 1
fi
hearnote_swift_version="$(swift --version)"
if [[ "$hearnote_swift_version" =~ Swift\ version\ ([0-9]+)\.([0-9]+) ]]; then
    hearnote_swift_major="${BASH_REMATCH[1]}"
    hearnote_swift_minor="${BASH_REMATCH[2]}"
    if (( hearnote_swift_major < 5 || (hearnote_swift_major == 5 && hearnote_swift_minor < 10) )); then
        echo "中英混合识别需要 Swift 5.10+，建议安装 Xcode 16 或更新版本的编译工具。"
        exit 1
    fi
fi
cd "$project_root"
swift test
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
app_path="$project_root/dist/HearNote.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_dir/HearNote" "$app_path/Contents/MacOS/HearNote"
cp "$project_root/Resources/Info.plist" "$app_path/Contents/Info.plist"
shopt -s nullglob
for hearnote_resource_bundle in "$binary_dir"/*.bundle; do
    cp -R "$hearnote_resource_bundle" "$app_path/Contents/Resources/"
done
codesign --force --sign - --entitlements "$project_root/Resources/HearNote.entitlements" "$app_path"
codesign --verify --strict "$app_path"
echo "已构建：$app_path"
if [[ "${1:-}" == "--open" ]]; then
    open "$app_path"
fi
