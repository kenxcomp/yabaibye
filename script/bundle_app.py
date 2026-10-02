#!/usr/bin/env python3
"""Shared bundle metadata and signing for development and release builds."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def read_version(path):
    data = json.loads(Path(path).read_text())
    if not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", data.get("version", "")):
        raise ValueError("version must be major.minor.patch")
    if type(data.get("build")) is not int or not 1 <= data["build"] < 999999999:
        raise ValueError("build must be a positive integer below 999999999")
    return {"version": data["version"], "build": data["build"]}


def create_bundle(binary, output, version, identity="-", release=False):
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".bundle-", dir=output.parent) as temporary:
        staged = Path(temporary) / "Yabaibye.app"
        executable = staged / "Contents/MacOS/Yabaibye"
        executable.parent.mkdir(parents=True)
        shutil.copy2(binary, executable)
        executable.chmod(0o755)
        metadata = {
            "CFBundleExecutable": "Yabaibye", "CFBundleIdentifier": "com.kenxcomp.yabaibye",
            "CFBundleName": "Yabaibye", "CFBundleDisplayName": "Yabaibye",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version["version"],
            "CFBundleVersion": str(version["build"]), "LSMinimumSystemVersion": "14.0",
            "LSUIElement": True, "NSPrincipalClass": "NSApplication",
            "NSHighResolutionCapable": True, "YBReleaseBuild": release,
        }
        (staged / "Contents/Info.plist").write_bytes(plistlib.dumps(metadata))
        command = ["codesign", "--force", "--options", "runtime", "--sign", identity]
        if identity != "-":
            command.append("--timestamp")
        subprocess.run(command + [str(staged)], check=True)
        subprocess.run([str(ROOT / "script/verify_security.sh"), str(staged)], check=True)
        # Keep a working bundle if staging/signing fails; replace only after verification.
        old = Path(temporary) / "previous.app"
        if output.exists():
            output.rename(old)
        try:
            staged.rename(output)
        except BaseException:
            if old.exists():
                old.rename(output)
            raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--identity", default="-")
    args = parser.parse_args()
    create_bundle(args.binary, args.output, read_version(ROOT / "version.json"), args.identity)
