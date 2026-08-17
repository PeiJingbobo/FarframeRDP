#!/bin/sh
set -eu

if [ "$#" -eq 0 ]; then
    echo "usage: $0 <diagnostic-artifact> [...]" >&2
    exit 64
fi

for artifact in "$@"; do
    if [ ! -f "$artifact" ]; then
        echo "error: diagnostic artifact does not exist: $artifact" >&2
        exit 66
    fi

    if [ -n "${FARFRAME_SECRET_CANARY:-}" ] &&
        LC_ALL=C grep -Fq -- "$FARFRAME_SECRET_CANARY" "$artifact"; then
        echo "error: secret canary found in diagnostic artifact" >&2
        exit 1
    fi

    if LC_ALL=C grep -Eiq -- '(password|passwd|token|username|domain|host(name)?|fingerprint)[[:space:]]*[:=][[:space:]]*[^<[:space:]]|authorization[[:space:]]*[:=]|bearer[[:space:]]+[A-Za-z0-9]|-----BEGIN [^-]*PRIVATE KEY-----|/Users/[^/<[:space:]]+' "$artifact"; then
        echo "error: potentially private material found in diagnostic artifact" >&2
        exit 1
    fi
done

echo "Diagnostic artifact scan passed"
