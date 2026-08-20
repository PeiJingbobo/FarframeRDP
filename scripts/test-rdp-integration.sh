#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
architecture=$(uname -m)
config_path=${FARFRAME_INTEGRATION_CONFIG:-"$project_root/config/local/integration.json"}

/bin/sh "$script_dir/build-native-dependencies.sh"

if [ ! -f "$config_path" ]; then
    echo "error: create an ignored local integration config at config/local/integration.json" >&2
    exit 2
fi
if ! git -C "$project_root" check-ignore -q "$config_path"; then
    echo "error: integration config must be ignored by Git" >&2
    exit 2
fi

read_value() {
    plutil -extract "$1" raw -o - "$config_path"
}

host=$(read_value profiles.0.host)
port=$(read_value profiles.0.port)
username=$(read_value profiles.0.username)
domain=$(read_value profiles.0.domain)
password=$(read_value profiles.0.password)
certificate_decision=$(read_value profiles.0.certificateDecision)
cancel_delay=$(read_value profiles.0.cancelDelayMilliseconds 2>/dev/null || printf '0')

case "$certificate_decision" in
    once|store|reject) ;;
    *)
        echo "error: certificateDecision must explicitly be once, store, or reject" >&2
        exit 2
        ;;
esac

artifact_root="$project_root/third-party/artifacts/macos-$architecture"
output_dir="$project_root/third-party/build/connection-integration"
test_binary="$output_dir/FarframeRDPConnectionIntegration"
mkdir -p "$output_dir"
clang_bin=$(xcrun --find clang)
macos_sdk=$(xcrun --sdk macosx --show-sdk-path)

"$clang_bin" \
    -isysroot "$macos_sdk" \
    -std=c11 \
    -arch "$architecture" \
    -mmacosx-version-min=14.0 \
    -Wall -Wextra -Werror \
    -I"$project_root/Sources/FarframeRDPBridge/include" \
    -I"$artifact_root/freerdp/include/freerdp3" \
    -I"$artifact_root/freerdp/include/winpr3" \
    -I"$artifact_root/openssl/include" \
    "$project_root/Sources/FarframeRDPBridge/FarframeRDPBridge.c" \
    "$project_root/Sources/FarframeRDPBridge/FarframeRDPConnection.c" \
    "$project_root/Tests/ConnectionIntegrationHarness/main.c" \
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
    -lc++ \
    -o "$test_binary"

FARFRAME_TEST_HOST="$host" \
FARFRAME_TEST_PORT="$port" \
FARFRAME_TEST_USERNAME="$username" \
FARFRAME_TEST_DOMAIN="$domain" \
FARFRAME_TEST_PASSWORD="$password" \
FARFRAME_TEST_CERTIFICATE_DECISION="$certificate_decision" \
FARFRAME_TEST_CANCEL_DELAY_MS="$cancel_delay" \
    "$test_binary"
