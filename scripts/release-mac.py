#!/usr/bin/env python3
"""只发布经过 Mac CI 验证的安装包；发布后保留最近三个自动 Release。"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

REPOSITORY = "xiuleiyy/hearnote-mac"
MARKER_RE = re.compile(
    r"<!-- hearnote-managed-release:v1 "
    r"commit=([0-9a-f]{40}) run=([0-9]+) number=([0-9]+) -->"
)
TAG_RE = re.compile(r"mac-[0-9]{8}-[0-9]+-[0-9a-f]{8}")
ASSETS = ("HearNote-Mac-arm64.dmg", "HearNote-Mac-arm64.app.zip",
          "SHA256SUMS", "Installation.md")
GATEKEEPER_OPENING_GUIDE = (
    "## 首次被 macOS 拦截时\n\n"
    f"以下步骤仅适用于从[本仓库 GitHub Releases](https://github.com/{REPOSITORY}/releases)"
    "下载的听译。\n\n"
    "当前安装包使用 ad-hoc 签名，未做 Developer ID 签名或 Apple 公证。"
    "如果看到 `Apple could not verify ...` 或“Apple 无法验证”，请按以下步骤打开：\n\n"
    "1. 点击“完成 / Done”，保留 App。\n\n"
    "2. 打开“系统设置 → 隐私与安全性”，向下找到听译的提示，"
    "点击“仍要打开 / Open Anyway”。\n\n"
    "3. 按提示输入 Mac 登录密码或使用 Touch ID，再确认“打开 / Open”。\n\n"
    "若没有“仍要打开”按钮，先从“应用程序”重新尝试启动听译，再返回“隐私与安全性”。"
    "完成授权后，这次安装通常可以直接双击打开。\n\n"
    "无需关闭系统整体保护。[Apple 官方说明](https://support.apple.com/zh-cn/102445)。\n\n"
)


class ReleaseError(RuntimeError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


class GitHub:
    def __init__(self, repo: str):
        self.repo = repo

    def command(self, *args: str) -> str:
        try:
            result = subprocess.run(
                ["gh", *args], check=True, capture_output=True, text=True, timeout=300
            )
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
            # 不回显子进程输出或环境变量，避免凭据出现在 CI 日志中。
            raise ReleaseError("GitHub 操作失败，请检查该步骤的权限和网络后重跑。") from exc
        return result.stdout

    def api(self, suffix: str, *, paginate: bool = False):
        endpoint = f"repos/{self.repo}" + (f"/{suffix}" if suffix else "")
        args = ["api", endpoint]
        if paginate:
            args += ["--paginate", "--slurp"]
        try:
            return json.loads(self.command(*args))
        except json.JSONDecodeError as exc:
            raise ReleaseError("GitHub 返回了无法校验的响应。") from exc

    def releases(self) -> list[dict]:
        pages = self.api("releases?per_page=100", paginate=True)
        return [release for page in pages for release in page]

    def head(self) -> str:
        return self.api("git/ref/heads/main")["object"]["sha"]

    def tag_commit(self, tag: str) -> str | None:
        refs = self.api(f"git/matching-refs/tags/{tag}")
        exact = [ref for ref in refs if ref.get("ref") == f"refs/tags/{tag}"]
        if not exact:
            return None
        if len(exact) != 1:
            raise ReleaseError("发布标签存在歧义，停止发布。")
        obj = exact[0]["object"]
        for _ in range(10):
            if obj["type"] == "commit":
                return obj["sha"]
            if obj["type"] != "tag":
                break
            obj = self.api(f"git/tags/{obj['sha']}")["object"]
        raise ReleaseError("发布标签未指向可校验的提交。")


def managed_release(release: dict) -> bool:
    marker = MARKER_RE.search(release.get("body") or "")
    tag = release.get("tag_name") or ""
    if not marker or not TAG_RE.fullmatch(tag):
        return False
    commit, _run_id, number = marker.groups()
    return tag.endswith(f"-{number}-{commit[:8]}")


def complete_assets(release: dict) -> bool:
    assets = release.get("assets", [])
    return (
        len(assets) == len(ASSETS)
        and {asset.get("name") for asset in assets} == set(ASSETS)
        and all(asset.get("state") == "uploaded"
                and isinstance(asset.get("size"), int) and asset["size"] > 0
                for asset in assets)
    )


def release_for_tag(github: GitHub, tag: str) -> dict | None:
    matching = [release for release in github.releases() if release["tag_name"] == tag]
    if len(matching) > 1:
        raise ReleaseError("同一标签出现多个 Release，停止发布。")
    return matching[0] if matching else None


def validate_build(github: GitHub, args) -> dict:
    repo = github.api("")
    if repo.get("full_name") != REPOSITORY or repo.get("private") is not False:
        raise ReleaseError("仓库身份或 public 状态不符合当前授权，停止发布。")
    if repo.get("default_branch") != "main":
        raise ReleaseError("默认分支已变化，停止发布。")
    run = github.api(f"actions/runs/{args.run_id}")
    if (run.get("head_sha") != args.commit or run.get("head_branch") != "main"
            or run.get("path") != ".github/workflows/mac-build.yml"
            or run.get("event") not in ("push", "workflow_dispatch")):
        raise ReleaseError("CI 记录与本次 main 提交不一致。")
    # 只重跑失败的发布 job 时，当前 attempt 可以没有 build。
    # 选全部 attempts 中最后一次实际执行的 build；较早的成功不能覆盖较晚失败。
    pages = github.api(f"actions/runs/{args.run_id}/jobs?filter=all&per_page=100",
                       paginate=True)
    jobs = [job for page in pages for job in page["jobs"] if job["name"] == args.build_job]
    if not jobs or any(not isinstance(job.get("run_attempt"), int)
                       or not isinstance(job.get("id"), int) for job in jobs):
        raise ReleaseError("无法确定对应的 Mac 构建任务。")
    latest_build = max(jobs, key=lambda job: (job["run_attempt"], job["id"]))
    if (latest_build.get("status") != "completed"
            or latest_build.get("conclusion") != "success"
            or latest_build.get("head_sha") != args.commit):
        raise ReleaseError("对应的 Mac 构建任务尚未成功，不发布安装包。")
    created = datetime.fromisoformat(run["created_at"].replace("Z", "+00:00"))
    date = created.astimezone(timezone.utc).strftime("%Y%m%d")
    expected_tag = f"mac-{date}-{run['run_number']}-{args.commit[:8]}"
    if args.tag is not None and args.tag != expected_tag:
        raise ReleaseError("标签必须绑定原始 CI 日期、run_number 和源码提交。")
    args.tag = expected_tag
    return run


def prepare_assets(args, destination: Path) -> list[Path]:
    dist = Path(args.dist)
    short = args.commit[:8]
    sums_path = dist / "SHA256SUMS"
    evidence_path = dist / "build-environment.txt"
    for path in (sums_path, evidence_path):
        if path.is_symlink() or not path.is_file():
            raise ReleaseError("缺少 CI 校验清单或构建环境记录。")
    if f"Source commit: {args.commit}" not in evidence_path.read_text().splitlines():
        raise ReleaseError("安装包构建记录不属于本次提交。")
    sums = {}
    for line in sums_path.read_text().splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([^\r\n]+)", line)
        if not match or match[2] in sums:
            raise ReleaseError("CI 校验清单格式不正确。")
        sums[match[2]] = match[1]
    pairs = (
        (f"HearNote-Mac-arm64-{short}.dmg", ASSETS[0]),
        (f"HearNote-Mac-arm64-{short}.app.zip", ASSETS[1]),
    )
    for source_name, target_name in pairs:
        source = dist / source_name
        if source.is_symlink() or not source.is_file() or source.stat().st_size == 0:
            raise ReleaseError("缺少本次 CI 生成的非空安装包。")
        if sums.get(source_name) != sha256(source):
            raise ReleaseError("安装包 SHA-256 与 CI 清单不一致。")
        shutil.copyfile(source, destination / target_name)
    (destination / ASSETS[3]).write_text(
        "# 听译 Mac 安装说明\n\n"
        "支持 Apple Silicon（M 系列）Mac，macOS 14 及以上。使用安装包无需 Xcode。\n\n"
        "公开 GitHub Releases 的安装包可以直接从浏览器下载，无需登录 GitHub。\n\n"
        "1. 下载并双击 `HearNote-Mac-arm64.dmg`，将听译.app 拖到“应用程序”，再从那里打开。\n"
        "2. 若首次被系统拦截，请按下方“首次被 macOS 拦截时”的步骤授权。\n"
        "3. 翻译与摘要需配置自己的 Bedrock API Key；Key 保存在本机 Keychain。"
        "也可以暂时跳过配置，仅使用录音与本地转写。\n"
        "4. 按录音来源授予麦克风／系统录制权限；首次使用 Whisper 需下载或导入本地模型，"
        "之后复用缓存。\n\n"
        + GATEKEEPER_OPENING_GUIDE
        + f"源码提交：`{args.commit}`。\n\n"
        "自动构建验证不代表真实会议识别准确度、外放双讲或北京网络延迟已经验收。\n",
        encoding="utf-8",
    )
    content = "".join(f"{sha256(destination / name)}  {name}\n"
                      for name in (ASSETS[0], ASSETS[1], ASSETS[3]))
    (destination / ASSETS[2]).write_text(content, encoding="utf-8")
    return [destination / name for name in ASSETS]


def verify_remote(github: GitHub, args, release: dict, staged: list[Path]) -> None:
    marker = f"commit={args.commit} run={args.run_id} "
    if not managed_release(release) or marker not in release.get("body", ""):
        raise ReleaseError("现有 Release 不属于本次自动发布，拒绝修改。")
    if github.tag_commit(args.tag) != args.commit:
        raise ReleaseError("远端发布标签与安装包源码提交不一致。")
    assets = release.get("assets", [])
    if not complete_assets(release):
        raise ReleaseError("Release 附件数量或名称不正确。")
    expected = {path.name: path for path in staged}
    for asset in assets:
        if (asset.get("state") != "uploaded" or asset.get("size", 0) <= 0
                or asset["size"] != expected[asset["name"]].stat().st_size):
            raise ReleaseError("Release 附件不完整或大小不一致。")
    with tempfile.TemporaryDirectory(prefix="hearnote-release-verify-") as directory:
        download = Path(directory)
        github.command("release", "download", args.tag, "--repo", args.repo,
                       "--dir", str(download))
        for source in staged:
            actual = download / source.name
            if not actual.is_file() or sha256(actual) != sha256(source):
                raise ReleaseError("回下载的 Release 附件 SHA-256 不一致，停止发布／清理。")


def prune(github: GitHub, args, current_id: int) -> None:
    if github.head() != args.commit:
        print("main 已更新，保留现有 Releases，由新构建继续发布。")
        return
    releases = [
        release for release in github.releases()
        if managed_release(release) and not release.get("draft")
        and not release.get("prerelease") and release.get("published_at")
        and complete_assets(release)
    ]
    releases.sort(key=lambda release: (release["published_at"], release["id"]), reverse=True)
    if current_id not in {release["id"] for release in releases[:args.retain]}:
        raise ReleaseError("本次已发布版本不在保留集合中，不清理任何 Release。")
    for release in releases[args.retain:]:
        if github.head() != args.commit:
            print("main 已更新，停止清理旧 Releases。")
            return
        # 只删除 Release 和其附件，保留源码 tag；不处理未知／手工 Release。
        github.command("release", "delete", release["tag_name"], "--repo", args.repo,
                       "--yes")
        print(f"已清理旧 Release：{release['tag_name']}")


def publish(args, github: GitHub) -> bool:
    run = validate_build(github, args)
    if github.head() != args.commit:
        print("main 已有更新，跳过过期构建发布，不修改最新版或清理历史版本。")
        return False
    with tempfile.TemporaryDirectory(prefix="hearnote-release-stage-") as directory:
        stage = Path(directory)
        staged = prepare_assets(args, stage)
        release = release_for_tag(github, args.tag)
        tag_commit = github.tag_commit(args.tag)
        if tag_commit is not None and tag_commit != args.commit:
            raise ReleaseError("标签已指向其他提交，拒绝覆盖。")
        if release is not None:
            marker = f"commit={args.commit} run={args.run_id} "
            if (not managed_release(release) or marker not in release.get("body", "")
                    or release.get("prerelease")):
                raise ReleaseError("Release 已被其他内容占用，拒绝覆盖。")
            if not release.get("draft"):
                verify_remote(github, args, release, staged)
                latest = github.api("releases/latest")
                if latest["id"] == release["id"]:
                    prune(github, args, release["id"])
                print(f"已确认已有发布版本：{release['html_url']}")
                return True
        else:
            if tag_commit is None:
                github.command(
                    "api", f"repos/{args.repo}/git/refs", "--method", "POST",
                    "--raw-field", f"ref=refs/tags/{args.tag}",
                    "--raw-field", f"sha={args.commit}",
                )
            if github.tag_commit(args.tag) != args.commit:
                raise ReleaseError("新建标签与源码提交不一致，停止发布。")
            notes = stage / "release-notes.md"
            notes.write_text(
                f"<!-- hearnote-managed-release:v1 commit={args.commit} "
                f"run={args.run_id} number={run['run_number']} -->\n\n"
                "下载 **HearNote-Mac-arm64.dmg**，拖入“应用程序”后打开听译。\n\n"
                "公开 Release 附件可以直接从浏览器下载，无需登录 GitHub。\n\n"
                "- 支持 Apple Silicon（M 系列）、macOS 14+；使用无需 Xcode。\n"
                "- Mac CI 完成 Core 测试、release 编译、音频处理器合成检查、"
                "签名／架构、独立启动、图标及 DMG 挂载验证。\n"
                "- 首次启动可能被 macOS 拦截，处理步骤见下方说明。\n"
                "- 首次需准备语音识别模型、按来源授予录音权限；翻译和摘要需自己的 Bedrock API Key。\n"
                "- 实际会议准确度、外放双讲、GUI 与北京网络延迟仍需本机验收。\n\n"
                + GATEKEEPER_OPENING_GUIDE
                + f"源码：`{args.commit}`。\n\n"
                f"[构建验证记录](https://github.com/{args.repo}/actions/runs/{args.run_id}) · "
                f"[完整安装说明](https://github.com/{args.repo}/blob/{args.commit}/docs/安装使用.md)\n",
                encoding="utf-8",
            )
            github.command("release", "create", args.tag, "--repo", args.repo,
                           "--target", args.commit, "--verify-tag", "--draft", "--latest=false",
                           "--title", f"听译 Mac · {args.tag[4:12]} · {args.commit[:8]}",
                           "--notes-file", str(notes))
        # 已确认身份和源码匹配的草稿可以恢复上传；绝不覆盖已发布附件。
        github.command("release", "upload", args.tag, "--repo", args.repo,
                       "--clobber", *(str(path) for path in staged))
        release = release_for_tag(github, args.tag)
        if release is None or not release.get("draft"):
            raise ReleaseError("上传后草稿状态不正确，停止发布。")
        verify_remote(github, args, release, staged)
        if github.head() != args.commit:
            print("main 已更新，安装包保留在草稿中，由新构建继续发布。")
            return False
        github.command("release", "edit", args.tag, "--repo", args.repo,
                       "--draft=false", "--latest", "--verify-tag")
        release = release_for_tag(github, args.tag)
        if release is None or release.get("draft") or release.get("prerelease"):
            raise ReleaseError("新 Release 尚未确认发布成功，不清理历史版本。")
        verify_remote(github, args, release, staged)
        latest = github.api("releases/latest")
        if latest["id"] != release["id"]:
            raise ReleaseError("最新版入口尚未确认指向新安装包，不清理历史版本。")
        print(f"已发布并校验：{release['html_url']}")
        prune(github, args, release["id"])
        return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dist", default="dist/ci")
    parser.add_argument("--repo", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--tag")
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--build-job", default="build")
    parser.add_argument("--retain", type=int, default=3)
    args = parser.parse_args()
    if (args.repo != REPOSITORY or not re.fullmatch(r"[0-9a-f]{40}", args.commit)
            or (args.tag is not None and not TAG_RE.fullmatch(args.tag))
            or not args.run_id.isdecimal()
            or args.retain != 3):
        parser.error("仅支持指定仓库、完整提交 SHA、固定格式标签和保留 3 个版本。")
    try:
        head = subprocess.run(["git", "rev-parse", "HEAD"], check=True,
                              capture_output=True, text=True, timeout=30).stdout.strip()
        if head != args.commit:
            raise ReleaseError("发布脚本的 HEAD 与已验证安装包提交不一致。")
        publish(args, GitHub(args.repo))
        return 0
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        print("发布未完成：无法核对发布脚本的源码提交。", file=sys.stderr)
        return 1
    except (ReleaseError, KeyError, ValueError, OSError) as exc:
        print(f"发布未完成：{exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
