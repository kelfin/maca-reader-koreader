# Maca Reader — Roadmap (KOReader fork for Android phone + tablet)

## Context

Goal: a personal ebook reader for an Oppo Find X9 Ultra (phone) and a Lenovo Legion Tab Gen 5 (tablet), forked from KOReader, that feels as seamless as the Kindle app or the Boox built-in reader: a real book library (catalog), reading statistics, and a polished reading screen.

`/home/kelfin/codes/maca-reader` is empty today, so this is a greenfield fork.

What KOReader already gives us, and what it does not:

| Area | Already in KOReader | Gap to close |
|---|---|---|
| Rendering | EPUB/FB2/MOBI (crengine), PDF/CBZ (MuPDF), DjVu | None — keep as is |
| Library | File browser, `coverbrowser.koplugin` (cover grid/list + SQLite metadata cache), collections, history | No real catalog: no home screen, no status filters, no series/author grouping, no book detail page |
| Statistics | `statistics.koplugin` (per-page SQLite log, calendar, per-book time) | Data is good, presentation is dated; no goals, streaks, yearly summary |
| Sync | `kosync.koplugin` (progress), stats sync via cloud storage, OPDS, Calibre wireless | Manual and scattered; no automatic "pick up where I left off" |
| Feel | UI toolkit built for e-ink: no animation, dense nested menus | The biggest gap. Both target devices are fast, high-refresh, non-e-ink screens |

The last row is the main risk: "seamless like Kindle" is mostly UI polish work, not feature work.

## Architecture decisions (recommended)

1. **Stay in Lua, inside KOReader's own widget toolkit.** Build new screens as plugins (`plugins/*.koplugin`) plus a small set of core patches. A native Kotlin/Compose shell around the engine would look smoother but means two codebases and a hard bridge; revisit only at the decision gate after Phase 2.
2. **Plugins first, core patches minimal.** Each core patch is a future merge conflict. Rebase onto upstream's monthly release (`vYYYY.MM`) on a fixed schedule.
3. **One SQLite library database** as the source of truth for the catalog, extending the pattern used by coverbrowser's `BookInfoManager`. Reuse the existing `statistics.sqlite3` rather than inventing a new stats store.
4. **Android only.** Drop e-ink device concerns from our defaults (no flash refreshes, colour on, immersive mode), but do not delete upstream device code — that keeps rebases cheap.
5. **Licence:** KOReader is AGPL-3.0. Personal use is unrestricted; if the APK is ever shared, the source must be published too.

## Phases

Estimates assume one developer, part-time. Each phase ends with an APK installed on both devices.

### Phase 0 — Foundation (1–2 weeks)
- Fork `koreader/koreader`, clone with submodules (`base`, `platform/android/luajit-launcher`).
- Build with `./kodev build android-arm64` / `./kodev release android-arm64` (upstream Docker image avoids NDK setup pain).
- Set up the desktop emulator (`./kodev run`) — this is the daily dev loop; device builds are for checks only.
- Rebrand: app name, application ID (so it installs beside stock KOReader), icon, signing key.
- CI: GitHub Actions builds a signed APK per push.
- Non-e-ink defaults: no flashing, colour rendering, immersive fullscreen, display-cutout handling, follow system dark mode, sensible DPI scaling for phone vs tablet.
- **Exit:** stock-behaviour fork running on both devices under the new name.

### Phase 1 — Library / catalog (4–6 weeks) — the headline feature
- Library index: background scan of chosen folders into SQLite (title, author, series + index, language, tags, cover, added date, status, progress, last opened).
- Home screen replacing the file browser as the start view:
  - "Continue reading" hero card, recently added, recently read.
  - Cover grid / list toggle, adaptive column count (phone portrait vs tablet landscape).
  - Filters: Unread / Reading / Finished / On hold. Sort: recent, title, author, progress.
  - Group by author, series, collection, tag, folder.
  - Fast metadata search (title/author/series), not just file names.
- Book detail page: cover, description, progress, time left, time spent, highlights count, actions (read, mark finished, add to collection, delete).
- Progress bar and status badge on each cover.
- Bottom navigation: Home · Library · Stats · Settings. File browser stays reachable as "Browse files".
- First-run onboarding: grant storage permission, pick library folder, import.
- Study first: `plugins/coverbrowser.koplugin` (BookInfoManager, MosaicMenu, ListMenu), `frontend/apps/filemanager/`, `frontend/readcollection.lua`, `frontend/readhistory.lua`, `frontend/docsettings.lua`. Also review community Kindle-style library plugins (e.g. "Project: Title") before writing our own — reuse or learn from them.
- **Exit:** can open the app, see every book with covers, and resume the last book in two taps.

### Phase 2 — Reading screen polish (4–6 weeks)
- Simplified reader chrome: tap centre → clean top bar (back, title, search, bookmark, contents) and bottom bar (progress scrubber with chapter marks, page / time left).
- One "Aa" panel replacing the deep menus: font, size, line spacing, margins, alignment, theme. Full KOReader menu kept behind "Advanced".
- Themes: Light, Sepia, Dark, true-black OLED; scheduled or follow-system.
- Bundle 4–6 good reading fonts (Literata, Bitter, Atkinson Hyperlegible, etc.) with tuned defaults and hyphenation.
- Simple default tap zones and gestures; brightness slide on the left edge.
- Highlights: colour choices, notes, a per-book notebook view; cleaner dictionary / Wikipedia / translate popup.
- Tablet: two-column pages in landscape, wider margins presets.
- Page-turn slide animation and smooth scroll — investigate early; this is the hardest item in the toolkit and feeds the decision gate.
- Study first: `frontend/apps/reader/readerui.lua` and `frontend/apps/reader/modules/`, `frontend/ui/widget/`, `frontend/ui/elements/`, `frontend/device/android/`.
- **Decision gate:** if the Lua toolkit cannot reach acceptable smoothness on high-refresh screens, decide whether to build Home/Library/Stats as native Android screens over the same SQLite data.

### Phase 3 — Reading statistics (2–3 weeks)
- New dashboard on top of the existing `statistics.koplugin` database:
  - Today / this week / this month time and pages.
  - Streak and daily goal (minutes or pages) with a progress ring.
  - Calendar heat map, reading-hours-by-time-of-day.
  - Per-book: time spent, reading speed, sessions, estimated time to finish.
  - Books finished per month/year, yearly "year in review" summary.
- Shareable summary image for a finished book or a year.
- Optional goal reminder notification.
- **Exit:** Stats tab answers "how much did I read this week, and am I on my streak?" at a glance.

### Phase 4 — Phone ↔ tablet sync (3–4 weeks)
- Automatic progress sync on open/close/suspend via the kosync protocol (self-hosted server or the public one) — no prompts unless there is a real conflict.
- Sync highlights, notes, bookmarks, reading status, collections and statistics, not only position.
- Book files: WebDAV / Syncthing folder or an OPDS source (Calibre-Web, Kavita) shown as "Sources" in the Library.
- "Continue from page X on your tablet?" prompt when opening a book read elsewhere.
- **Exit:** stop on the phone, pick up the tablet, land on the same sentence with the same highlights.

### Phase 5 — Extras (pick by interest)
See suggestions below.

### Phase 6 — Hardening (ongoing, 1–2 weeks before calling it v1.0)
- Cold start to library under ~1 second; cover thumbnails cached; large-library test (2,000+ books).
- Unit tests for the library index and stats queries using upstream's `busted` spec setup.
- Settings backup / restore; crash log capture.
- Monthly upstream rebase routine, documented.
- Distribution: GitHub Releases + Obtainium for self-update on both devices.

## Suggested features that would make it good

Ranked by value for effort:

1. **Automatic cross-device sync of everything** (Phase 4) — the single biggest "feels like Kindle" factor.
2. **Time-left estimates** ("12 min left in chapter") driven by your own reading speed.
3. **Highlights notebook + export** to Markdown / Obsidian / Readwise (upstream `exporter.koplugin` does the export; add the nice view).
4. **Read aloud** using Android text-to-speech, with sentence highlighting and a sleep timer.
5. **Send to reader**: Android "Open with" / Share-to handling, plus a local Wi-Fi upload page for dropping books from a computer.
6. **Vocabulary builder** with spaced-repetition review (upstream `vocabbuilder.koplugin` as the base).
7. **Comics / manga mode for the tablet**: right-to-left, fit modes, double-page spread, panel zoom.
8. **PDF comfort on the tablet**: auto-crop margins, reflow, remembered zoom per book.
9. **Android home-screen widget** for "continue reading" and today's goal (needs a little Kotlin).
10. **AI assist (optional, opt-in)**: "the story so far" recap, character/term look-up without spoilers, explain selected passage.
11. **Per-book and per-format profiles** (novel vs comic vs PDF settings switch automatically).
12. **Series awareness**: "next in series" on finishing a book; finished-book screen with rating and stats.
13. **Split view on the tablet**: book on one side, notes or dictionary on the other.
14. **Backup and restore** of settings, library database and statistics in one file.

## Risks

- **UI smoothness** on high-refresh screens — the toolkit has no animation system. Mitigated by the early spike in Phase 2 and the decision gate.
- **Upstream drift** — mitigated by plugins-first and scheduled rebases.
- **Android storage permissions** — all-files access is needed for a free-form library folder; fine for sideloading, a problem only for Play Store distribution.
- **Scope** — Phases 1–3 alone already deliver the stated goal; treat 4–5 as the second release.

## Verification (per phase)

- Run in the desktop emulator (`./kodev run`) for every change; run upstream tests (`./kodev test front`) plus new specs.
- Build the APK and install on both devices via `adb install`; check phone portrait and tablet landscape for every new screen.
- Phase 1: import a 500+ book folder; confirm scan time, cover display, filters, search, resume-in-two-taps.
- Phase 3: compare dashboard totals against raw queries on `statistics.sqlite3`.
- Phase 4: read on one device, open on the other, confirm position, highlights and stats match; test the offline-then-reconnect conflict case.

## Added to the plan: motion, high refresh rate and glass (2026-11-14)

Requested after the first build. Developed ahead of the remaining phases.

- **High refresh rate:** the launcher asks Android for the display's fastest mode at the current resolution (`setHighRefreshRate` in the launcher fork). Toggle in More.
- **Animation engine** (`maca/animator.lua`): KOReader has none, so transitions are composed on the framebuffer from a before and an after picture. Kinds: slide, cover, uncover, wipe, unwipe. Time-based, so they run at whatever rate the display takes frames.
- **Where it is used:** tab switches, opening and closing screens, drilling into groups, page turns, the reader bars, the display sheet. List flings follow the finger and are time-based.
- **Glass-inspired look** (`maca/glass.lua`): frosted panels made by shrinking and re-stretching what is behind them; floating navigation pill, frosted header, floating reader bars, frosted display sheet, a wash of the current cover's colour on the home tab. Toggle in More, because the cost on a real device is unmeasured.
- **Not possible in this toolkit:** real-time refraction, light effects, morphing shapes, zoom transitions. Those need native Android screens (the decision gate above).
- **Still to do:** page turns that follow the finger (today a swipe or tap triggers a fixed 0.2 s slide); measuring frame rates on the phone and the tablet.

## Added to the plan: read aloud with Kokoro (2026-11-14)

Not started. Two steps, so the reader work is not wasted if Kokoro proves too slow or too large on the devices.

**Step 1 — read aloud with the device's own voices**
- Android side (launcher fork): a playback service on Android's text-to-speech interface, with a notification and play/pause, so reading continues with the screen off.
- Reader side (plugin): send the page text sentence by sentence, highlight the sentence being spoken, turn the page when it runs out.
- Controls in the reading bars: play/pause, speed, voice, sleep timer.

**Step 2 — Kokoro built in**
- Kokoro (82M-parameter model, Apache 2.0) running on-device through sherpa-onnx (Apache 2.0) inside the launcher, as a second engine behind the same controls.
- Model downloaded on first use, not shipped in the APK (roughly 80–330 MB depending on the variant).
- Languages: English is strongest; also Japanese, Chinese, Spanish, French, Hindi, Italian, Brazilian Portuguese. No Indonesian voice.

**Open questions, answerable only on the devices:** speed on the phone and the tablet, battery use, and whether the spoken sentence and the highlight stay in step.

## Status

As of 2026-11-14. "Emulator" means run by the scripted checks in `tools/maca/check.sh` on the desktop emulator. Nothing has run on the phone or the tablet yet.

| Phase | State | Notes |
|---|---|---|
| 0 Foundation | Done except CI run | Fork, signed APK, own name / application ID / icon, emulator harness. `.github/workflows/maca-android.yml` is written but has never run. |
| 1 Library | Emulator | Home, shelves, grid and list, filters, sort, grouping, search, book page, several library folders, next in series. |
| 2 Reading screen | Emulator, partly | Bars with seek slider and time left, display sheet, five page themes, bundled fonts, first-run margins. Missing: follow-the-finger page turns, simpler gesture defaults, cleaner status line. |
| 3 Statistics | Emulator | Today card, week, overview, heat map, hours, most read, year in review, goal. Missing: share image, goal reminder. |
| 4 Sync | Written, untested across devices | Position through KOSync (sign-in and auto-sync in More). Highlights, notes and status through a shared folder (`maca/syncfolder.lua`; additive merge, deletions do not propagate). Statistics sync is left to the Statistics plugin's own cloud sync. Book files are left to whatever syncs the folder. |
| 5 Extras | Partly | Done: highlights notebook with Markdown export and share, time-left estimates, series awareness, backup and restore. Planned above: read aloud with Kokoro. Not started: Wi-Fi upload, vocabulary review, comics mode, PDF comfort, home-screen widget, AI assist, per-format profiles, split view. |
| 6 Hardening | Started | Unit tests in `spec/unit/maca_spec.lua`, scripted emulator checks. Missing: large-library test, device performance pass, upstream rebase routine. |

### Before calling it usable

1. Install on the phone and the tablet (portrait) and go through every screen.
2. Measure animation and scrolling smoothness on both; turn glass off by default if it stutters.
3. Check the top bar against the phone's camera cut-out.
4. Try folder sync between the two devices.
