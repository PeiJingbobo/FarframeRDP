#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd -P)

# shellcheck source=../third-party/versions.sh
. "$project_root/third-party/versions.sh"

sbom="$project_root/third-party/sbom.spdx"
freerdp_license="$project_root/third-party/licenses/FreeRDP-Apache-2.0.txt"
openssl_license="$project_root/third-party/licenses/OpenSSL-Apache-2.0.txt"
openh264_license="$project_root/third-party/licenses/OpenH264-BSD-2-Clause.txt"
artifact_manifest="$project_root/third-party/artifacts/macos-universal/build-manifest.txt"
aggregate_archive="$project_root/third-party/artifacts/macos-universal/lib/libFarframeRDPDependencies.a"

fail() {
    echo "error: $*" >&2
    exit 1
}

assert_line() {
    file=$1
    expected=$2
    grep -Fqx "$expected" "$file" || fail "missing or stale entry in ${file#$project_root/}: $expected"
}

[ -f "$sbom" ] || fail "missing third-party/sbom.spdx"
[ -f "$freerdp_license" ] || fail "missing FreeRDP license text"
[ -f "$openssl_license" ] || fail "missing OpenSSL license text"
[ -f "$openh264_license" ] || fail "missing OpenH264 license text"

assert_line "$sbom" "PackageVersion: $FARFRAME_FREERDP_VERSION"
assert_line "$sbom" "PackageDownloadLocation: git+$FARFRAME_FREERDP_REPOSITORY@$FARFRAME_FREERDP_COMMIT"
assert_line "$sbom" "PackageVersion: $FARFRAME_OPENSSL_VERSION"
assert_line "$sbom" "PackageDownloadLocation: git+$FARFRAME_OPENSSL_REPOSITORY@$FARFRAME_OPENSSL_COMMIT"
assert_line "$sbom" "PackageVersion: $FARFRAME_OPENH264_VERSION"
assert_line "$sbom" "PackageDownloadLocation: git+$FARFRAME_OPENH264_REPOSITORY@$FARFRAME_OPENH264_COMMIT"

package_count=$(grep -c '^PackageName:' "$sbom")
[ "$package_count" -eq 4 ] || fail "SBOM package count is $package_count; expected FreeRDP, WinPR, OpenSSL, and OpenH264"
for package in FreeRDP WinPR OpenSSL OpenH264; do
    assert_line "$sbom" "PackageName: $package"
done

freerdp_license_hash=$(shasum -a 256 "$freerdp_license" | awk '{print $1}')
openssl_license_hash=$(shasum -a 256 "$openssl_license" | awk '{print $1}')
openh264_license_hash=$(shasum -a 256 "$openh264_license" | awk '{print $1}')
[ "$freerdp_license_hash" = cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30 ] ||
    fail "FreeRDP license text hash changed; review upstream license before accepting it"
[ "$openssl_license_hash" = 7d5450cb2d142651b8afa315b5f238efc805dad827d91ba367d8516bc9d49e7a ] ||
    fail "OpenSSL license text hash changed; review upstream license before accepting it"
[ "$openh264_license_hash" = 0f2262320212046c7453b0d2f10b44ca6702481f18168ee4a963c45eb6aea2f1 ] ||
    fail "OpenH264 license text changed; review upstream license before accepting it"

if [ -f "$artifact_manifest" ]; then
    assert_line "$artifact_manifest" "freerdp_version=$FARFRAME_FREERDP_VERSION"
    assert_line "$artifact_manifest" "freerdp_commit=$FARFRAME_FREERDP_COMMIT"
    assert_line "$artifact_manifest" "openssl_version=$FARFRAME_OPENSSL_VERSION"
    assert_line "$artifact_manifest" "openssl_commit=$FARFRAME_OPENSSL_COMMIT"
    assert_line "$artifact_manifest" "openh264_version=$FARFRAME_OPENH264_VERSION"
    assert_line "$artifact_manifest" "openh264_commit=$FARFRAME_OPENH264_COMMIT"
    [ -f "$aggregate_archive" ] || fail "build manifest exists but aggregate native archive is missing"
    architectures=$(xcrun lipo -archs "$aggregate_archive")
    case "$architectures" in
        "arm64 x86_64"|"x86_64 arm64") ;;
        *) fail "native dependency archive is not Universal: $architectures" ;;
    esac
    echo "Verified pinned inputs, SPDX SBOM, licenses, and native artifact manifest"
else
    echo "Verified pinned inputs, SPDX SBOM, and licenses (native artifacts not present)"
fi
