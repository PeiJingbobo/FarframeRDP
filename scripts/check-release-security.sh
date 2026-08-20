#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd -P)

settings=$(xcodebuild \
    -project "$project_root/FarframeRDP.xcodeproj" \
    -scheme FarframeRDP \
    -configuration Release \
    -destination 'platform=macOS' \
    -showBuildSettings)

require_setting() {
    key=$1
    expected=$2
    actual=$(printf '%s\n' "$settings" | awk -F ' = ' -v key="$key" '$1 ~ "^[[:space:]]*" key "$" { print $2; exit }')
    if [ "$actual" != "$expected" ]; then
        echo "error: Release $key must be $expected (found ${actual:-missing})" >&2
        exit 1
    fi
}

require_setting ENABLE_HARDENED_RUNTIME YES
require_setting ENABLE_APP_SANDBOX NO
require_setting RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION NO
require_setting CODE_SIGN_INJECT_BASE_ENTITLEMENTS NO

if printf '%s\n' "$settings" | grep -Eq '^[[:space:]]*CODE_SIGN_ENTITLEMENTS = .+'; then
    echo "error: unexpected Release entitlements file; audit every entitlement before enabling it" >&2
    exit 1
fi

if ! printf '%s\n' "$settings" | grep -Fq 'INFOPLIST_KEY_NSMicrophoneUsageDescription = '; then
    echo "error: microphone usage description is missing" >&2
    exit 1
fi

if ! printf '%s\n' "$settings" | grep -Fq 'INFOPLIST_KEY_NSLocalNetworkUsageDescription = '; then
    echo "error: local network usage description is missing" >&2
    exit 1
fi

if rg -n --glob '!third-party/**' --glob '!docs/**' \
    'IgnoreCertificate[^,]*,[[:space:]]*TRUE|CertificateCallback[[:space:]]*=[[:space:]]*NULL|TlsSecurity[^,]*,[[:space:]]*FALSE|NlaSecurity[^,]*,[[:space:]]*FALSE' \
    "$project_root/Sources" >/dev/null; then
    echo "error: source contains a certificate/TLS/NLA weakening pattern" >&2
    exit 1
fi

echo "Farframe Release security settings passed"
