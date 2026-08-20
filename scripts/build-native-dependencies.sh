#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd -P)

# shellcheck source=../third-party/versions.sh
. "$project_root/third-party/versions.sh"

if [ "$(uname -s)" != Darwin ]; then
    echo "error: native dependencies require macOS" >&2
    exit 1
fi

architecture=${FARFRAME_ARCH:-$(uname -m)}
case "$architecture" in
    arm64)
        openssl_target=darwin64-arm64-cc
        system_processor=aarch64
        openh264_use_asm=Yes
        ;;
    x86_64)
        openssl_target=darwin64-x86_64-cc
        system_processor=x86_64
        # The release recipe must not depend on a machine-global NASM install.
        # OpenH264's portable implementation is sufficient for the first
        # Universal release and keeps native builds reproducible on CI.
        openh264_use_asm=No
        ;;
    *)
        echo "error: unsupported FARFRAME_ARCH: $architecture" >&2
        exit 1
        ;;
esac

find_tool() {
    variable_name=$1
    command_name=$2
    eval "configured_path=\${$variable_name:-}"
    if [ -n "$configured_path" ]; then
        if [ ! -x "$configured_path" ]; then
            echo "error: $variable_name is not executable: $configured_path" >&2
            exit 1
        fi
        printf '%s\n' "$configured_path"
        return
    fi

    resolved_path=$(command -v "$command_name" || true)
    if [ -z "$resolved_path" ]; then
        echo "error: $command_name not found; set $variable_name to an executable path" >&2
        exit 1
    fi
    printf '%s\n' "$resolved_path"
}

source_root="$project_root/third-party/sources"
platform="macos-$architecture"
build_root="$project_root/third-party/build/$platform"
artifact_root="$project_root/third-party/artifacts/$platform"
openssl_source="$source_root/openssl"
openh264_source="$source_root/openh264"
freerdp_source="$source_root/freerdp"
freerdp_patch="$project_root/third-party/patches/freerdp-drive-canonical-containment.patch"
openssl_prefix="$artifact_root/openssl"
openh264_prefix="$artifact_root/openh264"
freerdp_prefix="$artifact_root/freerdp"
combined_lib="$artifact_root/lib/libFarframeRDPDependencies.a"
stamp_file="$artifact_root/build-manifest.txt"

expected_manifest=$(cat <<EOF
platform=$platform
build_recipe=17
deployment_target=14.0
system_processor=$system_processor
with_simd=OFF
openh264_use_asm=$openh264_use_asm
channel_audin=ON
channel_cliprdr=ON
channel_disp=ON
channel_drive=ON
channel_printer=OFF
channel_rail=ON
channel_rdpdr=ON
channel_rdpgfx=ON
channel_rdpsnd=ON
channel_smartcard=OFF
with_cups=OFF
with_pcsc=OFF
with_openh264=ON
freerdp_version=$FARFRAME_FREERDP_VERSION
freerdp_commit=$FARFRAME_FREERDP_COMMIT
openssl_version=$FARFRAME_OPENSSL_VERSION
openssl_commit=$FARFRAME_OPENSSL_COMMIT
openh264_version=$FARFRAME_OPENH264_VERSION
openh264_commit=$FARFRAME_OPENH264_COMMIT
EOF
)

if [ -f "$stamp_file" ] && [ -f "$combined_lib" ] &&
   [ "$(cat "$stamp_file")" = "$expected_manifest" ]; then
    echo "Native dependencies are current: $artifact_root"
    exit 0
fi
cmake_bin=$(find_tool FARFRAME_CMAKE cmake)
make_bin=$(find_tool FARFRAME_MAKE make)
if [ -n "${FARFRAME_CMAKE_GENERATOR:-}" ]; then
    cmake_generator=$FARFRAME_CMAKE_GENERATOR
elif command -v ninja >/dev/null 2>&1; then
    cmake_generator=Ninja
else
    cmake_generator="Unix Makefiles"
fi
case "$cmake_generator" in
    Ninja)
        build_tool_bin=$(find_tool FARFRAME_NINJA ninja)
        ;;
    "Unix Makefiles")
        build_tool_bin=$make_bin
        ;;
    *)
        echo "error: unsupported FARFRAME_CMAKE_GENERATOR: $cmake_generator" >&2
        exit 1
        ;;
esac


mkdir -p "$source_root" "$build_root" "$artifact_root/lib"

checkout_exact_commit() {
    repository=$1
    commit=$2
    destination=$3
    label=$4

    if [ ! -d "$destination/.git" ]; then
        if [ -e "$destination" ]; then
            echo "error: non-Git path blocks $label checkout: $destination" >&2
            exit 1
        fi
        git init -q "$destination"
        git -C "$destination" remote add origin "$repository"
    fi

    current_commit=$(git -C "$destination" rev-parse HEAD 2>/dev/null || true)
    if [ "$current_commit" != "$commit" ]; then
        git -C "$destination" fetch --depth 1 origin "$commit"
        git -C "$destination" checkout -q --detach FETCH_HEAD
    fi

    actual_commit=$(git -C "$destination" rev-parse HEAD)
    if [ "$actual_commit" != "$commit" ]; then
        echo "error: $label checkout mismatch: $actual_commit" >&2
        exit 1
    fi
}

checkout_exact_commit \
    "$FARFRAME_OPENSSL_REPOSITORY" \
    "$FARFRAME_OPENSSL_COMMIT" \
    "$openssl_source" \
    OpenSSL

checkout_exact_commit \
    "$FARFRAME_FREERDP_REPOSITORY" \
    "$FARFRAME_FREERDP_COMMIT" \
    "$freerdp_source" \
    FreeRDP

checkout_exact_commit \
    "$FARFRAME_OPENH264_REPOSITORY" \
    "$FARFRAME_OPENH264_COMMIT" \
    "$openh264_source" \
    OpenH264

# The upstream drive add-in rejects `..` components, but the pinned 3.30.0
# implementation otherwise follows symlinks without checking that the resolved
# target remains below the explicitly shared root. Keep this security patch in
# the reproducible recipe and fail closed if the pinned source no longer matches.
if git -C "$freerdp_source" apply --reverse --check "$freerdp_patch" 2>/dev/null; then
    : # already applied in this local checkout
elif git -C "$freerdp_source" apply --check "$freerdp_patch"; then
    git -C "$freerdp_source" apply "$freerdp_patch"
else
    echo "error: FreeRDP drive containment patch does not apply cleanly" >&2
    exit 1
fi

openssl_stamp="$openssl_prefix/.farframe-build-commit"
openssl_expected_stamp="$FARFRAME_OPENSSL_COMMIT $platform deployment-target-14.0"
if [ ! -f "$openssl_stamp" ] || [ "$(cat "$openssl_stamp")" != "$openssl_expected_stamp" ]; then
    openssl_build="$build_root/openssl"
    rm -rf "$openssl_build" "$openssl_prefix"
    mkdir -p "$openssl_build" "$openssl_prefix"

    (
        cd "$openssl_build"
        export MACOSX_DEPLOYMENT_TARGET=14.0
        export CFLAGS="-mmacosx-version-min=14.0"
        "$openssl_source/Configure" \
            "$openssl_target" \
            no-shared \
            no-tests \
            no-docs \
            --prefix="$openssl_prefix" \
            --openssldir="$openssl_prefix/ssl"
        make -j"$(sysctl -n hw.logicalcpu)"
        make install_sw
    )
    printf '%s\n' "$openssl_expected_stamp" > "$openssl_stamp"
fi

openh264_stamp="$openh264_prefix/.farframe-build-commit"
openh264_expected_stamp="$FARFRAME_OPENH264_COMMIT $platform deployment-target-14.0 use-asm-$openh264_use_asm isolated-source explicit-compiler-arch"
if [ ! -f "$openh264_stamp" ] ||
   [ "$(cat "$openh264_stamp")" != "$openh264_expected_stamp" ]; then
    openh264_build="$build_root/openh264"
    rm -rf "$openh264_build" "$openh264_prefix"
    openh264_build_source="$openh264_build/source"
    mkdir -p "$openh264_build_source" "$openh264_prefix"
    git -C "$openh264_source" archive --format=tar "$FARFRAME_OPENH264_COMMIT" |
        tar -xf - -C "$openh264_build_source"
    MACOSX_DEPLOYMENT_TARGET=14.0 "$make_bin" \
        -C "$openh264_build_source" \
        -j"$(sysctl -n hw.logicalcpu)" \
        CC="clang -arch $architecture" \
        CXX="clang++ -arch $architecture" \
        CCAS="clang -arch $architecture" \
        ARCH="$architecture" \
        USE_ASM="$openh264_use_asm" \
        BUILDTYPE=Release \
        PREFIX="$openh264_prefix" \
        install-static
    printf '%s\n' "$openh264_expected_stamp" > "$openh264_stamp"
fi

freerdp_build="$build_root/freerdp"
rm -rf "$freerdp_build" "$freerdp_prefix"

MACOSX_DEPLOYMENT_TARGET=14.0 "$cmake_bin" \
    -S "$freerdp_source" \
    -B "$freerdp_build" \
    -G "$cmake_generator" \
    -DCMAKE_MAKE_PROGRAM="$build_tool_bin" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$freerdp_prefix" \
    -DCMAKE_OSX_ARCHITECTURES="$architecture" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_SYSTEM_PROCESSOR="$system_processor" \
    -DCMAKE_PREFIX_PATH="$openssl_prefix;$openh264_prefix" \
    -DOPENSSL_ROOT_DIR="$openssl_prefix" \
    -DOPENSSL_USE_STATIC_LIBS=TRUE \
    -DOPENH264_ROOT="$openh264_prefix" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF \
    -DBUILD_TESTING_INTERNAL=OFF \
    -DBUILD_BENCHMARK=OFF \
    -DWITH_CLIENT=OFF \
    -DWITH_CLIENT_COMMON=ON \
    -DWITH_CLIENT_SDL=OFF \
    -DWITH_SERVER=OFF \
    -DWITH_SERVER_INTERFACE=OFF \
    -DWITH_PROXY=OFF \
    -DWITH_SHADOW=OFF \
    -DWITH_SAMPLE=OFF \
    -DWITH_CHANNELS=ON \
    -DWITH_CLIENT_CHANNELS=ON \
    -DWITH_SERVER_CHANNELS=OFF \
    -DCHANNEL_AINPUT=OFF \
    -DCHANNEL_AUDIN=ON \
    -DCHANNEL_CLIPRDR=ON \
    -DCHANNEL_DISP=ON \
    -DCHANNEL_DRDYNVC=ON \
    -DCHANNEL_DRIVE=ON \
    -DCHANNEL_ECHO=OFF \
    -DCHANNEL_ENCOMSP=OFF \
    -DCHANNEL_GEOMETRY=OFF \
    -DCHANNEL_GFXREDIR=OFF \
    -DCHANNEL_LOCATION=OFF \
    -DCHANNEL_PARALLEL=OFF \
    -DCHANNEL_PRINTER=OFF \
    -DCHANNEL_RAIL=ON \
    -DCHANNEL_RDP2TCP=OFF \
    -DCHANNEL_RDPDR=ON \
    -DCHANNEL_RDPEAR=OFF \
    -DCHANNEL_RDPECAM=OFF \
    -DCHANNEL_RDPEI=OFF \
    -DCHANNEL_RDPEMSC=OFF \
    -DCHANNEL_RDPEWA=OFF \
    -DCHANNEL_RDPGFX=ON \
    -DCHANNEL_RDPSND=ON \
    -DCHANNEL_REMDESK=OFF \
    -DCHANNEL_SERIAL=OFF \
    -DCHANNEL_SMARTCARD=OFF \
    -DCHANNEL_SSHAGENT=OFF \
    -DCHANNEL_TELEMETRY=OFF \
    -DCHANNEL_TSMF=OFF \
    -DCHANNEL_URBDRC=OFF \
    -DCHANNEL_VIDEO=OFF \
    -DWITH_THIRD_PARTY=OFF \
    -DWITH_MANPAGES=OFF \
    -DWITH_WINPR_TOOLS=OFF \
    -DWITH_OPENSSL=ON \
    -DWITH_MBEDTLS=OFF \
    -DWITH_OPENH264=ON \
    -DWITH_OPENH264_LOADING=OFF \
    -DWITH_JSON_DISABLED=ON \
    -DWITH_FFMPEG=OFF \
    -DWITH_SWSCALE=OFF \
    -DWITH_SIMD=OFF \
    -DWITH_JPEG=OFF \
    -DWITH_CUPS=OFF \
    -DWITH_PCSC=OFF \
    -DWITH_FUSE=OFF \
    -DWITH_MACAUDIO=ON \
    -DWITH_VERBOSE_WINPR_ASSERT=ON \
    -DWITH_DEBUG_ALL=OFF \
    -DWITH_DEBUG_CERTIFICATE=OFF \
    -DWITH_DEBUG_KBD=OFF

"$cmake_bin" --build "$freerdp_build" --parallel "$(sysctl -n hw.logicalcpu)"
"$cmake_bin" --install "$freerdp_build"

archive_list="$build_root/native-archives.txt"
find "$freerdp_prefix/lib" "$openssl_prefix/lib" "$openh264_prefix/lib" \
    -type f -name '*.a' -print | sort > "$archive_list"
if [ ! -s "$archive_list" ]; then
    echo "error: no static native dependency archives were produced" >&2
    exit 1
fi

# Apple libtool creates one private aggregate archive so Xcode consumers never
# need Homebrew paths or a fragile hand-maintained transitive library list.
# Archive paths come only from the three fixed installation prefixes above.
archives=$(cat "$archive_list")
# shellcheck disable=SC2086
xcrun libtool -static -o "$combined_lib" $archives

archive_architectures=$(xcrun lipo -archs "$combined_lib")
if [ "$archive_architectures" != "$architecture" ]; then
    echo "error: $platform aggregate archive contains unexpected architectures: $archive_architectures" >&2
    exit 1
fi

printf '%s\n' "$expected_manifest" > "$stamp_file"
echo "Built native dependencies: $artifact_root"
