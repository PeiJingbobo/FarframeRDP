#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
release_tag=${1:-${FARFRAME_RELEASE_TAG:-}}

if [ -z "$release_tag" ]; then
    echo "error: release tag is required (expected vX.Y.Z)" >&2
    exit 2
fi
if ! printf '%s\n' "$release_tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "error: release tag must use the stable version format vX.Y.Z: $release_tag" >&2
    exit 2
fi

tag_version=${release_tag#v}
app_version=$(xcodebuild \
    -project "$project_root/FarframeRDP.xcodeproj" \
    -scheme FarframeRDP \
    -configuration Release \
    -destination 'platform=macOS' \
    -showBuildSettings 2>/dev/null | \
    awk -F ' = ' '/^[[:space:]]*MARKETING_VERSION = / { print $2; exit }')

if [ -z "$app_version" ]; then
    echo "error: MARKETING_VERSION could not be read from the FarframeRDP Release settings" >&2
    exit 1
fi
if [ "$app_version" != "$tag_version" ]; then
    echo "error: release tag $release_tag does not match app MARKETING_VERSION $app_version" >&2
    exit 1
fi

echo "Release version validated: $release_tag"
