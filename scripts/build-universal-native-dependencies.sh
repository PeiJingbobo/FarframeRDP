#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
# shellcheck source=../third-party/versions.sh
. "$project_root/third-party/versions.sh"
artifact_root="$project_root/third-party/artifacts"
universal_root="$artifact_root/macos-universal"
arm64_root="$artifact_root/macos-arm64"
x86_64_root="$artifact_root/macos-x86_64"
universal_lib="$universal_root/lib/libFarframeRDPDependencies.a"

FARFRAME_ARCH=arm64 /bin/sh "$script_dir/build-native-dependencies.sh"
FARFRAME_ARCH=x86_64 /bin/sh "$script_dir/build-native-dependencies.sh"

rm -rf "$universal_root"
mkdir -p "$universal_root/lib" "$universal_root/freerdp"

header_diff=$(diff -qr \
    "$arm64_root/freerdp/include" \
    "$x86_64_root/freerdp/include" || true)
unexpected_header_diff=$(printf '%s\n' "$header_diff" | \
    grep -Ev '/(freerdp|winpr)/build-config\.h differ$' || true)
if [ -n "$unexpected_header_diff" ]; then
    echo "error: installed FreeRDP headers differ between architectures" >&2
    printf '%s\n' "$unexpected_header_diff" >&2
    exit 1
fi

ditto "$arm64_root/freerdp/include" "$universal_root/freerdp/include"
for generated_header in \
    "$universal_root/freerdp/include/freerdp3/freerdp/build-config.h" \
    "$universal_root/freerdp/include/winpr3/winpr/build-config.h"
do
    sed -i '' \
        "s|$arm64_root/freerdp|$universal_root/freerdp|g" \
        "$generated_header"
done

xcrun lipo -create \
    "$arm64_root/lib/libFarframeRDPDependencies.a" \
    "$x86_64_root/lib/libFarframeRDPDependencies.a" \
    -output "$universal_lib"

architectures=$(xcrun lipo -archs "$universal_lib")
case "$architectures" in
    "arm64 x86_64"|"x86_64 arm64") ;;
    *)
        echo "error: Universal dependency archive has unexpected architectures: $architectures" >&2
        exit 1
        ;;
esac

cat > "$universal_root/build-manifest.txt" <<EOF
platform=macos-universal
architectures=arm64 x86_64
arm64_manifest_sha256=$(shasum -a 256 "$arm64_root/build-manifest.txt" | awk '{print $1}')
x86_64_manifest_sha256=$(shasum -a 256 "$x86_64_root/build-manifest.txt" | awk '{print $1}')
freerdp_version=$FARFRAME_FREERDP_VERSION
freerdp_commit=$FARFRAME_FREERDP_COMMIT
openssl_version=$FARFRAME_OPENSSL_VERSION
openssl_commit=$FARFRAME_OPENSSL_COMMIT
openh264_version=$FARFRAME_OPENH264_VERSION
openh264_commit=$FARFRAME_OPENH264_COMMIT
EOF

echo "Built Universal native dependencies: $universal_root"
