import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import publish_release as publisher


class PublisherTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.root_patch = patch.object(publisher, "ROOT", self.root)
        self.root_patch.start()
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Release Test")
        self.git("config", "user.email", "release@example.test")
        (self.root / ".gitignore").write_text("dist/\n.release-local.json\n")
        (self.root / "source.swift").write_text("// original source\n")
        self.previous = {"version": "1.0.0", "build": 1}
        self.version = {"version": "1.0.1", "build": 2}
        self.write_version(self.previous)
        self.git("add", ".")
        self.git("commit", "-m", "Initial")
        (self.root / "dist").mkdir()
        self.config = {"identity": "Developer ID Application: Test (TEST123)", "notary_profile": "test"}
        self.state = {"source": publisher.head(), "repo": "example/project", "config": self.config,
                      "previous": self.previous, "version": self.version, "arch": "universal",
                      "tag": "v1.0.1+2"}

    def tearDown(self):
        self.root_patch.stop()
        self.temporary.cleanup()

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, check=True,
                              capture_output=True, text=True).stdout.strip()

    def write_version(self, version):
        (self.root / "version.json").write_text(json.dumps(version) + "\n")

    def artifacts(self):
        directory = publisher.destination(self.state)
        directory.mkdir(parents=True)
        names = ["Yabaibye-1.0.1-2-macos-universal.zip", "Yabaibye-1.0.1-2-macos-universal.dmg"]
        for name in names:
            (directory / name).write_bytes(name.encode())
        (directory / "SHA256SUMS").write_text("".join(
            f"{publisher.digest(directory / name)}  {name}\n" for name in names))
        metadata = {**self.version, "configuration": "release", "architectures": ["arm64", "x86_64"],
                    "signing": "certificate", "notarized": True, "artifacts": names}
        (directory / "release.json").write_text(json.dumps(metadata))
        return directory

    def test_dirty_untracked_and_staged_sources_are_rejected(self):
        unknown = self.root / "unknown.txt"
        unknown.write_text("untracked")
        with self.assertRaisesRegex(RuntimeError, "clean"):
            publisher.check_tree()
        unknown.unlink()
        (self.root / "source.swift").write_text("// modified\n")
        for staged in [False, True]:
            if staged:
                self.git("add", "source.swift")
            with self.assertRaisesRegex(RuntimeError, "clean"):
                publisher.check_tree(self.state)

    def test_resume_accepts_only_exact_recorded_version_change(self):
        self.write_version(self.version)
        publisher.check_tree(self.state)
        self.git("add", "version.json")
        publisher.check_tree(self.state)
        self.write_version({"version": "1.0.9", "build": 99})
        with self.assertRaisesRegex(RuntimeError, "Unexpected version"):
            publisher.check_tree(self.state)

    def test_resume_recovers_commit_before_state_save(self):
        self.write_version(self.version)
        with patch.object(publisher, "save_state", side_effect=OSError("disk interruption")):
            with self.assertRaises(OSError):
                publisher.commit_version(self.state.copy())
        commit = publisher.head()
        self.assertNotEqual(commit, self.state["source"])
        publisher.commit_version(self.state)
        self.assertEqual(publisher.head(), commit)
        self.assertEqual(self.state["commit"], commit)
        self.assertEqual(self.git("rev-parse", "refs/tags/v1.0.1+2"), commit)
        self.assertEqual(self.git("rev-list", "--count", "HEAD"), "2")

    def test_resume_rejects_source_commit_disguised_as_release(self):
        self.write_version(self.version)
        (self.root / "source.swift").write_text("// unrelated feature\n")
        self.git("add", ".")
        self.git("commit", "-m", "Release v1.0.1+2")
        with self.assertRaisesRegex(RuntimeError, "Source drift"):
            publisher.check_tree(self.state)

    def test_local_tag_mismatch_is_never_replaced(self):
        self.git("tag", self.state["tag"])
        self.write_version(self.version)
        with self.assertRaisesRegex(RuntimeError, "tag already points elsewhere"):
            publisher.commit_version(self.state)
        self.assertEqual(self.git("rev-parse", "refs/tags/v1.0.1+2"), self.state["source"])

    def test_unsigned_and_unnotarized_metadata_rejected_before_signing_check(self):
        directory = self.artifacts()
        path = directory / "release.json"
        original = json.loads(path.read_text())
        for field, value in [("notarized", False), ("signing", "ad-hoc"), ("build", 3)]:
            path.write_text(json.dumps({**original, field: value}))
            with patch.object(publisher, "verify_signatures") as signatures:
                with self.assertRaisesRegex(RuntimeError, "signed, notarized"):
                    publisher.verify_artifacts(self.state)
                signatures.assert_not_called()

    def test_tampered_payload_and_modified_manifest_rejected(self):
        directory = self.artifacts()
        with patch.object(publisher, "verify_signatures"):
            self.state["hashes"] = publisher.verify_artifacts(self.state)
            archive = directory / "Yabaibye-1.0.1-2-macos-universal.zip"
            original = archive.read_bytes()
            archive.write_bytes(b"changed")
            with self.assertRaisesRegex(RuntimeError, "checksum mismatch"):
                publisher.verify_artifacts(self.state)
            archive.write_bytes(original)
            metadata = directory / "release.json"
            metadata.write_text(metadata.read_text() + "\n")
            with self.assertRaisesRegex(RuntimeError, "Artifacts changed"):
                publisher.verify_artifacts(self.state)

    def test_missing_artifact_rejected(self):
        directory = self.artifacts()
        (directory / "Yabaibye-1.0.1-2-macos-universal.zip").unlink()
        with self.assertRaises(FileNotFoundError):
            publisher.verify_artifacts(self.state)

    def test_public_release_is_verified_without_any_mutation(self):
        release = {"draft": False, "html_url": "https://example.test/release", "assets": []}
        with patch.object(publisher, "release_info", return_value=release), \
                patch.object(publisher, "verify_downloads") as verify, \
                patch.object(publisher, "run") as run:
            self.assertEqual(publisher.publish(self.state), release["html_url"])
            verify.assert_called_once_with(self.state, release)
            run.assert_not_called()

    def test_public_asset_mismatch_stops_without_upload_or_edit(self):
        release = {"draft": False, "html_url": "https://example.test/release", "assets": []}
        with patch.object(publisher, "release_info", return_value=release), \
                patch.object(publisher, "verify_downloads", side_effect=RuntimeError("checksum mismatch")), \
                patch.object(publisher, "run") as run:
            with self.assertRaisesRegex(RuntimeError, "checksum mismatch"):
                publisher.publish(self.state)
            run.assert_not_called()

    def test_draft_becoming_public_prevents_clobber(self):
        self.state["hashes"] = {"archive.zip": "checksum"}
        with patch.object(publisher, "release_info", side_effect=[{"draft": True}, {"draft": False}]), \
                patch.object(publisher, "run") as run:
            with self.assertRaisesRegex(RuntimeError, "no longer a draft"):
                publisher.publish(self.state)
            run.assert_not_called()

    def test_download_verification_checks_content_not_only_names(self):
        self.state["hashes"] = {"asset.zip": hashlib.sha256(b"correct").hexdigest()}
        release = {"assets": [{"name": "asset.zip"}]}
        def download(*args, **kwargs):
            directory = Path(args[args.index("--dir") + 1])
            (directory / "asset.zip").write_bytes(b"wrong")
        with patch.object(publisher, "run", side_effect=download):
            with self.assertRaisesRegex(RuntimeError, "checksum mismatch"):
                publisher.verify_downloads(self.state, release)

    def test_remote_tag_mismatch_stops_before_push(self):
        self.write_version(self.version)
        publisher.commit_version(self.state)
        refs = {"refs/heads/main": self.state["source"], "refs/tags/v1.0.1+2": self.state["source"]}
        with patch.object(publisher, "remote_refs", return_value=refs):
            with self.assertRaisesRegex(RuntimeError, "tag already points elsewhere"):
                publisher.push(self.state)

    def test_resume_with_complete_artifacts_does_not_build_again(self):
        self.artifacts()
        self.write_version(self.version)
        publisher.save_state(self.state)
        args = argparse.Namespace(resume=True, bump="patch", arch="universal")
        with patch.object(publisher, "preflight"), patch.object(publisher, "verify_signatures"), \
                patch.object(publisher, "build") as build, patch.object(publisher, "push"), \
                patch.object(publisher, "publish", return_value="https://example.test/release"):
            publisher.execute(self.config, args)
            build.assert_not_called()
        saved = json.loads((self.root / publisher.STATE).read_text())
        self.assertTrue(saved["complete"])
        self.assertEqual(saved["version"], self.version)

    def test_draft_resume_only_uploads_missing_assets_without_clobber(self):
        directory = self.artifacts()
        with patch.object(publisher, "verify_signatures"):
            self.state["hashes"] = publisher.verify_artifacts(self.state)
        self.state["commit"] = self.state["source"]
        names = list(self.state["hashes"])
        release = {"draft": True, "html_url": "https://example.test/release",
                   "assets": [{"name": names[0]}]}
        uploaded = []
        def command(*args, **kwargs):
            self.assertNotIn("--clobber", args)
            if args[:3] == ("gh", "release", "download"):
                output = Path(args[args.index("--dir") + 1])
                selected = [args[args.index("--pattern") + 1]] if "--pattern" in args else names
                for name in selected:
                    (output / name).write_bytes((directory / name).read_bytes())
            elif args[:3] == ("gh", "release", "upload"):
                name = Path(args[4]).name
                uploaded.append(name)
                release["assets"].append({"name": name})
            elif args[:3] == ("gh", "release", "edit"):
                release["draft"] = False
            else:
                self.fail(f"Unexpected command: {args}")
        refs = {"refs/heads/main": self.state["commit"], "refs/tags/v1.0.1+2": self.state["commit"]}
        with patch.object(publisher, "release_info", side_effect=lambda _: release), \
                patch.object(publisher, "run", side_effect=command), \
                patch.object(publisher, "remote_refs", return_value=refs):
            self.assertEqual(publisher.publish(self.state), release["html_url"])
        self.assertEqual(uploaded, names[1:])
        self.assertFalse(release["draft"])

    def test_remote_main_drift_rejected_before_credentials(self):
        with patch.object(publisher, "repository", return_value=self.state["repo"]), \
                patch.object(publisher, "remote_refs", return_value={"refs/heads/main": "other"}):
            with self.assertRaisesRegex(RuntimeError, "Remote main changed"):
                publisher.preflight(self.config)

    def test_invalid_identity_suffix_is_rejected(self):
        def command(*args, **kwargs):
            if args[:2] == ("gh", "auth"):
                return ""
            if args[:2] == ("gh", "api"):
                return "true"
            if args[0] == "security":
                return f'  1) ABCDEF "{self.config["identity"]}" (CSSMERR_TP_CERT_REVOKED)'
            self.fail(f"Unexpected command: {args}")
        with patch.object(publisher, "check_tree"), \
                patch.object(publisher, "repository", return_value=self.state["repo"]), \
                patch.object(publisher, "remote_refs", return_value={"refs/heads/main": self.state["source"]}), \
                patch.object(publisher, "git", return_value=self.state["source"]), \
                patch.object(publisher, "run", side_effect=command):
            with self.assertRaisesRegex(RuntimeError, "private key are unavailable"):
                publisher.preflight(self.config)

    def test_completed_state_allows_new_release(self):
        self.state["complete"] = True
        publisher.save_state(self.state)
        args = argparse.Namespace(resume=False, bump="patch", arch="universal")
        with patch.object(publisher, "preflight", return_value=self.state["repo"]), \
                patch.object(publisher, "remote_refs", return_value={}), \
                patch.object(publisher, "build", side_effect=RuntimeError("test stops before building")):
            with self.assertRaisesRegex(RuntimeError, "test stops"):
                publisher.execute(self.config, args)
        saved = json.loads((self.root / publisher.STATE).read_text())
        self.assertNotIn("complete", saved)
        self.assertEqual(saved["version"], self.version)

    def test_check_does_not_create_lock_state_or_change_version(self):
        before = (self.root / "version.json").read_bytes()
        with patch.object(sys, "argv", ["publish_release.py", "--check"]), \
                patch.object(publisher, "configuration", return_value=self.config), \
                patch.object(publisher, "preflight") as preflight:
            publisher.main()
            preflight.assert_called_once_with(self.config, None)
        self.assertEqual((self.root / "version.json").read_bytes(), before)
        self.assertEqual(list((self.root / "dist").iterdir()), [])


if __name__ == "__main__":
    unittest.main()
