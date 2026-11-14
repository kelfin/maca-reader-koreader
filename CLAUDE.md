# Maca Reader

Personal Android ebook reader (phone + tablet), forked from KOReader. Plan and progress: `ROADMAP.md`.

## Layout

- `plugins/maca.koplugin/` — the Maca plugin. `main.lua` wires it in; everything else is under `maca/` and required as `maca/<module>` (the prefix avoids clashes with other plugins' module names).
  - UI: `home`, `screen`, `scrollview`, `rows`, `bookdetail`, `statsview`, `notebook`, `reader` (bars and display sheet), `theme`, `glass`, `animator`, `covers`.
  - Data and services: `library` (index), `stats` (read-only statistics queries), `syncfolder`, `backup`, `defaults` (first-run settings), `speech` (read aloud), `assistant` (Claude API, user's own key), `wifiupload`.
  - Android-only pieces call into the launcher fork through the `android` Lua module: `setHighRefreshRate`, `getRefreshRate`, `speechStart/Say/Stop/SetRate/Done`. They are absent in the emulator, so every caller checks for them first.
- Core patches outside the plugin are deliberately few: `reader.lua` (loads `maca/defaults`), `frontend/fontlist.lua` (plugin fonts), `make/android.mk`.

- `frontend/` — Lua UI and reader logic (upstream).
- `plugins/*.koplugin` — plugins. New Maca features go here first; keep core patches minimal so upstream rebases stay cheap.
- `base/` — C/C++ engine submodule (koreader-base). Avoid changing.
- `platform/android/luajit-launcher/` — Android launcher submodule (Kotlin/Gradle; holds the application ID).
- `make/android.mk` — Android packaging; `ANDROID_APP_NAME` (launcher label), `ANDROID_PACKAGE_ID` (application ID), `ANDROID_KEYSTORE` (signing).

## Git

- `origin` = kelfin/maca-reader, `upstream` = koreader/koreader. Work branch: `maca`. Rebase onto upstream release tags (`vYYYY.MM`) monthly.
- `platform/android/luajit-launcher` points at kelfin/android-luajit-launcher, branch `maca` (remote `fork` inside the submodule). Commit and push there first, then commit the new submodule pointer here.
- Submodules are shallow clones. Use `git fetch --no-recurse-submodules upstream`; a plain fetch tries to download submodule history.

## Build

One-time setup (Ubuntu):

    sudo apt install --no-install-recommends autoconf automake build-essential \
        ca-certificates cmake gcc-multilib gettext git libtool libtool-bin meson \
        nasm ninja-build patch pkg-config unzip wget libsdl3-0 \
        openjdk-17-jdk-headless p7zip-full adb ccache luajit

Commands:

    ./kodev run                     # desktop emulator — the daily dev loop
    ./kodev test front              # Lua unit tests (busted, in spec/)
    ./kodev check                   # lint (needs luacheck)
    ./kodev release -i android-arm64      # APK in the repo root (maca-reader-android-arm64-*.apk)
    ./kodev release -i -b android-arm64   # repackage only (Lua / launcher changes), about 30 s

The NDK and SDK live in `base/toolchain` (downloaded on first build). A clean build of the native libraries is slow; later builds are incremental.

Scripted emulator checks (screenshots in `.maca-dev/shots`, log in `.maca-dev/check.log`):

    MACA_BOOKS=/folder/with/a/dozen/epubs tools/maca/check.sh
    MACA_DEVICE=tablet tools/maca/dev.sh tools/maca/scripts/tour.lua   # one script; phone | tablet | tablet-landscape

Scripts live in `tools/maca/scripts/`; `tools/maca/harness.lua` gives them `MacaHarness.steps/shot/quit`. The emulator poses as an e-ink device, so animations are off there unless a script sets `maca_animations` to true. Unit tests: `./kodev test front maca`.

Headless emulator smoke test (no display needed):

    cd koreader-emulator-*/koreader && SDL_VIDEODRIVER=dummy timeout 20 ./reader.lua -d .

Exit code 124 with no `error`/`traceback` lines in the output means it started and ran.

## Signing

The APK is signed with `~/.config/maca-reader/maca.keystore` (password in `maca.keystore.pass` beside it) when that file exists; otherwise it is left unsigned. Neither file belongs in git. Android only accepts updates signed with the same key, so the keystore must be backed up.

## Conventions

- Lua, upstream style (4 spaces, luacheck clean). User-visible strings go through `_()` from `gettext`.
- Target devices are fast non-e-ink screens: check every new screen in phone portrait and tablet landscape.
- Licence is AGPL-3.0; keep upstream copyright headers.
