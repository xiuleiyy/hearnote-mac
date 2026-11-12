#!/bin/bash
set -euo pipefail

hearnote_project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hearnote_app_path="$hearnote_project_root/dist/HearNote.app"
hearnote_image_path="$hearnote_project_root/dist/HearNote.dmg"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "DMG 打包需要在 Mac 上运行；当前主机不是 Mac。"
    exit 1
fi
if [[ ! -x "$hearnote_app_path/Contents/MacOS/HearNote" ]]; then
    echo "未找到已构建的 App。请先运行：bash scripts/build-mac.sh"
    exit 1
fi
codesign --verify --strict "$hearnote_app_path"

hearnote_stage="$(mktemp -d "${TMPDIR:-/tmp}/hearnote-package.XXXXXX")"
hearnote_cleanup() {
    rm -rf "$hearnote_stage"
}
trap hearnote_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir "$hearnote_stage/payload"
ditto "$hearnote_app_path" "$hearnote_stage/payload/HearNote.app"
codesign --verify --strict "$hearnote_stage/payload/HearNote.app"
ln -s /Applications "$hearnote_stage/payload/Applications"
hdiutil create -volname HearNote \
    -srcfolder "$hearnote_stage/payload" \
    -format UDZO "$hearnote_stage/HearNote.dmg"
hdiutil verify "$hearnote_stage/HearNote.dmg"

# 完整创建并验证后再替换同名构建产物，失败时保留上一份 DMG。
mv -f "$hearnote_stage/HearNote.dmg" "$hearnote_image_path"
echo "已生成：$hearnote_image_path"
echo "打开 DMG，将 HearNote.app 拖到 Applications 即可安装。"
echo "这是本机 ad-hoc 签名的构建产物，未进行 Developer ID 签名或公证。"
