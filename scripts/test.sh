#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
configuration=${FARFRAME_CONFIGURATION:-Debug}
derived_data=${FARFRAME_DERIVED_DATA_PATH:-"$project_root/.derivedData"}
architecture=$(uname -m)

/bin/sh "$script_dir/verify-supply-chain.sh"
/bin/sh "$script_dir/build-universal-native-dependencies.sh"

xcodebuild \
    -project "$project_root/FarframeRDP.xcodeproj" \
    -scheme FarframeRDP \
    -configuration "$configuration" \
    -destination "platform=macOS,arch=$architecture" \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    test

/bin/sh "$script_dir/check-app-static-addins.sh" "$derived_data" "$configuration"
