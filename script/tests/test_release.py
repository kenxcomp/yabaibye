import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from bundle_app import create_bundle, read_version
from package_release import next_version, publish_local


class ReleaseTests(unittest.TestCase):
    def test_bump_modes_keep_build_monotonic(self):
        for mode, expected in [("patch", "1.2.4"), ("minor", "1.3.0"),
                               ("major", "2.0.0"), ("build", "1.2.3")]:
            with self.subTest(mode=mode):
                self.assertEqual(next_version({"version": "1.2.3", "build": 7}, mode),
                                 {"version": expected, "build": 8})

    def test_invalid_version_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "version.json"
            for value in [{"version": "1.2", "build": 1}, {"version": "1.2.3", "build": True},
                          {"version": "01.2.3", "build": 1}, {"version": "1.2.3", "build": 0}]:
                path.write_text(json.dumps(value))
                with self.assertRaises(ValueError):
                    read_version(path)

    def test_signing_failure_preserves_installed_bundle(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / "binary"
            binary.write_text("new")
            output = root / "Yabaibye.app"
            output.mkdir()
            (output / "marker").write_text("previous")
            with patch("bundle_app.subprocess.run", side_effect=RuntimeError("signing failed")):
                with self.assertRaises(RuntimeError):
                    create_bundle(binary, output, {"version": "1.0.0", "build": 1})
            self.assertEqual((output / "marker").read_text(), "previous")

    def test_publish_advances_version_with_artifacts(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            version = root / "version.json"
            version.write_text('{"version":"1.0.0","build":1}')
            stage = root / "stage"
            stage.mkdir()
            (stage / "artifact").write_text("ready")
            release = root / "release"
            publish_local(version, release, stage, {"version": "1.0.1", "build": 2})
            self.assertEqual(read_version(version)["build"], 2)
            self.assertEqual((release / "artifact").read_text(), "ready")

    def test_version_write_failure_rolls_back_publication(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            version = root / "version.json"
            original = '{"version":"1.0.0","build":1}'
            version.write_text(original)
            stage = root / "stage"
            stage.mkdir()
            release = root / "release"
            with patch("package_release.os.replace", side_effect=OSError("disk failure")):
                with self.assertRaises(OSError):
                    publish_local(version, release, stage, {"version": "1.0.1", "build": 2})
            self.assertEqual(version.read_text(), original)
            self.assertTrue(stage.exists())
            self.assertFalse(release.exists())
            self.assertFalse(version.with_suffix(".json.next").exists())

    def test_existing_release_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            version = root / "version.json"
            version.write_text('{"version":"1.0.0","build":1}')
            stage, release = root / "stage", root / "release"
            stage.mkdir()
            release.mkdir()
            with self.assertRaises(FileExistsError):
                publish_local(version, release, stage, {"version": "1.0.1", "build": 2})
            self.assertEqual(read_version(version)["build"], 1)
            self.assertTrue(stage.exists())
