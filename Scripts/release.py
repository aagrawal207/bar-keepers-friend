#!/usr/bin/env python3
"""Build and verify Developer ID releases using the operator's asc Keychain profile."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
import urllib.request


ROOT = Path(__file__).resolve().parent.parent
APP_NAME = "BarKeepersFriend.app"
SCHEME = "BarKeepersFriend"


def run(*args, capture=False):
    command = [str(arg) for arg in args]
    print("+ " + shlex.join(command), flush=True)
    result = subprocess.run(command, cwd=ROOT, text=True, capture_output=capture)
    if result.returncode:
        if capture:
            print(result.stdout, end="", file=sys.stderr)
            print(result.stderr, end="", file=sys.stderr)
        raise RuntimeError(f"Command failed ({result.returncode}): {command[0]}")
    return result


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def signing_identity(fingerprint):
    if not fingerprint or not re.fullmatch(r"[0-9a-fA-F]{40}", fingerprint):
        raise RuntimeError("Set BKF_RELEASE_SIGNING_IDENTITY to a Developer ID Application certificate SHA-1.")
    fingerprint = fingerprint.upper()
    identities = run("security", "find-identity", "-v", "-p", "codesigning", capture=True).stdout
    if not re.search(rf'{fingerprint}\s+"Developer ID Application:', identities):
        raise RuntimeError("The requested Developer ID Application identity is not available in Keychain.")
    return fingerprint


def verify_app(app, expected=None):
    run("codesign", "--verify", "--deep", "--strict", "--all-architectures", app)
    details = run("codesign", "--display", "--verbose=4", app, capture=True).stderr
    if not re.search(r"^Authority=Developer ID Application:", details, re.MULTILINE):
        raise RuntimeError("The app is not signed with Developer ID Application.")
    if "(runtime)" not in details or not re.search(r"^Timestamp=.+", details, re.MULTILINE):
        raise RuntimeError("The app must have Hardened Runtime and a secure signing timestamp.")
    team = re.search(r"^TeamIdentifier=(\w+)$", details, re.MULTILINE)
    if not team:
        raise RuntimeError("The signed app has no TeamIdentifier.")
    entitlements = run("codesign", "--display", "--entitlements", "-", "--xml", app, capture=True).stdout
    if plistlib.loads(entitlements.encode()).get("com.apple.security.get-task-allow", False):
        raise RuntimeError("A release must not allow debugger attachment.")
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if (info["CFBundleIdentifier"] != "com.agraabhi.BarKeepersFriend" or info["LSMinimumSystemVersion"] != "26.0"
            or info.get("LSApplicationCategoryType") != "public.app-category.utilities"):
        raise RuntimeError("Unexpected bundle identity, category, or minimum macOS version.")
    version = info["CFBundleShortVersionString"]
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise RuntimeError("The release version must have three numeric components.")
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    architectures = sorted(run("lipo", "-archs", executable, capture=True).stdout.split())
    if architectures != ["arm64", "x86_64"]:
        raise RuntimeError(f"Expected a universal app; found {architectures}.")
    metadata = {"version": version, "build": info["CFBundleVersion"], "team": team.group(1), "architectures": architectures}
    if expected and any(expected[key] != value for key, value in metadata.items()):
        raise RuntimeError("The app no longer matches its build manifest.")
    return metadata


def build(output, identity):
    identity = signing_identity(identity)
    if output.exists():
        raise RuntimeError(f"Build output already exists: {output}. Use a fresh directory.")
    revision = run("git", "rev-parse", "HEAD", capture=True).stdout.strip()
    dirty = bool(run("git", "status", "--porcelain", capture=True).stdout.strip())
    output.mkdir(parents=True)
    run("xcodegen", "generate")
    archive = output / "BarKeepersFriend.xcarchive"
    run("xcodebuild", "-project", ROOT / "BarKeepersFriend.xcodeproj", "-scheme", SCHEME,
        "-configuration", "Release", "-destination", "generic/platform=macOS",
        "-derivedDataPath", output / "DerivedData", "-archivePath", archive,
        "CODE_SIGN_STYLE=Manual", f"CODE_SIGN_IDENTITY={identity}", "ENABLE_HARDENED_RUNTIME=YES",
        "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO", "ENABLE_DEBUG_DYLIB=NO", "OTHER_CODE_SIGN_FLAGS=--timestamp",
        "ONLY_ACTIVE_ARCH=NO", "ARCHS=arm64 x86_64", "COMPILER_INDEX_STORE_ENABLE=NO", "-quiet", "archive")
    metadata = verify_app(archive / "Products/Applications" / APP_NAME)
    options = output / "ExportOptions.plist"
    with options.open("wb") as stream:
        plistlib.dump({"method": "developer-id", "destination": "export", "signingStyle": "manual",
                      "signingCertificate": identity, "teamID": metadata["team"],
                      "manageAppVersionAndBuildNumber": False}, stream)
    run("xcodebuild", "-exportArchive", "-archivePath", archive,
        "-exportOptionsPlist", options, "-exportPath", output / "export", "-quiet")
    app = output / "export" / APP_NAME
    verify_app(app, metadata)
    run("ditto", "-c", "-k", "--keepParent", app, output / "notarization-app.zip")
    dirty = dirty or bool(run("git", "status", "--porcelain", capture=True).stdout.strip())
    dirty = dirty or revision != run("git", "rev-parse", "HEAD", capture=True).stdout.strip()
    metadata.update({"revision": revision, "dirty": dirty, "signingIdentity": identity,
                     "dmg": f"BarKeepersFriend-{metadata['version']}-universal.dmg"})
    write_json(output / "build-info.json", metadata)
    print(f"Built {metadata['version']} ({metadata['build']}); notarization is a separate step.")


def asc(profile, *args):
    prefix = ("asc", "--profile", profile) if profile else ("asc",)
    return json.loads(run(*prefix, *args, "--output", "json", capture=True).stdout)


def notary_data(payload):
    root = payload.get("data", payload)
    return root, root.get("attributes", root)


def notary_log(profile, submission, receipt):
    location = asc(profile, "notarization", "log", "--id", submission)
    _, attributes = notary_data(location)
    url = attributes.get("developerLogUrl")
    if not isinstance(url, str) or not url.startswith("https://"):
        raise RuntimeError("Apple did not return an HTTPS developer log URL.")
    with urllib.request.urlopen(url, timeout=60) as response:
        report = json.load(response)
    write_json(receipt.with_suffix(".log.json"), report)
    issues = report.get("issues") or []
    for issue in issues:
        print(f"Notary {issue.get('severity')}: {issue.get('path')}: {issue.get('message')}")
    if any(issue.get("severity") == "error" for issue in issues):
        raise RuntimeError("The developer log contains notarization errors.")


def notarize(path, receipt, profile):
    digest = sha256(path)
    if receipt.exists():
        record = json.loads(receipt.read_text(encoding="utf-8"))
        if record["sha256"] != digest:
            raise RuntimeError("The submitted artifact changed; do not reuse its notarization receipt.")
        submission = record["id"]
    else:
        response = asc(profile, "notarization", "submit", "--file", path)
        root, _ = notary_data(response)
        submission = root.get("id") or root.get("submissionId")
        uuid.UUID(submission)
        write_json(receipt, {"id": submission, "sha256": digest})
    print(f"Notarization submission: {submission}", flush=True)
    deadline = time.monotonic() + 600
    while True:
        status = asc(profile, "notarization", "status", "--id", submission)
        _, attributes = notary_data(status)
        state = attributes.get("status")
        print(f"Notarization: {state}", flush=True)
        if state in ("Accepted", "Invalid", "Rejected"):
            write_json(receipt.with_suffix(".status.json"), status)
            notary_log(profile, submission, receipt)
            if state != "Accepted":
                raise RuntimeError("Apple rejected notarization; inspect the developer log.")
            return
        if state != "In Progress":
            raise RuntimeError(f"Unexpected notarization status: {state}")
        if time.monotonic() >= deadline:
            raise RuntimeError("Apple is still processing. Rerun this step to resume the existing submission.")
        time.sleep(15)


def package(output, metadata):
    app = output / "export" / APP_NAME
    verify_app(app, metadata)
    run("xcrun", "stapler", "validate", app)
    stage = output / "dmg-root"
    dmg = output / metadata["dmg"]
    if stage.exists() or dmg.exists():
        raise RuntimeError("DMG staging/output already exists; refusing to replace an artifact.")
    stage.mkdir()
    run("ditto", app, stage / APP_NAME)
    (stage / "Applications").symlink_to("/Applications")
    shutil.copyfile(ROOT / "LICENSE", stage / "LICENSE.txt")
    shutil.copyfile(ROOT / "Distribution/INSTALL.txt", stage / "Install.txt")
    run("hdiutil", "create", "-volname", "Bar Keeper's Friend", "-srcfolder", stage,
        "-fs", "HFS+", "-format", "UDZO", dmg)
    run("codesign", "--sign", metadata["signingIdentity"], "--timestamp", dmg)
    run("hdiutil", "verify", dmg)


def verify(output, metadata):
    if metadata["dirty"]:
        raise RuntimeError("Public release verification requires a build from a clean git checkout.")
    dmg = output / metadata["dmg"]
    run("codesign", "--verify", "--strict", dmg)
    run("hdiutil", "verify", dmg)
    run("xcrun", "stapler", "validate", dmg)
    run("spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=2", dmg)
    with tempfile.TemporaryDirectory(prefix="bkf-release-mount-") as mount:
        run("hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mount, dmg)
        try:
            app = Path(mount) / APP_NAME
            verify_app(app, metadata)
            run("xcrun", "stapler", "validate", app)
            run("spctl", "--assess", "--type", "execute", "--verbose=2", app)
            if not (Path(mount) / "Applications").is_symlink():
                raise RuntimeError("The DMG has no Applications shortcut.")
        finally:
            run("hdiutil", "detach", mount)
    (output / "SHA256SUMS").write_text(f"{sha256(dmg)}  {dmg.name}\n", encoding="utf-8")
    write_json(output / "verified.json", {**metadata, "sha256": sha256(dmg)})
    print(f"Verified release: {dmg}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("step", choices=["build", "notarize-app", "package", "notarize-dmg", "verify"])
    parser.add_argument("--output", type=Path, default=ROOT / "artifacts/release")
    parser.add_argument("--identity", default=os.environ.get("BKF_RELEASE_SIGNING_IDENTITY"))
    parser.add_argument("--profile", default=os.environ.get("BKF_ASC_PROFILE"))
    args = parser.parse_args()
    output = args.output.expanduser().resolve()
    if args.step == "build":
        build(output, args.identity)
        return
    metadata = json.loads((output / "build-info.json").read_text(encoding="utf-8"))
    app = output / "export" / APP_NAME
    dmg = output / metadata["dmg"]
    if args.step == "notarize-app":
        verify_app(app, metadata)
        notarize(output / "notarization-app.zip", output / "notary-app.json", args.profile)
        run("xcrun", "stapler", "staple", app)
        run("xcrun", "stapler", "validate", app)
    elif args.step == "package":
        package(output, metadata)
    elif args.step == "notarize-dmg":
        if (output / "notary-dmg.json").exists() and subprocess.run(
            ["xcrun", "stapler", "validate", str(dmg)], capture_output=True
        ).returncode == 0:
            print("DMG ticket is already stapled; continue with verify.")
            return
        notarize(dmg, output / "notary-dmg.json", args.profile)
        run("xcrun", "stapler", "staple", dmg)
        run("xcrun", "stapler", "validate", dmg)
    else:
        verify(output, metadata)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError, TypeError) as error:
        sys.exit(f"Release failed: {error}")
