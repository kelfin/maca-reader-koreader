# Maca Reader

Personal Android ebook reader (phone + tablet), forked from KOReader. Plan and progress: `ROADMAP.md`.

## Layout

- `frontend/` — Lua UI and reader logic (upstream).
- `plugins/*.koplugin` — plugins. New Maca features go here first; keep core patches minimal so upstream rebases stay cheap.
- `base/` — C/C++ engine submodule (koreader-base). Avoid changing.
- `platform/android/luajit-launcher/` — Android launcher submodule (Kotlin/Gradle; holds the application ID).
- `make/android.mk` — Android packaging; `ANDROID_APP_NAME` sets the launcher label.

## Git

- `upstream` = koreader/koreader. Work branch: `maca`. Rebase onto upstream release tags (`vYYYY.MM`) monthly.
- The clone and submodules are shallow; run `git fetch --unshallow upstream` before rebasing across releases.
- Submodules in use: `base`, `platform/android/luajit-launcher`, `l10n`, `resources/fonts`. `test` (test data) is not initialised; `git submodule update --init test` before running specs.

## Build

One-time setup (Ubuntu):

    sudo apt install --no-install-recommends autoconf automake build-essential \
        ca-certificates cmake gcc-multilib gettext git libtool libtool-bin meson \
        nasm ninja-build patch pkg-config unzip wget libsdl3-0 \
        openjdk-17-jdk-headless p7zip-full adb

Commands:

    ./kodev run                     # desktop emulator — the daily dev loop
    ./kodev test front              # Lua unit tests (busted, in spec/)
    ./kodev check                   # lint (needs luacheck)
    ./kodev build android-arm64     # debug build
    ./kodev release android-arm64   # APK; NDK r23c and SDK are downloaded into base/toolchain on first run

The first build compiles all third-party libraries and takes a long time.

## Conventions

- Lua, upstream style (4 spaces, luacheck clean). User-visible strings go through `_()` from `gettext`.
- Target devices are fast non-e-ink screens: check every new screen in phone portrait and tablet landscape.
- Licence is AGPL-3.0; keep upstream copyright headers.
