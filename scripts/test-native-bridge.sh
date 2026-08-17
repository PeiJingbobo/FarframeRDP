#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd -P)

/bin/sh "$script_dir/build-native-dependencies.sh"

artifact_root="$project_root/third-party/artifacts/macos-arm64"
output_dir="$project_root/third-party/build/native-bridge-tests"
test_binary="$output_dir/FarframeRDPBridgeSanitizerTests"
mkdir -p "$output_dir"

sanitizer_clang=${FARFRAME_SANITIZER_CLANG:-}
if [ -z "$sanitizer_clang" ] &&
   [ -x /Library/Developer/CommandLineTools/usr/bin/clang ]; then
    sanitizer_clang=/Library/Developer/CommandLineTools/usr/bin/clang
fi
if [ -z "$sanitizer_clang" ]; then
    sanitizer_clang=$(xcrun --find clang)
fi
if [ ! -x "$sanitizer_clang" ]; then
    echo "error: sanitizer clang is not executable: $sanitizer_clang" >&2
    exit 1
fi
macos_sdk=$(xcrun --sdk macosx --show-sdk-path)

"$sanitizer_clang" \
    -isysroot "$macos_sdk" \
    -std=c11 \
    -arch arm64 \
    -mmacosx-version-min=14.0 \
    -Wall -Wextra -Werror \
    -fsanitize=address,undefined \
    -fno-omit-frame-pointer \
    -I"$project_root/Sources/FarframeRDPBridge" \
    -I"$project_root/Sources/FarframeRDPBridge/include" \
    -I"$artifact_root/freerdp/include/freerdp3" \
    -I"$artifact_root/freerdp/include/winpr3" \
    -I"$artifact_root/openssl/include" \
    -I"$project_root/third-party/sources/freerdp/channels/drive/client" \
    "$project_root/Sources/FarframeRDPBridge/FarframeRDPBridge.c" \
    "$project_root/Sources/FarframeRDPBridge/FarframeRDPConnection.c" \
    "$project_root/Tests/NativeBridgeHarness/main.c" \
    "$artifact_root/lib/libFarframeRDPDependencies.a" \
    -framework Foundation \
    -framework Security \
    -framework SystemConfiguration \
    -framework Carbon \
    -framework Cocoa \
    -framework CoreFoundation \
    -framework CoreServices \
    -framework CoreAudio \
    -framework AudioToolbox \
    -framework AVFoundation \
    -o "$test_binary"

ASAN_OPTIONS=abort_on_error=1 \
UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
    "$test_binary"
