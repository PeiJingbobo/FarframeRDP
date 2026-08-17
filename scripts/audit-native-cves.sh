#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd -P)

# shellcheck source=../third-party/versions.sh
. "$project_root/third-party/versions.sh"

curl_bin=${FARFRAME_CURL:-$(command -v curl || true)}
[ -n "$curl_bin" ] && [ -x "$curl_bin" ] || {
    echo "error: curl not found; set FARFRAME_CURL to an executable path" >&2
    exit 1
}

audit_commit() {
    label=$1
    commit=$2
    response=$(mktemp "${TMPDIR:-/tmp}/farframe-osv.XXXXXX")
    trap 'rm -f "$response"' EXIT HUP INT TERM

    "$curl_bin" --fail --silent --show-error \
        --connect-timeout 15 --max-time 60 \
        -H 'Content-Type: application/json' \
        --data "{\"commit\":\"$commit\"}" \
        https://api.osv.dev/v1/query > "$response"

    if grep -q '"id"[[:space:]]*:' "$response"; then
        echo "error: OSV reported vulnerability records for $label commit $commit" >&2
        grep -Eo 'CVE-[0-9]{4}-[0-9]{4,8}' "$response" | sort -u | sed 's/^/  /' >&2
        rm -f "$response"
        trap - EXIT HUP INT TERM
        return 1
    fi

    rm -f "$response"
    trap - EXIT HUP INT TERM
    echo "OSV returned no vulnerability records for $label commit $commit"
}

# WinPR shares the exact FreeRDP source commit, so the same commit query covers both.
audit_commit "FreeRDP/WinPR $FARFRAME_FREERDP_VERSION" "$FARFRAME_FREERDP_COMMIT"
audit_commit "OpenSSL $FARFRAME_OPENSSL_VERSION" "$FARFRAME_OPENSSL_COMMIT"
