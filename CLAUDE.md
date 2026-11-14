# Maca Reader

Personal Android ebook reader (phone + tablet), forked from KOReader. Plan and progress: `ROADMAP.md`.

## Layout

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

Headless emulator smoke test (no display needed):

    cd koreader-emulator-*/koreader && SDL_VIDEODRIVER=dummy timeout 20 ./reader.lua -d .

Exit code 124 with no `error`/`traceback` lines in the output means it started and ran.

## Signing

The APK is signed with `~/.config/maca-reader/maca.keystore` (password in `maca.keystore.pass` beside it) when that file exists; otherwise it is left unsigned. Neither file belongs in git. Android only accepts updates signed with the same key, so the keystore must be backed up.

## Conventions

- Lua, upstream style (4 spaces, luacheck clean). User-visible strings go through `_()` from `gettext`.
- Target devices are fast non-e-ink screens: check every new screen in phone portrait and tablet landscape.
- Licence is AGPL-3.0; keep upstream copyright headers.
