#!/bin/sh
set -eu
version=2.10.1
digest=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
dest="build/dependencies/sparkle-$version"
mkdir -p build/dependencies
tmp=$(mktemp -d build/dependencies/.sparkle.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
archive=${SPARKLE_ARCHIVE:-"$tmp/Sparkle.tar.xz"}
if [ -z "${SPARKLE_ARCHIVE:-}" ]; then
    curl --fail --location --retry 3 --output "$archive" \
        "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz"
fi
printf '%s  %s\n' "$digest" "$archive" | shasum -a 256 --check --status
mkdir "$tmp/package"
tar -xf "$archive" -C "$tmp/package" ./Sparkle.framework ./bin ./LICENSE
mkdir -p "$dest"
ditto "$tmp/package" "$dest"
touch "$dest/.ready"
