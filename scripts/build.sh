#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
configuration=${FARFRAME_CONFIGURATION:-Debug}
derived_data=${FARFRAME_DERIVED_DATA_PATH:-"$project_root/.derivedData"}

/bin/sh "$script_dir/build-native-dependencies.sh"

exec xcodebuild \
    -project "$project_root/FarframeRDP.xcodeproj" \
    -scheme FarframeRDP \
    -configuration "$configuration" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    build
