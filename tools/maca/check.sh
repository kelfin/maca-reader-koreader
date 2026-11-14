#!/usr/bin/env bash
# Run every scripted emulator check against a fresh dev profile.
#   MACA_BOOKS=/path/to/sample/epubs tools/maca/check.sh
# Screenshots land in .maca-dev/shots. Exits non-zero if any script fails.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
: "${MACA_BOOKS:?set MACA_BOOKS to a folder with a dozen EPUB files}"
export MACA_BOOKS
rm -rf "$root/.maca-dev/home"
mkdir -p "$root/.maca-dev"
log="$root/.maca-dev/check.log"
: > "$log"
failed=0
run() { # device script
    echo "== $1 $2" >> "$log"
    if MACA_DEVICE="$1" MACA_TIMEOUT=90 "$root/tools/maca/dev.sh" "$root/tools/maca/scripts/$2.lua" >> "$log" 2>&1 \
        && ! grep -q "MACA_HARNESS_ERROR" "$log"; then
        echo "ok    $1 $2"
    else
        echo "FAIL  $1 $2"
        failed=1
    fi
}
run phone seed
run phone tour
run phone interact
run phone reader
run phone animate
run tablet tour
run tablet reader
if [ "$failed" -ne 0 ]; then
    grep -n -A12 "MACA harness error" "$log" | head -60
fi
exit "$failed"
