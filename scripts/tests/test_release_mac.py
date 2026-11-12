"""合成 GitHub 状态；不连接 GitHub、不调用真实模型或上传实际安装包。"""

from argparse import Namespace
from contextlib import redirect_stdout
from copy import deepcopy
import hashlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location(
    "release_mac", Path(__file__).resolve().parents[1] / "release-mac.py"
)
release_mac = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release_mac)

COMMIT = "a" * 40
RUN_ID = "101"
TAG = "mac-20261112-20-aaaaaaaa"


def marker(commit=COMMIT, run_id=RUN_ID, number=20):
    return (f"<!-- hearnote-managed-release:v1 commit={commit} "
            f"run={run_id} number={number} -->")


class FakeGitHub:
    def __init__(self):
        self.repo = release_mac.REPOSITORY
        self.data = []
        self.tags = {}
        self.files = {}
        self.commands = []
        self.deleted = []
        self.head_values = [COMMIT]
        self.fail_action = None
        self.corrupt_download = False
        self.corrupt_after_publish = False
        self.build_status = "success"
        self.build_jobs = None
        self.private = False
        self.run_commit = COMMIT
        self.run_branch = "main"
        self.run_created = "2026-11-12T00:30:00Z"

    def releases(self):
        return deepcopy(self.data)

    def head(self):
        value = self.head_values[0]
        if len(self.head_values) > 1:
            self.head_values.pop(0)
        return value

    def tag_commit(self, tag):
        return self.tags.get(tag)

    def api(self, suffix, *, paginate=False):
        if suffix == "":
            return {"full_name": self.repo, "private": self.private, "default_branch": "main"}
        if suffix == f"actions/runs/{RUN_ID}":
            return {
                "head_sha": self.run_commit, "head_branch": self.run_branch,
                "path": ".github/workflows/mac-build.yml", "event": "push",
                "created_at": self.run_created, "run_number": 20,
            }
        if suffix.startswith(f"actions/runs/{RUN_ID}/jobs?"):
            jobs = self.build_jobs
            if jobs is None:
                jobs = [{"name": "build", "status": "completed",
                         "conclusion": self.build_status, "run_attempt": 1,
                         "id": 100, "head_sha": COMMIT}]
            return [{"jobs": deepcopy(jobs)}]
        if suffix == "releases/latest":
            latest = [item for item in self.data if item.get("latest")]
            if len(latest) != 1:
                raise release_mac.ReleaseError("fake latest missing")
            return deepcopy(latest[0])
        raise AssertionError(f"Unexpected fake API: {suffix}")

    def command(self, *args):
        self.commands.append(args)
        if args[0] == "api":
            fields = {arg.split("=", 1)[0]: arg.split("=", 1)[1]
                      for arg in args if "=" in arg}
            self.tags[fields["ref"].removeprefix("refs/tags/")] = fields["sha"]
            return ""
        self.assert_release(args)
        action, tag = args[1:3]
        if self.fail_action == action:
            raise release_mac.ReleaseError("synthetic network failure")
        found = [item for item in self.data if item["tag_name"] == tag]
        if action == "create":
            if found:
                raise AssertionError("existing release overwritten")
            notes = Path(args[args.index("--notes-file") + 1]).read_text()
            item = {
                "id": max([item["id"] for item in self.data], default=0) + 1,
                "tag_name": tag, "body": notes, "draft": True, "prerelease": False,
                "assets": [], "published_at": None,
                "html_url": f"https://github.com/{self.repo}/releases/tag/{tag}",
            }
            self.data.append(item)
            return ""
        if len(found) != 1:
            raise AssertionError(f"missing release: {tag}")
        item = found[0]
        if action == "upload":
            if not item["draft"]:
                raise AssertionError("published release assets overwritten")
            paths = [Path(arg) for arg in args[args.index("--clobber") + 1:]]
            self.files[tag] = {path.name: path.read_bytes() for path in paths}
            item["assets"] = [{"name": path.name, "size": path.stat().st_size,
                               "state": "uploaded"} for path in paths]
        elif action == "download":
            directory = Path(args[args.index("--dir") + 1])
            for name, content in self.files[tag].items():
                if (self.corrupt_download
                        or (self.corrupt_after_publish and not item["draft"])):
                    content += b"corrupt"
                (directory / name).write_bytes(content)
        elif action == "edit":
            for other in self.data:
                other["latest"] = False
            item.update(draft=False, latest=True, published_at="2026-11-12T23:00:00Z")
        elif action == "delete":
            self.deleted.append(tag)
            self.data.remove(item)
        else:
            raise AssertionError(f"unexpected fake command: {args}")
        return ""

    @staticmethod
    def assert_release(args):
        if args[0] != "release":
            raise AssertionError(f"unexpected fake command: {args}")

    def add_old(self, index, *, managed=True, draft=False):
        commit = f"{index:040x}"
        tag = f"mac-20261112-{index}-{commit[:8]}"
        item = {
            "id": index, "tag_name": tag,
            "body": marker(commit, str(index), index) if managed else "manual release",
            "draft": draft, "prerelease": False,
            "published_at": f"2026-11-12T{index:02d}:00:00Z",
            "assets": [{"name": name, "size": 1, "state": "uploaded"}
                       for name in release_mac.ASSETS],
            "html_url": f"https://github.com/{self.repo}/releases/tag/{tag}",
        }
        self.data.append(item)
        return tag


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.output = io.StringIO()
        self.silence = redirect_stdout(self.output)
        self.silence.__enter__()
        self.addCleanup(self.silence.__exit__, None, None, None)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.dist = Path(self.temp.name)
        sums = []
        for suffix in ("dmg", "app.zip"):
            name = f"HearNote-Mac-arm64-{COMMIT[:8]}.{suffix}"
            content = f"synthetic package {suffix}".encode()
            (self.dist / name).write_bytes(content)
            sums.append(f"{hashlib.sha256(content).hexdigest()}  {name}\n")
        (self.dist / "SHA256SUMS").write_text("".join(sums))
        (self.dist / "build-environment.txt").write_text(f"Source commit: {COMMIT}\n")
        self.args = Namespace(
            dist=str(self.dist), repo=release_mac.REPOSITORY, commit=COMMIT,
            run_id=RUN_ID, tag=None, build_job="build", retain=3,
        )
        self.github = FakeGitHub()

    def test_repository_api_has_no_trailing_slash(self):
        github = release_mac.GitHub(release_mac.REPOSITORY)
        calls = []
        github.command = lambda *args: calls.append(args) or "{}"
        self.assertEqual(github.api(""), {})
        self.assertEqual(calls, [("api", "repos/xiuleiyy/hearnote-mac")])

    def publish(self):
        return release_mac.publish(self.args, self.github)

    def test_success_has_fixed_assets_and_published_latest(self):
        self.assertTrue(self.publish())
        self.assertEqual(self.args.tag, TAG)
        result = self.github.data[0]
        self.assertFalse(result["draft"])
        self.assertTrue(result["latest"])
        self.assertEqual({asset["name"] for asset in result["assets"]},
                         set(release_mac.ASSETS))
        self.assertEqual(self.github.tags[TAG], COMMIT)
        commands = [command[1] for command in self.github.commands
                    if command[0] == "release"]
        self.assertEqual(commands, ["create", "upload", "download", "edit", "download"])

    def test_only_three_managed_published_releases_survive(self):
        old = [self.github.add_old(index) for index in range(1, 5)]
        manual = self.github.add_old(6, managed=False)
        draft = self.github.add_old(7, draft=True)
        self.publish()
        self.assertEqual(self.github.deleted, [old[1], old[0]])
        remaining = {item["tag_name"] for item in self.github.data}
        self.assertTrue({TAG, old[2], old[3], manual, draft}.issubset(remaining))

    def test_incomplete_published_release_does_not_count_as_success(self):
        old = [self.github.add_old(index) for index in range(1, 5)]
        incomplete = self.github.add_old(6)
        self.github.data[-1]["assets"] = []
        self.publish()
        self.assertEqual(self.github.deleted, [old[1], old[0]])
        self.assertIn(incomplete, {item["tag_name"] for item in self.github.data})

    def test_upload_failure_keeps_existing_releases_and_draft(self):
        for index in range(1, 5):
            self.github.add_old(index)
        self.github.fail_action = "upload"
        with self.assertRaises(release_mac.ReleaseError):
            self.publish()
        self.assertEqual(self.github.deleted, [])
        self.assertTrue(next(item for item in self.github.data if item["tag_name"] == TAG)["draft"])

    def test_remote_hash_mismatch_never_publishes_or_prunes(self):
        self.github.corrupt_download = True
        with self.assertRaises(release_mac.ReleaseError):
            self.publish()
        self.assertEqual(self.github.deleted, [])
        self.assertFalse(any(command[:2] == ("release", "edit")
                             for command in self.github.commands))

    def test_publish_failure_never_prunes(self):
        self.github.fail_action = "edit"
        with self.assertRaises(release_mac.ReleaseError):
            self.publish()
        self.assertEqual(self.github.deleted, [])
        self.assertTrue(self.github.data[0]["draft"])

    def test_post_publish_verification_failure_never_prunes(self):
        for index in range(1, 5):
            self.github.add_old(index)
        self.github.corrupt_after_publish = True
        with self.assertRaises(release_mac.ReleaseError):
            self.publish()
        self.assertEqual(self.github.deleted, [])
        self.assertEqual(len(self.github.data), 5)

    def test_outdated_build_skips_without_mutation(self):
        self.github.head_values = ["b" * 40]
        self.assertFalse(self.publish())
        self.assertEqual(self.github.commands, [])

    def test_head_advances_during_upload_preserves_draft(self):
        self.github.head_values = [COMMIT, "b" * 40]
        self.assertFalse(self.publish())
        self.assertTrue(self.github.data[0]["draft"])
        self.assertEqual(self.github.deleted, [])

    def test_repeated_success_verifies_but_does_not_overwrite_assets(self):
        self.publish()
        before = len(self.github.commands)
        self.publish()
        new_commands = self.github.commands[before:]
        self.assertEqual([command[1] for command in new_commands], ["download"])

    def test_partial_draft_can_resume_after_upload_failure(self):
        self.github.fail_action = "upload"
        with self.assertRaises(release_mac.ReleaseError):
            self.publish()
        self.github.fail_action = None
        self.assertTrue(self.publish())
        self.assertEqual(len(self.github.data), 1)
        self.assertFalse(self.github.data[0]["draft"])

    def test_conflicting_tag_is_not_overwritten(self):
        self.github.tags[TAG] = "b" * 40
        with self.assertRaises(release_mac.ReleaseError):
            self.publish()
        self.assertEqual(self.github.commands, [])

    def test_unknown_release_is_not_overwritten(self):
        self.github.data.append({"id": 1, "tag_name": TAG, "body": "manual release",
                                 "draft": True, "prerelease": False})
        with self.assertRaises(release_mac.ReleaseError):
            self.publish()
        self.assertEqual(self.github.commands, [])

    def test_local_checksum_mismatch_prevents_all_mutation(self):
        (self.dist / f"HearNote-Mac-arm64-{COMMIT[:8]}.dmg").write_bytes(b"changed")
        with self.assertRaises(release_mac.ReleaseError):
            self.publish()
        self.assertEqual(self.github.commands, [])

    def test_unsuccessful_build_is_refused(self):
        self.github.build_status = "failure"
        with self.assertRaises(release_mac.ReleaseError):
            self.publish()
        self.assertEqual(self.github.commands, [])

    def test_rerun_release_only_can_use_latest_executed_successful_build(self):
        self.github.build_jobs = [
            {"name": "build", "status": "completed", "conclusion": "success",
             "run_attempt": 1, "id": 100, "head_sha": COMMIT},
            {"name": "release", "status": "in_progress", "conclusion": None,
             "run_attempt": 2, "id": 102, "head_sha": COMMIT},
        ]
        self.assertTrue(self.publish())

    def test_previous_success_cannot_override_later_build_failure(self):
        self.github.build_jobs = [
            {"name": "build", "status": "completed", "conclusion": "success",
             "run_attempt": 1, "id": 100, "head_sha": COMMIT},
            {"name": "build", "status": "completed", "conclusion": "failure",
             "run_attempt": 2, "id": 102, "head_sha": COMMIT},
        ]
        with self.assertRaises(release_mac.ReleaseError):
            self.publish()
        self.assertEqual(self.github.commands, [])

    def test_build_job_source_commit_must_match(self):
        self.github.build_jobs = [
            {"name": "build", "status": "completed", "conclusion": "success",
             "run_attempt": 1, "id": 100, "head_sha": "b" * 40},
        ]
        with self.assertRaises(release_mac.ReleaseError):
            self.publish()
        self.assertEqual(self.github.commands, [])

    def test_unexpected_repo_visibility_is_refused(self):
        self.github.private = True
        with self.assertRaises(release_mac.ReleaseError):
            self.publish()
        self.assertEqual(self.github.commands, [])

    def test_run_source_mismatch_is_refused(self):
        self.github.run_commit = "b" * 40
        with self.assertRaises(release_mac.ReleaseError):
            self.publish()
        self.assertEqual(self.github.commands, [])

    def test_supplied_tag_must_match_original_run(self):
        self.args.tag = "mac-20261113-20-aaaaaaaa"
        with self.assertRaises(release_mac.ReleaseError):
            self.publish()
        self.assertEqual(self.github.commands, [])

    def test_run_date_is_normalized_to_utc(self):
        self.github.run_created = "2026-11-13T00:30:00+09:00"
        self.publish()
        self.assertEqual(self.args.tag, TAG)

    def test_head_advances_after_publish_blocks_pruning(self):
        for index in range(1, 5):
            self.github.add_old(index)
        self.github.head_values = [COMMIT, COMMIT, "b" * 40]
        self.publish()
        self.assertEqual(self.github.deleted, [])
        self.assertEqual(len(self.github.data), 5)


if __name__ == "__main__":
    unittest.main()
