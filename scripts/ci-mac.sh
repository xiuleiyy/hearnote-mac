#!/bin/bash
set -euo pipefail

hearnote_project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$hearnote_project_root"
mkdir -p dist/ci
hearnote_commit="$(git rev-parse HEAD)"
hearnote_short_commit="${hearnote_commit:0:8}"

{
    echo "Source commit: $hearnote_commit"
    echo "Architecture: $(uname -m)"
    sw_vers
    xcodebuild -version
    swift --version
    xcrun --sdk macosx --show-sdk-version
} > dist/ci/build-environment.txt

# 交付包必须实际编译 macOS 26 的 SpeechAnalyzer 分支，不能悄悄省略新识别实现。
hearnote_swift_version="$(swift --version)"
if [[ ! "$hearnote_swift_version" =~ Swift\ version\ ([0-9]+)\.([0-9]+) ]] ||
   (( BASH_REMATCH[1] < 6 || (BASH_REMATCH[1] == 6 && BASH_REMATCH[2] < 2) )); then
    echo "本次交付需要 Swift 6.2+ 和 macOS 26 SDK，请选择 Xcode 26 或更新版本。" \
        > dist/ci/结果说明.md
    exit 1
fi

# 不记录环境变量、凭据或客户数据。所有测试只使用合成数据和 URLProtocol stub。
if ! bash scripts/build-mac.sh 2>&1 | tee dist/ci/build.log; then
    echo "macOS 构建失败；没有生成经验证的安装包。" > dist/ci/结果说明.md
    exit 1
fi
if ! bash scripts/package-mac.sh 2>&1 | tee dist/ci/package.log; then
    echo "DMG 打包失败；请查看真实构建日志。" > dist/ci/结果说明.md
    exit 1
fi
if ! bash scripts/verify-mac-build.sh 2>&1 | tee dist/ci/verify.log; then
    echo "安装包验证失败；不能标记为已验证交付。" > dist/ci/结果说明.md
    exit 1
fi

ditto -c -k --keepParent dist/听译.app \
    "dist/ci/HearNote-Mac-arm64-$hearnote_short_commit.app.zip"
cp dist/听译.dmg "dist/ci/HearNote-Mac-arm64-$hearnote_short_commit.dmg"
hearnote_archive_stage="$(mktemp -d "${TMPDIR:-/tmp}/hearnote-source.XXXXXX")"
trap 'rm -rf "$hearnote_archive_stage"' EXIT
git archive --format=tar --prefix=HearNote/ HEAD | tar -xf - -C "$hearnote_archive_stage"
if [[ -f Package.resolved ]]; then
    cp Package.resolved "$hearnote_archive_stage/HearNote/"
    cp Package.resolved dist/ci/Package.resolved
fi
ditto -c -k --keepParent "$hearnote_archive_stage/HearNote" \
    "dist/ci/HearNote-Mac-Source-$hearnote_short_commit.zip"
hearnote_feedback_base="627374f98d25c50bae110f9693cc385850f34cfa"
git diff "$hearnote_feedback_base" HEAD -- Sources/ Tests/ scripts/ Resources/ Package.swift \
    > dist/ci/最小修复.diff
(
    cd dist/ci
    shasum -a 256 *.app.zip *.dmg HearNote-Mac-Source-*.zip > SHA256SUMS
)
{
    echo "# 听译 macOS CI 构建交付"
    echo
    echo "- 源码提交：\`$hearnote_commit\`"
    echo "- 修复 diff 基线：\`$hearnote_feedback_base\`。"
    echo "- 架构：arm64；部署目标：macOS 14.0。"
    echo "- 签名：本机 ad-hoc；没有 Developer ID 签名或公证。"
    echo "- 完整 Core XCTest、release 编译、签名与架构检查：通过，数量见 build.log。"
    echo "- App 移动后独立启动检查、DMG 校验及只读挂载检查：通过，详见 verify.log。"
    echo "- 麦克风、系统音、Apple／Whisper 推理、翻译、北京网络速度及 GUI 功能：未测。"
    echo "- 未使用客户 Bedrock API Key；不是 Mac 实机功能验收完成。"
    echo
    echo "build-environment.txt 记录实际 macOS、Xcode、Swift 与 SDK；源码 ZIP 包含本次解析的 Package.resolved。"
} > dist/ci/结果说明.md
