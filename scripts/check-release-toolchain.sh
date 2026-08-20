#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=release-toolchain.sh
. "$script_dir/release-toolchain.sh"

xcode_output=$(xcodebuild -version)
xcode_version=$(printf '%s\n' "$xcode_output" | sed -n '1s/^Xcode //p')
xcode_build=$(printf '%s\n' "$xcode_output" | sed -n '2s/^Build version //p')
sdk_version=$(xcrun --sdk macosx --show-sdk-version)

if [ "$xcode_version" != "$FARFRAME_RELEASE_XCODE_VERSION" ]; then
    echo "error: release requires Xcode $FARFRAME_RELEASE_XCODE_VERSION, found $xcode_version" >&2
    exit 1
fi
if [ "$xcode_build" != "$FARFRAME_RELEASE_XCODE_BUILD" ]; then
    echo "error: release requires Xcode build $FARFRAME_RELEASE_XCODE_BUILD, found $xcode_build" >&2
    exit 1
fi
if [ "$sdk_version" != "$FARFRAME_RELEASE_MACOS_SDK_VERSION" ]; then
    echo "error: release requires macOS SDK $FARFRAME_RELEASE_MACOS_SDK_VERSION, found $sdk_version" >&2
    exit 1
fi

echo "Release toolchain validated: Xcode $xcode_version ($xcode_build), macOS SDK $sdk_version"
