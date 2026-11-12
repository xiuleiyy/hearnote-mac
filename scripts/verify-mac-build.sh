#!/bin/bash
set -euo pipefail

hearnote_project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$hearnote_project_root"
hearnote_app_path="$hearnote_project_root/dist/HearNote.app"
hearnote_binary="$hearnote_app_path/Contents/MacOS/HearNote"
hearnote_expected_arch="${HEARNOTE_EXPECTED_ARCH:-$(uname -m)}"
hearnote_arch="$(lipo -archs "$hearnote_binary")"
if [[ "$hearnote_arch" != "$hearnote_expected_arch" ]]; then
    echo "架构不符合要求：$hearnote_arch；预期 $hearnote_expected_arch。"
    exit 1
fi
file "$hearnote_binary"
codesign --verify --strict "$hearnote_app_path"
codesign -dvv "$hearnote_app_path" 2>&1
xcrun vtool -show-build "$hearnote_binary"
otool -L "$hearnote_binary"

python3 - "$hearnote_binary" "$hearnote_app_path" <<'PY'
import plistlib, re, subprocess, sys
from pathlib import Path
binary, app = Path(sys.argv[1]), Path(sys.argv[2])
with (app / "Contents/Info.plist").open("rb") as source:
    info = plistlib.load(source)
assert info["LSMinimumSystemVersion"] == "14.0", "Info.plist 最低系统错误"
build = subprocess.check_output(["xcrun", "vtool", "-show-build", str(binary)], text=True)
assert re.search(r"\bminos\s+14\.0\b", build), "Mach-O 部署目标不是 macOS 14.0"
libraries = subprocess.check_output(["otool", "-L", str(binary)], text=True).splitlines()[1:]
for line in libraries:
    library = line.strip().split(" (", 1)[0]
    allowed = library.startswith(("/System/Library/", "/usr/lib/", "@rpath/libswift"))
    assert allowed, "发现需要单独打包验证的动态库依赖：" + library
print("arm64/macOS 14 目标、权限说明与系统动态库依赖检查通过。")
for key in ("NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription", "NSScreenCaptureUsageDescription"):
    assert info.get(key), "权限用途说明缺失：" + key
PY

hearnote_verify_stage="$(mktemp -d "${TMPDIR:-/tmp}/hearnote-verify.XXXXXX")"
hearnote_smoke_pid=""
hearnote_mounted=0
hearnote_cleanup() {
    if [[ -n "$hearnote_smoke_pid" ]] && kill -0 "$hearnote_smoke_pid" 2>/dev/null; then
        kill "$hearnote_smoke_pid" 2>/dev/null || true
        wait "$hearnote_smoke_pid" 2>/dev/null || true
    fi
    if [[ "$hearnote_mounted" == 1 ]]; then
        hdiutil detach "$hearnote_verify_stage/mount" >/dev/null || true
    fi
    if [[ -d "$hearnote_verify_stage/build-cache" && ! -e "$hearnote_project_root/.build" ]]; then
        mv "$hearnote_verify_stage/build-cache" "$hearnote_project_root/.build"
    fi
    rm -rf "$hearnote_verify_stage"
}
trap hearnote_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ditto "$hearnote_app_path" "$hearnote_verify_stage/HearNote.app"
codesign --verify --strict "$hearnote_verify_stage/HearNote.app"
# 隐藏构建缓存，确保移动后启动不借助原 .build 路径回退。
if [[ -d .build ]]; then
    mv .build "$hearnote_verify_stage/build-cache"
fi
mkdir -p dist/ci
"$hearnote_verify_stage/HearNote.app/Contents/MacOS/HearNote" \
    > dist/ci/startup-smoke.log 2>&1 &
hearnote_smoke_pid=$!
for hearnote_second in {1..8}; do
    sleep 1
    if ! kill -0 "$hearnote_smoke_pid" 2>/dev/null; then
        echo "移动后的 App 启动提前退出，请查看 startup-smoke.log。"
        exit 1
    fi
done
kill "$hearnote_smoke_pid"
wait "$hearnote_smoke_pid" 2>/dev/null || true
hearnote_smoke_pid=""
echo "App 移动后启动并持续运行 8 秒；此检查不代表 GUI 或音频功能验收。"
if [[ -d "$hearnote_verify_stage/build-cache" ]]; then
    mv "$hearnote_verify_stage/build-cache" .build
fi

hdiutil verify dist/HearNote.dmg
mkdir "$hearnote_verify_stage/mount"
hdiutil attach dist/HearNote.dmg -readonly -nobrowse \
    -mountpoint "$hearnote_verify_stage/mount"
hearnote_mounted=1
test -x "$hearnote_verify_stage/mount/HearNote.app/Contents/MacOS/HearNote"
test "$(readlink "$hearnote_verify_stage/mount/Applications")" == "/Applications"
codesign --verify --strict "$hearnote_verify_stage/mount/HearNote.app"
hdiutil detach "$hearnote_verify_stage/mount"
hearnote_mounted=0
echo "DMG 校验、只读挂载、App 签名与 Applications 快捷方式检查通过。"
