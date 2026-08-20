#!/bin/sh
set -eu

app_path=${1:-}
if [ -z "$app_path" ] || [ ! -d "$app_path" ]; then
    echo "error: usage: $0 /path/to/FarframeRDP.app" >&2
    exit 1
fi

binary="$app_path/Contents/MacOS/FarframeRDP"
if [ ! -f "$binary" ]; then
    echo "error: app binary not found: $binary" >&2
    exit 1
fi

unexpected_dylibs=$(xcrun otool -L "$binary" | awk '/^[[:space:]]/ { print $1 }' | grep -Ev '^(/System/Library/|/usr/lib/)' || true)
if [ -n "$unexpected_dylibs" ]; then
    echo "error: release app has non-system dynamic library dependencies:" >&2
    printf '%s\n' "$unexpected_dylibs" >&2
    exit 1
fi

build_paths=$(strings "$binary" | grep -E '/(Users|Volumes|home)/.*/third-party/(artifacts|build|sources)(/|$)' || true)
if [ -n "$build_paths" ]; then
    echo "error: release app contains native dependency build-machine paths" >&2
    exit 1
fi

for architecture in arm64 x86_64; do
    if ! nm -arch "$architecture" "$binary" 2>/dev/null | grep -q '_winpr_MD4_Init$'; then
        echo "error: release app is missing internal MD4 for $architecture" >&2
        exit 1
    fi
    if ! nm -arch "$architecture" "$binary" 2>/dev/null | grep -q '_winpr_int_rc4_new$'; then
        echo "error: release app is missing internal RC4 for $architecture" >&2
        exit 1
    fi
done

echo "Farframe release runtime dependencies are self-contained"
