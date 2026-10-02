#!/usr/bin/env python3
"""Build distributable Release artifacts; advance version only after successful packaging."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from bundle_app import ROOT, create_bundle, read_version


def next_version(current, bump):
    if current["build"] >= 999999998:
        raise ValueError("Build number exhausted")
    major, minor, patch = map(int, current["version"].split("."))
    if bump == "major":
        major, minor, patch = major + 1, 0, 0
    elif bump == "minor":
        minor, patch = minor + 1, 0
    elif bump == "patch":
        patch += 1
    return {"version": f"{major}.{minor}.{patch}", "build": current["build"] + 1}


def run(*args, **kwargs):
    return subprocess.run([str(item) for item in args], check=True, cwd=ROOT, **kwargs)


def package_artifacts(stage, version, arch, identity, profile):
    architectures = ["arm64", "x86_64"] if arch == "universal" else [arch]
    flags = ["-c", "release", "--product", "Yabaibye"]
    for target in architectures:
        flags += ["--arch", target]
    run("swift", "build", *flags)
    bin_path = run("swift", "build", *flags, "--show-bin-path", capture_output=True, text=True).stdout.strip()
    binary = Path(bin_path) / "Yabaibye"
    for target in architectures:
        run("xcrun", "lipo", binary, "-verify_arch", target)
    app = stage / "Yabaibye.app"
    create_bundle(binary, app, version, identity, release=True)
    notarized = False
    if profile:
        archive = stage / "notarization.zip"
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive)
        result = run("xcrun", "notarytool", "submit", archive, "--keychain-profile", profile,
                     "--wait", "--output-format", "json", capture_output=True, text=True)
        response = json.loads(result.stdout)
        if response.get("status") != "Accepted":
            raise RuntimeError(f"Notarization was not accepted: {response.get('status')}; id={response.get('id')}")
        run("xcrun", "stapler", "staple", app)
        run("xcrun", "stapler", "validate", app)
        run("spctl", "--assess", "--type", "execute", app)
        archive.unlink()
        notarized = True
    stem = f"Yabaibye-{version['version']}-{version['build']}-macos-{arch}"
    zip_path = stage / f"{stem}.zip"
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, zip_path)
    image_source = stage / "image-source"
    image_source.mkdir()
    run("ditto", app, image_source / "Yabaibye.app")
    (image_source / "Applications").symlink_to("/Applications")
    trust = "Apple notarized" if notarized else "NOT NOTARIZED / 未经 Apple 公证"
    (image_source / "READ ME.txt").write_text(
        f"Yabaibye {version['version']} ({version['build']}) — {trust}\n\n"
        "Drag Yabaibye.app to Applications, then launch it.\n"
        "将 Yabaibye.app 拖入 Applications 后打开。授予辅助功能权限，然后启用窗口管理。\n"
        "主窗口可以启用“登录时启动”。它在用户登录后启动，不是登录前的系统服务。\n"
        "Unnotarized downloads may be blocked by macOS or your organization's policy.\n"
        "未公证下载包可能被系统安全策略拦截；不要禁用 Gatekeeper 或 SIP。\n")
    dmg = stage / f"{stem}.dmg"
    run("hdiutil", "create", "-volname", f"Yabaibye {version['version']}", "-srcfolder", image_source,
        "-format", "UDZO", "-ov", dmg)
    run("hdiutil", "verify", dmg)
    if profile:
        run("codesign", "--sign", identity, "--timestamp", dmg)
        result = run("xcrun", "notarytool", "submit", dmg, "--keychain-profile", profile,
                     "--wait", "--output-format", "json", capture_output=True, text=True)
        response = json.loads(result.stdout)
        if response.get("status") != "Accepted":
            raise RuntimeError(f"DMG notarization was not accepted: {response.get('status')}")
        run("xcrun", "stapler", "staple", dmg)
        run("xcrun", "stapler", "validate", dmg)
    shutil.rmtree(image_source)
    (stage / "SHA256SUMS").write_text("".join(
        f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n" for path in [zip_path, dmg]))
    (stage / "release.json").write_text(json.dumps({
        **version, "configuration": "release", "architectures": architectures,
        "signing": "ad-hoc" if identity == "-" else "certificate", "notarized": notarized,
        "minimumMacOS": "14.0", "artifacts": [zip_path.name, dmg.name],
    }, indent=2) + "\n")


def publish_local(version_path, destination, stage, version):
    """Advance the tracked version only if complete artifacts can be published locally."""
    if destination.exists():
        raise FileExistsError(f"Release already exists: {destination}")
    temporary = version_path.with_suffix(".json.next")
    try:
        temporary.write_text(json.dumps(version, indent=2) + "\n")
        stage.rename(destination)
        try:
            os.replace(temporary, version_path)
        except BaseException:
            destination.rename(stage)
            raise
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bump", choices=["patch", "minor", "major", "build"], default="patch")
    parser.add_argument("--arch", choices=["universal", "arm64", "x86_64"], default="universal")
    parser.add_argument("--identity", default=os.environ.get("YABAIBYE_RELEASE_IDENTITY", "-"))
    parser.add_argument("--notary-profile", default=os.environ.get("YABAIBYE_NOTARY_PROFILE"))
    args = parser.parse_args()
    if args.notary_profile and not args.identity.startswith("Developer ID Application:"):
        parser.error("Notarization requires an explicit Developer ID Application identity")
    if args.identity != "-" and not args.identity.startswith("Developer ID Application:"):
        parser.error("Public releases support ad-hoc or Developer ID Application signing only")
    releases = ROOT / "dist/releases"
    releases.mkdir(parents=True, exist_ok=True)
    # An OS lock is released even if the process fails; do not unlink the lock inode.
    with (releases / ".package.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit("Another release package is in progress")
        version_path = ROOT / "version.json"
        version = next_version(read_version(version_path), args.bump)
        destination = releases / f"{version['version']}-{version['build']}-{args.arch}"
        if destination.exists():
            raise SystemExit(f"Refusing to overwrite {destination}")
        run("python3", "-m", "unittest", "discover", "-s", "script/tests")
        run("swift", "test")
        with tempfile.TemporaryDirectory(prefix=".package-", dir=releases) as temporary:
            stage = Path(temporary) / "release"
            stage.mkdir()
            package_artifacts(stage, version, args.arch, args.identity, args.notary_profile)
            publish_local(version_path, destination, stage, version)
        print(f"Release ready: {destination}")
        print(f"Version advanced to {version['version']} ({version['build']})")
        print("Notarized" if args.notary_profile else "NOT NOTARIZED: clearly label this when publishing")


if __name__ == "__main__":
    main()
