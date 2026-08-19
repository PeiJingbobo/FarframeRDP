#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
derived_data=${1:-"$project_root/.derivedData"}
configuration=${2:-Debug}
product_dir="$derived_data/Build/Products/$configuration"
app_dir="$product_dir/FarframeRDP.app"
main_binary="$app_dir/Contents/MacOS/FarframeRDP"
debug_dylib="$app_dir/Contents/MacOS/FarframeRDP.debug.dylib"

if [ -f "$debug_dylib" ]; then
    binary="$debug_dylib"
else
    binary="$main_binary"
fi

if [ ! -f "$binary" ]; then
    echo "error: FarframeRDP app binary not found under $app_dir" >&2
    exit 1
fi

required_symbols='
CLIENT_STATIC_ENTRY_TABLES
audin_DVCPluginEntry
cliprdr_VirtualChannelEntryEx
disp_DVCPluginEntry
drdynvc_VirtualChannelEntryEx
drive_DeviceServiceEntry
mac_freerdp_audin_client_subsystem_entry
mac_freerdp_rdpsnd_client_subsystem_entry
rail_VirtualChannelEntryEx
rdpgfx_DVCPluginEntry
rdpdr_VirtualChannelEntryEx
rdpsnd_DVCPluginEntry
rdpsnd_VirtualChannelEntryEx
'

missing=0
for symbol in $required_symbols; do
    if ! nm "$binary" 2>/dev/null | grep -q "_$symbol"; then
        echo "error: missing FreeRDP static addin symbol in $(basename "$binary"): $symbol" >&2
        missing=1
    fi
done

if [ "$missing" -ne 0 ]; then
    echo "error: final app did not retain all Phase 8 FreeRDP static channel addins" >&2
    exit 1
fi

echo "FarframeRDP app retains required FreeRDP static channel addins"
