#!/usr/bin/env python3
"""Publish a notarized release locally; use --resume after an interrupted run."""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
from urllib.parse import quote

import package_release as package
from bundle_app import ROOT, read_version

STATE = "dist/publish-state.json"
CONFIG = ".release-local.json"


def run(*args, timeout=120, **kwargs):
    return subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True,
                          capture_output=True, text=True, timeout=timeout, **kwargs).stdout.rstrip("\n")


def git(*args):
    return run("git", *args)


def save_state(state):
    path = ROOT / STATE
    temporary = path.with_suffix(".next")
    temporary.write_text(json.dumps(state, indent=2) + "\n")
    temporary.chmod(0o600)
    os.replace(temporary, path)


@contextmanager
def lock(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError(f"Another process holds {path.name}") from error
        yield


def configuration():
    path = ROOT / CONFIG
    value = json.loads(path.read_text()) if path.exists() else {}
    if not isinstance(value, dict) or set(value) - {"identity", "notary_profile"}:
        raise ValueError("Local config supports only identity and notary_profile names")
    if path.exists():
        git("check-ignore", "--quiet", "--", CONFIG)
    identity = os.environ.get("YABAIBYE_RELEASE_IDENTITY", value.get("identity", ""))
    profile = os.environ.get("YABAIBYE_NOTARY_PROFILE", value.get("notary_profile", ""))
    if not isinstance(identity, str) or not re.fullmatch(r"Developer ID Application: .+ \([A-Z0-9]+\)", identity):
        raise ValueError("A Developer ID Application identity is required")
    if not isinstance(profile, str) or not profile.strip() or any(c in profile for c in "\r\n\0"):
        raise ValueError("A Keychain notary_profile name is required")
    return {"identity": identity, "notary_profile": profile}


def head():
    return git("rev-parse", "HEAD")


def repository():
    origin = git("remote", "get-url", "origin")
    match = re.fullmatch(r"(?:git@github\.com:|https://github\.com/)([\w.-]+/[\w.-]+?)(?:\.git)?", origin)
    if not match:
        raise RuntimeError("origin must be an SSH or HTTPS github.com repository")
    repo = match.group(1)
    actual = json.loads(run("gh", "repo", "view", "--json", "nameWithOwner"))["nameWithOwner"]
    if actual.lower() != repo.lower():
        raise RuntimeError("gh repository does not match origin")
    return repo


def remote_refs():
    output = git("ls-remote", "origin", "refs/heads/main", "refs/tags/*")
    return {line.split()[1]: line.split()[0] for line in output.splitlines()}


def tag_commit(refs, tag):
    ref = f"refs/tags/{tag}"
    return refs.get(ref + "^{}", refs.get(ref))


def check_tree(state=None):
    if git("branch", "--show-current") != "main":
        raise RuntimeError("Release must run on main")
    status = git("status", "--porcelain=v1", "-z", "--untracked-files=all")
    # The resumed publisher owns only the precise version change recorded before packaging.
    changes = [entry for entry in status.split("\0") if entry]
    if changes:
        if not state or any(entry[3:] != "version.json" for entry in changes):
            raise RuntimeError("Working tree and index must be clean, including untracked files")
        if read_version(ROOT / "version.json") != state["version"]:
            raise RuntimeError("Unexpected version.json change")
    if not state:
        return
    current = head()
    if current == state["source"]:
        return
    if state.get("commit") and current != state["commit"]:
        raise RuntimeError("HEAD changed since the release commit")
    parents = git("rev-list", "--parents", "-n", "1", current).split()
    changed = git("diff-tree", "--no-commit-id", "--name-only", "-r", current).splitlines()
    expected = git("show", f"{current}:version.json")
    if (parents != [current, state["source"]] or changed != ["version.json"]
            or json.loads(expected) != state["version"]
            or git("log", "-1", "--format=%s") != f"Release {state['tag']}"):
        raise RuntimeError("Source drift: HEAD is not this publisher's version-only release commit")
    if changes:
        raise RuntimeError("Release commit must have a clean working tree")


def preflight(config, state=None):
    check_tree(state)
    repo = repository()
    if state and (state["repo"] != repo or state["config"] != config):
        raise RuntimeError("Repository or signing configuration changed; refusing resume")
    refs = remote_refs()
    allowed = {head()} if not state else {state["source"], head()}
    if refs.get("refs/heads/main") not in allowed:
        raise RuntimeError("Remote main changed; synchronize before starting a new release")
    if not state and git("rev-parse", "refs/remotes/origin/main") != head():
        raise RuntimeError("Local main and origin/main must match")
    if state:
        existing = tag_commit(refs, state["tag"])
        if existing and (head() == state["source"] or existing != head()):
            raise RuntimeError("Remote release tag points to another commit")
    run("gh", "auth", "status")
    permission = run("gh", "api", f"repos/{repo}", "--jq", ".permissions.push")
    if permission != "true":
        raise RuntimeError("GitHub push permission is required")
    identities = run("security", "find-identity", "-v", "-p", "codesigning")
    if not re.search(r'^\s*\d+\)\s+[A-Fa-f0-9]+\s+"' + re.escape(config["identity"]) + r'"\s*$',
                     identities, re.MULTILINE):
        raise RuntimeError("Signing identity and private key are unavailable")
    run("xcrun", "notarytool", "history", "--keychain-profile", config["notary_profile"],
        "--output-format", "json", timeout=180)
    return repo


def destination(state):
    version = state["version"]
    return ROOT / "dist/releases" / f"{version['version']}-{version['build']}-{state['arch']}"


def build(state):
    # Reuse the packager's implementation and lock; only this invocation gets time bounds.
    releases = ROOT / "dist/releases"
    with lock(releases / ".package.lock"):
        if read_version(ROOT / "version.json") != state["previous"]:
            raise RuntimeError("Version advanced without complete artifacts; investigate before retrying")
        run(sys.executable, "-m", "unittest", "discover", "-s", "script/tests", timeout=600)
        print(run("swift", "test", timeout=1800), flush=True)
        original = package.run
        def bounded(*args, **kwargs):
            kwargs.setdefault("timeout", 1800)
            return original(*args, **kwargs)
        package.run = bounded
        try:
            with tempfile.TemporaryDirectory(prefix=".package-", dir=releases) as temporary:
                stage = Path(temporary) / "release"
                stage.mkdir()
                package.package_artifacts(stage, state["version"], state["arch"],
                                          state["config"]["identity"], state["config"]["notary_profile"])
                package.publish_local(ROOT / "version.json", destination(state), stage, state["version"])
        finally:
            package.run = original


def digest(path):
    with path.open("rb") as handle:
        checksum = hashlib.sha256()
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            checksum.update(block)
        return checksum.hexdigest()


def verify_signatures(directory, names, state):
    dmg = next(directory / name for name in names if name.endswith(".dmg"))
    archive = next(directory / name for name in names if name.endswith(".zip"))
    run("hdiutil", "verify", dmg)
    run("codesign", "--verify", "--strict", dmg)
    run("xcrun", "stapler", "validate", dmg)
    with tempfile.TemporaryDirectory(prefix="verify-release-") as temporary:
        run("ditto", "-x", "-k", archive, temporary)
        app = Path(temporary) / "Yabaibye.app"
        run("codesign", "--verify", "--deep", "--strict", app)
        details = subprocess.run(["codesign", "-d", "--verbose=4", str(app)],
                                 check=True, capture_output=True, text=True, timeout=60).stderr
        if f"Authority={state['config']['identity']}\n" not in details:
            raise RuntimeError("Archive signing authority differs from configured Developer ID")
        run("xcrun", "stapler", "validate", app)
        run("spctl", "--assess", "--type", "execute", app)
        with (app / "Contents/Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
        if (info.get("CFBundleShortVersionString") != state["version"]["version"]
                or str(info.get("CFBundleVersion")) != str(state["version"]["build"])):
            raise RuntimeError("Archive version metadata does not match release")


def verify_artifacts(state):
    directory = destination(state)
    metadata = json.loads((directory / "release.json").read_text())
    version = state["version"]
    stem = f"Yabaibye-{version['version']}-{version['build']}-macos-{state['arch']}"
    payloads = [f"{stem}.zip", f"{stem}.dmg"]
    archs = ["arm64", "x86_64"] if state["arch"] == "universal" else [state["arch"]]
    if (any(metadata.get(key) != value for key, value in version.items())
            or metadata.get("notarized") is not True or metadata.get("signing") != "certificate"
            or metadata.get("configuration") != "release" or metadata.get("architectures") != archs
            or metadata.get("artifacts") != payloads):
        raise RuntimeError("Artifacts must be the expected signed, notarized Release build")
    sums = (directory / "SHA256SUMS").read_text().splitlines()
    expected = [f"{digest(directory / name)}  {name}" for name in payloads]
    if sums != expected:
        raise RuntimeError("Archive checksum mismatch")
    names = payloads + ["SHA256SUMS", "release.json"]
    hashes = {name: digest(directory / name) for name in names}
    if state.get("hashes") and hashes != state["hashes"]:
        raise RuntimeError("Artifacts changed since this release began")
    verify_signatures(directory, names, state)
    return hashes


def commit_version(state):
    check_tree(state)
    if head() == state["source"]:
        if read_version(ROOT / "version.json") != state["version"]:
            raise RuntimeError("Packaged version does not match working tree")
        git("add", "--", "version.json")
        git("commit", "-m", f"Release {state['tag']}", "--", "version.json")
    check_tree(state)  # Also recognizes a commit completed just before an interruption.
    state["commit"] = head()
    save_state(state)
    try:
        existing = git("rev-parse", "--verify", f"refs/tags/{state['tag']}^{{commit}}")
    except subprocess.CalledProcessError:
        existing = None
    if existing and existing != state["commit"]:
        raise RuntimeError("Local release tag already points elsewhere")
    if not existing:
        git("tag", state["tag"], state["commit"])


def push(state):
    check_tree(state)
    refs = remote_refs()
    existing = tag_commit(refs, state["tag"])
    if refs.get("refs/heads/main") not in {state["source"], state["commit"]}:
        raise RuntimeError("Remote main changed during packaging; refusing push")
    if existing and existing != state["commit"]:
        raise RuntimeError("Remote release tag already points elsewhere")
    git("push", "--atomic", "origin", f"{state['commit']}:refs/heads/main", f"refs/tags/{state['tag']}")
    refs = remote_refs()
    if refs.get("refs/heads/main") != state["commit"] or tag_commit(refs, state["tag"]) != state["commit"]:
        raise RuntimeError("Remote main/tag verification failed")


def release_info(state):
    endpoint = f"repos/{state['repo']}/releases/tags/{quote(state['tag'], safe='')}"
    try:
        return json.loads(run("gh", "api", endpoint))
    except subprocess.CalledProcessError as error:
        if "HTTP 404" in (error.stderr or ""):
            return None
        raise


def verify_downloads(state, release):
    names = {asset["name"] for asset in release["assets"]}
    if names != set(state["hashes"]) or len(release["assets"]) != len(names):
        raise RuntimeError("GitHub release does not contain exactly the four expected assets")
    with tempfile.TemporaryDirectory(prefix="verify-download-") as temporary:
        run("gh", "release", "download", state["tag"], "--repo", state["repo"], "--dir", temporary, timeout=600)
        for name, checksum in state["hashes"].items():
            if digest(Path(temporary) / name) != checksum:
                raise RuntimeError(f"GitHub asset checksum mismatch: {name}")


def publish(state):
    release = release_info(state)
    if release and not release["draft"]:
        verify_downloads(state, release)  # Never edit or overwrite an existing public release.
        return release["html_url"]
    if release is None:
        notes = ROOT / "dist/publish-notes.md"
        notes.write_text(
            f"Yabaibye {state['version']['version']} ({state['version']['build']})\n\n"
            "**Developer ID signed and Apple notarized / 已签名并通过 Apple 公证**\n\n"
            "The app and DMG passed notarization; tickets are stapled. Universal releases support "
            "Apple Silicon and Intel. macOS 14 is the minimum build target, not full compatibility certification.\n\n"
            "Install Yabaibye.app in Applications, grant Accessibility access and enable management. "
            "The main window provides the start-at-login switch. Verify downloads with SHA256SUMS.\n")
        run("gh", "release", "create", state["tag"], "--repo", state["repo"], "--draft", "--verify-tag",
            "--title", f"Yabaibye {state['version']['version']} ({state['version']['build']}) — Notarized",
            "--notes-file", notes)
    for name in state["hashes"]:
        release = release_info(state)
        if not release or not release["draft"]:
            raise RuntimeError("Release is no longer a draft; resume to verify without overwriting")
        if any(asset["name"] == name for asset in release["assets"]):
            with tempfile.TemporaryDirectory(prefix="verify-existing-") as temporary:
                run("gh", "release", "download", state["tag"], "--repo", state["repo"],
                    "--pattern", name, "--dir", temporary, timeout=600)
                if digest(Path(temporary) / name) != state["hashes"][name]:
                    raise RuntimeError(f"Existing draft asset differs; inspect manually: {name}")
        else:
            # Without --clobber, a concurrent publish/upload cannot overwrite public assets.
            run("gh", "release", "upload", state["tag"], destination(state) / name,
                "--repo", state["repo"], timeout=600)
    release = release_info(state)
    verify_downloads(state, release)
    refs = remote_refs()
    if (tag_commit(refs, state["tag"]) != state["commit"]
            or refs.get("refs/heads/main") != state["commit"]):
        raise RuntimeError("Remote main or tag changed before publication")
    if release["draft"]:
        run("gh", "release", "edit", state["tag"], "--repo", state["repo"], "--draft=false", "--latest")
    release = release_info(state)
    if not release or release["draft"]:
        raise RuntimeError("Release is not public")
    verify_downloads(state, release)
    return release["html_url"]


def execute(config, args):
    path = ROOT / STATE
    if args.resume:
        if not path.exists():
            raise RuntimeError("No saved release to resume")
        state = json.loads(path.read_text())
        preflight(config, state)
    else:
        if path.exists() and not json.loads(path.read_text()).get("complete"):
            raise RuntimeError("An unfinished release exists; use --resume")
        repo = preflight(config)
        previous = read_version(ROOT / "version.json")
        version = package.next_version(previous, args.bump)
        state = {"source": head(), "repo": repo, "config": config, "previous": previous,
                 "version": version, "arch": args.arch, "tag": f"v{version['version']}+{version['build']}"}
        if destination(state).exists() or tag_commit(remote_refs(), state["tag"]):
            raise RuntimeError("Target version already exists; investigate before starting")
        save_state(state)  # Written before building so failure never silently chooses another version.
    if not destination(state).exists():
        if state.get("hashes") or head() != state["source"]:
            raise RuntimeError("Saved release artifacts are missing")
        print(f"Packaging {state['tag']}…", flush=True)
        build(state)
    state["hashes"] = verify_artifacts(state)
    # Recover a crash between publishing the artifact directory and advancing version.json.
    if head() == state["source"] and read_version(ROOT / "version.json") == state["previous"]:
        temporary = ROOT / "version.json.next"
        temporary.write_text(json.dumps(state["version"], indent=2) + "\n")
        os.replace(temporary, ROOT / "version.json")
    save_state(state)
    commit_version(state)
    push(state)
    url = publish(state)
    state["complete"] = True
    save_state(state)
    print(f"Published and verified: {url}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Read-only credential and repository preflight")
    parser.add_argument("--resume", action="store_true", help="Continue the saved version without another bump")
    parser.add_argument("--bump", choices=["patch", "minor", "major", "build"], default="patch")
    parser.add_argument("--arch", choices=["universal", "arm64", "x86_64"], default="universal")
    args = parser.parse_args()
    config = configuration()
    if args.check:
        path = ROOT / STATE
        state = json.loads(path.read_text()) if args.resume and path.exists() else None
        if args.resume and state is None:
            raise RuntimeError("No saved release to resume")
        preflight(config, state)
        print("Preflight passed; no version, build, commit or publication changed.")
        return
    with lock(ROOT / "dist/.publish.lock"):
        execute(config, args)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or error.stdout or "").strip()
        raise SystemExit(f"Release stopped: {error}\n{detail[-4000:]}\n"
                         "After resolving the cause, use --resume for an unfinished release.")
    except (RuntimeError, ValueError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(f"Release stopped: {error}\nAfter resolving the cause, use --resume for an unfinished release.")
