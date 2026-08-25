# Sam's Ebook Library

Native macOS app (SwiftUI, non-sandboxed, notarized) that scans your Mac for
EPUB/PDF/CBZ books, imports them into one library with a built-in reader, and
stores the library folder inside iCloud Drive or Google Drive for backup.

Full plan: see `PLAN.md` in this folder.

## Status: Phase 1 scaffolded

What exists right now:
- Xcode project defined via `project.yml` (XcodeGen) — no `.xcodeproj` is
  committed; you generate it locally.
- `ScannerService` — walks Documents, Desktop, Downloads + any folder you add,
  finds `.epub` / `.pdf` / `.cbz` files. No metadata extraction yet — that's
  Phase 2.
- A bare-bones list UI (`ContentView`) that shows what the scanner found, and
  a `SettingsView` to add/remove extra folders and trigger a rescan.

## First-time setup (run this on your actual Mac, in Terminal)

```bash
cd ~/Documents/SamEbookLibrary
brew install xcodegen        # one-time, if you don't have it
xcodegen generate            # turns project.yml into SamEbookLibrary.xcodeproj
open SamEbookLibrary.xcodeproj
```

Then in Xcode: pick the `SamEbookLibrary` scheme, hit Run (⌘R). The first
launch will pop the standard macOS "would like to access files in your
Documents/Desktop/Downloads folder" dialogs — click Allow on each. That's the
whole permission story; no System Settings trip needed.

Whenever new Swift files are added, re-run `xcodegen generate` to pick them up
(or just edit `project.yml`'s `sources` list if you reorganize folders).

## Next phases (not built yet)

- **Phase 2:** EPUBKit/PDFKit/CBZ metadata + cover extraction, dedup by file
  hash, SQLite-backed `LibraryStore` (SwiftData or GRDB), real cover-grid
  library UI.
- **Phase 3:** In-app reader (EPUB via WKWebView, PDF via PDFKit, CBZ paged
  viewer).
- **Phase 4:** iCloud/Google Drive folder picker in Settings, search/sort/tags,
  empty states, app icon.

See the handoff prompts delivered alongside this project for exact next steps
to hand to your coding agent.
