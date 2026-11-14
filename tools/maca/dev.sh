#!/usr/bin/env bash
# Run the desktop emulator headlessly with an isolated data directory and an
# optional Lua script (see tools/maca/harness.lua), e.g. for screenshots.
#
#   tools/maca/dev.sh script.lua            # phone portrait
#   MACA_DEVICE=tablet tools/maca/dev.sh script.lua
#
# Environment: MACA_HOME (data dir, default .maca-dev/home), MACA_SHOTS
# (screenshot dir, default .maca-dev/shots), MACA_BOOKS (library folder).
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
emu="$(ls -d "$root"/koreader-emulator-*/koreader | head -n1)"
export KO_HOME="${MACA_HOME:-$root/.maca-dev/home}"
export MACA_SHOTS="${MACA_SHOTS:-$root/.maca-dev/shots}"
mkdir -p "$KO_HOME/patches" "$MACA_SHOTS"
cp "$root/tools/maca/harness.lua" "$KO_HOME/patches/2-maca-harness.lua"
case "${MACA_DEVICE:-phone}" in
    phone)  w=540;  h=1200; dpi=220 ;;
    tablet) w=800;  h=1280; dpi=170 ;; # held in portrait
    tablet-landscape) w=1280; h=800; dpi=170 ;;
    *) echo "unknown MACA_DEVICE" >&2; exit 2 ;;
esac
export EMULATE_READER_W="${EMULATE_READER_W:-$w}" EMULATE_READER_H="${EMULATE_READER_H:-$h}" EMULATE_READER_DPI="${EMULATE_READER_DPI:-$dpi}"
export SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy
if [ $# -gt 0 ]; then
    MACA_SCRIPT="$(realpath "$1")"
    export MACA_SCRIPT
fi
cd "$emu"
exec timeout -k 2 "${MACA_TIMEOUT:-60}" ./reader.lua ${MACA_BOOKS:+"$MACA_BOOKS"}
