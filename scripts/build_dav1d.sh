#!/bin/bash
# Optional: adds the software AV1 decoder behind the "1440p via Software AV1"
# setting. The app has no dependencies by default and builds without it, the
# setting hidden; run this once to build with it.
#
# Builds Vendor/Dav1d.xcframework from dav1d's source (BSD-2) — a static
# library for iOS devices and one for the arm64 simulator, with a module map
# so Swift can `import Dav1d` — and Config/Dav1d.xcconfig, which points the
# build at it. Both are git-ignored; delete them to build without again.
# Needs meson and ninja (brew install meson).
set -euo pipefail

DAV1D_REV="${DAV1D_REV:-2a0775ca5ea055450bdfbfe81758a3c9e001f58a}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git clone --quiet https://code.videolan.org/videolan/dav1d.git "$WORK/dav1d"
git -C "$WORK/dav1d" checkout --quiet "$DAV1D_REV"

cross_file() {  # sdk, min-version flag, subsystem
    cat > "$WORK/$1.ini" <<INI
[binaries]
c = ['xcrun', '--sdk', '$1', 'clang', '-arch', 'arm64']
ar = ['xcrun', '--sdk', '$1', 'ar']
strip = ['xcrun', '--sdk', '$1', 'strip']

[built-in options]
c_args = ['$2=12.0']
c_link_args = ['$2=12.0']

[host_machine]
system = 'darwin'
subsystem = '$3'
kernel = 'xnu'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
INI
}

build() {  # sdk, min-version flag, subsystem
    cross_file "$@"
    meson setup "$WORK/build-$1" "$WORK/dav1d" --cross-file "$WORK/$1.ini" \
        --buildtype release --default-library static \
        -Denable_tools=false -Denable_tests=false > /dev/null
    ninja -C "$WORK/build-$1" > /dev/null
}

build iphoneos -miphoneos-version-min ios
build iphonesimulator -mios-simulator-version-min ios-simulator

HEADERS="$WORK/headers"
mkdir -p "$HEADERS/dav1d"
cp "$WORK/dav1d/include/dav1d/"*.h "$HEADERS/dav1d/"
cat > "$HEADERS/module.modulemap" <<MAP
module Dav1d {
    umbrella header "dav1d/dav1d.h"
    link "dav1d"
    export *
}
MAP

rm -rf "$ROOT/Vendor/Dav1d.xcframework"
xcodebuild -create-xcframework \
    -library "$WORK/build-iphoneos/src/libdav1d.a" -headers "$HEADERS" \
    -library "$WORK/build-iphonesimulator/src/libdav1d.a" -headers "$HEADERS" \
    -output "$ROOT/Vendor/Dav1d.xcframework" > /dev/null
cp "$WORK/dav1d/COPYING" "$ROOT/Vendor/dav1d-COPYING"

FRAMEWORK='$(SRCROOT)/Vendor/Dav1d.xcframework'
cat > "$ROOT/Config/Dav1d.xcconfig" <<CONFIG
// Written by scripts/build_dav1d.sh: builds with the software AV1 decoder.
SWIFT_INCLUDE_PATHS[sdk=iphoneos*] = \$(inherited) $FRAMEWORK/ios-arm64/Headers
SWIFT_INCLUDE_PATHS[sdk=iphonesimulator*][arch=arm64] = \$(inherited) $FRAMEWORK/ios-arm64-simulator/Headers
LIBRARY_SEARCH_PATHS[sdk=iphoneos*] = \$(inherited) $FRAMEWORK/ios-arm64
LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*][arch=arm64] = \$(inherited) $FRAMEWORK/ios-arm64-simulator
CONFIG

LOCAL="$ROOT/Config/Local.xcconfig"
if [ -f "$LOCAL" ] && ! grep -q 'Dav1d.xcconfig' "$LOCAL"; then
    printf '\n#include? "Dav1d.xcconfig"\n' >> "$LOCAL"
fi
echo "Built with dav1d $DAV1D_REV — the software AV1 setting is now available"
