#!/bin/sh
# Build the optional native-core comparison outside the application bundle.
set -eu
cd "$(dirname "$0")/../.."
out="$PWD/build/terminal-comparison"
mkdir -p "$out"

fetch() {
    url=$1 file=$2 sha=$3
    if ! test -f "$file" || ! printf '%s  %s\n' "$sha" "$file" | shasum -a 256 -c - >/dev/null; then
        curl -fL --retry 2 "$url" -o "$file.part"
        printf '%s  %s\n' "$sha" "$file.part" | shasum -a 256 -c -
        mv "$file.part" "$file"
    fi
}
fetch https://release.files.ghostty.org/libghostty-vt/1.0.2/ghostty-vt-1.0.2.xcframework.zip \
    "$out/ghostty-vt.zip" 15477209ce86ad1c944f217e925c84acf796ecc51aba7a935aaa1a7769890bd6
fetch https://static.crates.io/crates/alacritty_terminal/alacritty_terminal-0.26.0.crate \
    "$out/alacritty.crate" bda177466b9524d59f1b12f0dd30b68696788e9992a7e959021c4a0ed96fcf59

unzip -qo "$out/ghostty-vt.zip" -d "$out"
lib="$out/ghostty-vt.xcframework/macos-arm64_x86_64"
xcrun clang++ -std=c++17 -O2 -DBENCH_GHOSTTY -I"$lib/Headers" Tests/compare/replay.cpp \
    "$lib/libghostty-vt.a" -framework Foundation -o "$out/ghostty"
xcrun clang++ -std=c++17 -O2 -ISources Tests/compare/replay.cpp Sources/Screen.cpp \
    Sources/Emoji.cpp Sources/History.cpp Sources/CodeOutput.cpp -lcompression -o "$out/yaaterm"

# Use the crate's published Cargo.lock so transitive dependency versions match.
tar -xzf "$out/alacritty.crate" -C "$out"
crate="$out/alacritty_terminal-0.26.0"
mkdir -p "$crate/examples"
cp Tests/compare/replay.rs "$crate/examples/yaa_replay.rs"
cat >> "$crate/Cargo.toml" <<'TOML'

[[example]]
name = "yaa_replay"
path = "examples/yaa_replay.rs"
TOML
cargo build --release --locked --example yaa_replay --manifest-path "$crate/Cargo.toml" --target-dir "$out/rust-target"
cp "$out/rust-target/release/examples/yaa_replay" "$out/alacritty"
