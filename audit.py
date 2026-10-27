#!/usr/bin/env python3
"""Offline, dependency-free checks for accidental release data. Not a DLP guarantee."""
import argparse
import plistlib
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent
ALLOWED = {
    ".gitignore", ".gitattributes", ".github/workflows/ci.yml",
    "Peeklet.swift", "PhotoLibrary.swift", "SelfTests.swift", "build.sh",
    "Info.plist", "Entitlements.plist", "README.md", "LICENSE", "PRIVACY.md",
    "SECURITY.md", "CONTRIBUTING.md", "CHANGELOG.md", "demo.svg", "audit.py",
}
EXPECTED_ENTITLEMENTS = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.files.user-selected.read-only": True,
}


def ensure(condition, message):
    if not condition:
        raise SystemExit("FAIL: " + message)


def public_files():
    if (ROOT / ".git").is_dir():
        result = subprocess.run(
            ["git", "ls-files", "-z"], cwd=ROOT, check=True, capture_output=True
        )
        return [part.decode("utf-8") for part in result.stdout.split(b"\0") if part]
    return sorted(ALLOWED)


def audit_source():
    names = public_files()
    ensure(set(names) == ALLOWED, "release must contain exactly the reviewed source allowlist")
    for name in names:
        path = ROOT / name
        ensure(path.is_file() and not path.is_symlink(), "non-regular public source file")
        content = path.read_text(encoding="utf-8")
        ensure(not re.search(r"/(?:Users|home)/[^\s/]+/", content), "personal absolute path in source")
        ensure(not re.search(r"(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})", content),
               "possible credential in source")
        ensure(("PRIVATE " + "KEY-----") not in content, "private key in source")
    with (ROOT / "Entitlements.plist").open("rb") as source:
        ensure(plistlib.load(source) == EXPECTED_ENTITLEMENTS, "unexpected app entitlements")
    svg = (ROOT / "demo.svg").read_text(encoding="utf-8")
    ensure("<script" not in svg.lower() and "<image" not in svg.lower(), "unsafe or embedded hero image")
    ensure(not re.search(r'(?:href|src)\s*=\s*["\'](?:https?:|data:)', svg, re.I),
           "remote or encoded demo content")
    print("PASS: public source allowlist, basic data scan, sandbox policy, and synthetic SVG")


def audit_bundle(path):
    ensure(path.is_dir() and not path.is_symlink(), "invalid bundle directory")
    expected = {"Contents/Info.plist", "Contents/MacOS/Peeklet", "Contents/_CodeSignature/CodeResources"}
    files = {str(item.relative_to(path)) for item in path.rglob("*") if item.is_file()}
    ensure(files == expected, "bundle includes unexpected resources")
    ensure(not any(item.is_symlink() for item in path.rglob("*")), "symlink in bundle")
    binary = (path / "Contents/MacOS/Peeklet").read_bytes()
    ensure(not re.search(rb"/(?:Users|home)/[^\x00\s/]+/", binary), "personal absolute path in binary")
    result = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(path)],
                            capture_output=True, check=True)
    data = result.stdout
    if b"<?xml" not in data:
        data = result.stderr[result.stderr.find(b"<?xml"):]
    ensure(plistlib.loads(data) == EXPECTED_ENTITLEMENTS, "unexpected signed entitlements")
    print("PASS: bundle contains no images or extra resources; signed entitlements match")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path)
    args = parser.parse_args()
    audit_source()
    if args.bundle:
        audit_bundle(args.bundle)
