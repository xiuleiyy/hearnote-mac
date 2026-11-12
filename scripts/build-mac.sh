#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "请在 macOS 14 或更高版本上构建。当前主机不是 Mac。"
    exit 1
fi
if ! xcrun --find swift >/dev/null 2>&1; then
    echo "未找到 Swift 编译器。请安装完整 Xcode 并完成首次初始化，再重新构建。"
    exit 1
fi
hearnote_developer_dir="$(xcode-select -p)"
if [[ ! -d "$hearnote_developer_dir/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework" ]] ||
   ! xcodebuild -version >/dev/null 2>&1; then
    echo "构建和 Core 测试需要完整 Xcode（含 XCTest），仅 Command Line Tools 不够。"
    echo "请安装并打开 Xcode 完成初始化，在 Xcode → Settings → Locations 选择编译工具。"
    exit 1
fi
if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
    echo "Xcode 尚未完成首次初始化。请打开 Xcode 确认许可证并安装所需组件，再重新构建。"
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
app_path="$project_root/dist/听译.app"
mkdir -p "$project_root/dist"
hearnote_stage="$(mktemp -d "$project_root/dist/.hearnote-build.XXXXXX")"
hearnote_stage_app="$hearnote_stage/听译.app"
hearnote_cleanup() {
    if [[ -d "$hearnote_stage/previous.app" && ! -e "$app_path" ]]; then
        mv "$hearnote_stage/previous.app" "$app_path"
    fi
    rm -rf "$hearnote_stage"
}
trap hearnote_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$hearnote_stage_app/Contents/MacOS" "$hearnote_stage_app/Contents/Resources"
cp "$binary_dir/HearNote" "$hearnote_stage_app/Contents/MacOS/HearNote"
cp "$project_root/Resources/Info.plist" "$hearnote_stage_app/Contents/Info.plist"
mkdir -p "$hearnote_stage_app/Contents/Resources/ThirdPartyLicenses"
cp "$project_root/Sources/CSpeexDSP/COPYING" \
    "$hearnote_stage_app/Contents/Resources/ThirdPartyLicenses/SpeexDSP.txt"
cp "$project_root/Resources/ThirdPartyLicenses/KISS-FFT.txt" \
    "$hearnote_stage_app/Contents/Resources/ThirdPartyLicenses/KISS-FFT.txt"
# 在签名前生成并放入资源目录，使 Finder、Dock 和打包后的 App 使用同一图标。
iconutil -c icns "$project_root/Resources/HearNote.iconset" \
    -o "$hearnote_stage_app/Contents/Resources/HearNote.icns"
if [[ -n "${HEARNOTE_SOURCE_COMMIT:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Add :HearNoteSourceCommit string $HEARNOTE_SOURCE_COMMIT" \
        "$hearnote_stage_app/Contents/Info.plist"
fi
if [[ "${HEARNOTE_BUILD_NUMBER:-}" =~ ^[0-9]+$ ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $HEARNOTE_BUILD_NUMBER" \
        "$hearnote_stage_app/Contents/Info.plist"
fi
shopt -s nullglob
for hearnote_resource_bundle in "$binary_dir"/*.bundle; do
    # SwiftPM 的 Bundle.module 首先在 Bundle.main.bundleURL 下寻找 bundle。
    # 当前生产依赖没有资源；若以后引入资源，也必须能脱离 .build 定位。
    cp -R "$hearnote_resource_bundle" "$hearnote_stage_app/"
done
codesign --force --sign - --entitlements "$project_root/Resources/HearNote.entitlements" "$hearnote_stage_app"
codesign --verify --strict "$hearnote_stage_app"
if [[ -e "$app_path" ]]; then
    mv "$app_path" "$hearnote_stage/previous.app"
fi
mv "$hearnote_stage_app" "$app_path"
echo "已构建：$app_path"
if [[ "${1:-}" == "--open" ]]; then
    open "$app_path"
fi
