#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
release_tag=${1:-${FARFRAME_RELEASE_TAG:-}}

/bin/sh "$script_dir/validate-release-version.sh" "$release_tag"
version=${release_tag#v}

release_root=${FARFRAME_RELEASE_OUTPUT_PATH:-"$project_root/.release"}
derived_data=${FARFRAME_DERIVED_DATA_PATH:-"$project_root/.derivedData-release-$version"}
app_path="$derived_data/Build/Products/Release/FarframeRDP.app"
dmg_path="$release_root/FarframeRDP-$version-universal.dmg"
checksum_path="$dmg_path.sha256"

/bin/sh "$script_dir/build-universal-native-dependencies.sh"
/bin/sh "$script_dir/verify-supply-chain.sh"

xcodebuild \
    -project "$project_root/FarframeRDP.xcodeproj" \
    -scheme FarframeRDP \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" \
    ARCHS='arm64 x86_64' \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM= \
    build

if [ ! -d "$app_path" ]; then
    echo "error: Release app was not produced: $app_path" >&2
    exit 1
fi

app_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")
if [ "$app_version" != "$version" ]; then
    echo "error: packaged app version $app_version does not match release version $version" >&2
    exit 1
fi

app_binary="$app_path/Contents/MacOS/FarframeRDP"
architectures=$(xcrun lipo -archs "$app_binary")
case "$architectures" in
    "arm64 x86_64"|"x86_64 arm64") ;;
    *)
        echo "error: packaged app is not Universal: $architectures" >&2
        exit 1
        ;;
esac

embedded_core="$app_path/Contents/Frameworks/FarframeCore.framework"
if [ -e "$embedded_core" ]; then
    echo "error: FarframeCore must be statically linked, not embedded: $embedded_core" >&2
    exit 1
fi
if xcrun otool -L "$app_binary" | grep -Fq '@rpath/FarframeCore.framework'; then
    echo "error: packaged app still dynamically loads FarframeCore" >&2
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "$app_path"
/bin/sh "$script_dir/check-app-static-addins.sh" "$derived_data" Release

mkdir -p "$release_root"
staging_root=$(mktemp -d "${TMPDIR:-/tmp}/farframe-release.XXXXXX")
cleanup() {
    rm -rf "$staging_root"
}
trap cleanup EXIT HUP INT TERM

ditto "$app_path" "$staging_root/FarframeRDP.app"
ln -s /Applications "$staging_root/Applications"
rm -f "$dmg_path" "$checksum_path"
hdiutil create \
    -volname "Farframe RDP $version" \
    -srcfolder "$staging_root" \
    -ov \
    -format UDZO \
    "$dmg_path"
hdiutil verify "$dmg_path"

(
    cd "$release_root"
    shasum -a 256 "$(basename "$dmg_path")" > "$(basename "$checksum_path")"
)

echo "Created ad-hoc signed, unnotarized Universal release: $dmg_path"
echo "Checksum: $checksum_path"
