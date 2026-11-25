"""Validate release metadata; print workflow outputs for the checked-out commit."""
import os
import plistlib
import re
import subprocess
from pathlib import Path

info = plistlib.loads(Path("Info.plist").read_bytes())
version = info["CFBundleShortVersionString"]
build = info["CFBundleVersion"]
if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", version) or not re.fullmatch(r"[1-9][0-9]*", build):
    raise SystemExit("Expected a numeric release version and a positive build number")
if not Path(f"Resources/ReleaseNotes/{version}.txt").read_text().strip():
    raise SystemExit("This version needs release notes")

ref = os.environ.get("GITHUB_REF", "")
publish = os.environ.get("GITHUB_EVENT_NAME") == "push" and ref.startswith("refs/tags/v")
if publish and ref != f"refs/tags/v{version}":
    raise SystemExit("Release tag must match CFBundleShortVersionString")
before = os.environ.get("BEFORE")
if before and before != "0" * 40 and ref.startswith("refs/heads/"):
    previous = plistlib.loads(subprocess.check_output(["git", "show", f"{before}:Info.plist"]))
    old_version = previous["CFBundleShortVersionString"]
    old_build = int(previous["CFBundleVersion"])
    if int(build) < old_build:
        raise SystemExit("Build number must not decrease")
    if old_version != version:
        def parts(value):
            return tuple(map(int, (value.split(".") + ["0", "0"])[:3]))
        if parts(version) <= parts(old_version) or int(build) <= old_build:
            raise SystemExit("A new release must increase both version and build number")

print(f"version={version}")
print(f"publish={str(publish).lower()}")
