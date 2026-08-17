#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd -P)

# shellcheck source=../third-party/versions.sh
. "$project_root/third-party/versions.sh"

sbom="$project_root/third-party/sbom.spdx"
freerdp_license="$project_root/third-party/licenses/FreeRDP-Apache-2.0.txt"
openssl_license="$project_root/third-party/licenses/OpenSSL-Apache-2.0.txt"
artifact_manifest="$project_root/third-party/artifacts/macos-arm64/build-manifest.txt"
aggregate_archive="$project_root/third-party/artifacts/macos-arm64/lib/libFarframeRDPDependencies.a"

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

assert_line "$sbom" "PackageVersion: $FARFRAME_FREERDP_VERSION"
assert_line "$sbom" "PackageDownloadLocation: git+$FARFRAME_FREERDP_REPOSITORY@$FARFRAME_FREERDP_COMMIT"
assert_line "$sbom" "PackageVersion: $FARFRAME_OPENSSL_VERSION"
assert_line "$sbom" "PackageDownloadLocation: git+$FARFRAME_OPENSSL_REPOSITORY@$FARFRAME_OPENSSL_COMMIT"

package_count=$(grep -c '^PackageName:' "$sbom")
[ "$package_count" -eq 3 ] || fail "SBOM package count is $package_count; expected FreeRDP, WinPR, and OpenSSL"
for package in FreeRDP WinPR OpenSSL; do
    assert_line "$sbom" "PackageName: $package"
done

freerdp_license_hash=$(shasum -a 256 "$freerdp_license" | awk '{print $1}')
openssl_license_hash=$(shasum -a 256 "$openssl_license" | awk '{print $1}')
[ "$freerdp_license_hash" = cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30 ] ||
    fail "FreeRDP license text hash changed; review upstream license before accepting it"
[ "$openssl_license_hash" = 7d5450cb2d142651b8afa315b5f238efc805dad827d91ba367d8516bc9d49e7a ] ||
    fail "OpenSSL license text hash changed; review upstream license before accepting it"

if [ -f "$artifact_manifest" ]; then
    assert_line "$artifact_manifest" "freerdp_version=$FARFRAME_FREERDP_VERSION"
    assert_line "$artifact_manifest" "freerdp_commit=$FARFRAME_FREERDP_COMMIT"
    assert_line "$artifact_manifest" "openssl_version=$FARFRAME_OPENSSL_VERSION"
    assert_line "$artifact_manifest" "openssl_commit=$FARFRAME_OPENSSL_COMMIT"
    [ -f "$aggregate_archive" ] || fail "build manifest exists but aggregate native archive is missing"
    echo "Verified pinned inputs, SPDX SBOM, licenses, and native artifact manifest"
else
    echo "Verified pinned inputs, SPDX SBOM, and licenses (native artifacts not present)"
fi
