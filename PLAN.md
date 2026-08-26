# Stoa — Plan & Architecture

**Type:** Native macOS app, SwiftUI
**Goal:** Scan Sam's laptop for ebooks, pull them into one Calibre-style library, with a built-in reader and cloud backup.

---

## 1. Final Scope

| Area | Decision |
|---|---|
| Formats | EPUB, PDF, CBZ |
| MOBI/AZW | Out of scope (mostly DRM-locked Kindle files; not building DRM removal) |
| CBR | Out of scope for v1 (RAR dependency); CBZ only |
| Scanning | Documents, Downloads, Desktop + any folder Sam manually adds |
| Permissions | Non-sandboxed, notarized app — simple one-time "Allow" popups per folder, no System Settings trip |
| Organizing | Grid/list library view, metadata (title/author/cover), search, tags/collections |
| Reading | Built-in reader (EPUB + PDF + CBZ page viewer) |
| Backup/sync | Library folder lives inside iCloud Drive (default) or Google Drive folder (fallback) — no account integration needed, just points at the right folder |

---

## 2. Why these calls (research notes)

- **Full Disk Access vs. per-folder prompts:** True Full Disk Access requires Sam to go into System Settings → Privacy — that's the "stressful" path. Since this app won't go through the App Store, it doesn't need to be sandboxed. A normal signed + notarized app gets a simple native "MyApp would like to access files in your Documents folder" dialog the first time it touches each protected folder (Documents, Desktop, Downloads). One click, no settings hunting. This satisfies "full disk-ish" coverage without the stress.
- **MOBI/AZW dropped:** Kindle-purchased books are DRM-encrypted by default; only self-made or explicitly DRM-free files would work, and there's no reliable way to tell which is which without opening them. Rather than build a feature that mostly shows locked/broken books, we're skipping the format. If Sam has actual Kindle books she reads a lot, she'll keep using the Kindle app for those — this app handles everything else.
- **CBR dropped for v1:** CBZ is just a ZIP file — trivial and dependency-free to read. CBR is a RAR archive and needs a bundled unrar binary, which adds complexity and a licensing consideration. Can be added later if Sam turns out to have a comics collection in CBR specifically.
- **EPUB parsing:** Using an actively maintained Swift library (EPUBKit) for metadata + manifest + cover extraction rather than hand-rolling XML/zip parsing.
- **PDF:** Apple's own PDFKit handles rendering and metadata — no third-party dependency needed.
- **Backup/sync:** Rather than integrating iCloud or Google Drive APIs (real complexity, auth flows, quota handling), the library's storage folder is simply placed inside whatever the user already has mounted as a Finder folder — iCloud Drive or Google Drive's local sync folder. Files just sync automatically because Finder is already watching that folder. Zero extra code, zero extra sign-in.

---

## 3. High-Level Architecture

```
Stoa (macOS App, SwiftUI + AppKit interop)
│
├── ScannerService
│   ├── Watches: ~/Documents, ~/Desktop, ~/Downloads, + user-added folders
│   ├── Walks directory tree, filters by extension (.epub, .pdf, .cbz)
│   ├── Emits found file URLs to the Import pipeline
│   └── Persists list of "known" folders (incl. any Sam adds via a folder picker)
│
├── ImportPipeline
│   ├── EPUB → EPUBKit → title/author/cover/language
│   ├── PDF  → PDFKit → title (from metadata or filename), first-page thumbnail as cover
│   ├── CBZ  → unzip first image entry → cover thumbnail; filename-based title
│   ├── Dedup check (by file hash) to avoid double-importing
│   └── Writes book record + copies (or references) file into the Library folder
│
├── LibraryStore
│   ├── SQLite (via SwiftData or GRDB) — book metadata, tags, collections, read progress
│   └── Library folder location = iCloud Drive/Stoa or GoogleDrive/Stoa
│
├── UI (SwiftUI)
│   ├── Library Grid/List View — covers, search, sort (title/author/recent/format)
│   ├── Book Detail — metadata, "Open" / "Read"
│   ├── Reader
│   │   ├── EPUB reader (WKWebView rendering EPUB content + pagination)
│   │   ├── PDF reader (PDFKit's PDFView, built-in)
│   │   └── CBZ reader (paged image viewer)
│   └── Settings — manage watched folders, choose iCloud vs Google Drive, re-scan
│
└── Permissions layer
    └── Standard macOS folder-access prompts (no sandbox), triggered on first scan
```

---

## 4. Build Phases

1. **Phase 1 — Scaffold & scanning:** Xcode project, folder scanning + permission prompts, raw file discovery (no metadata yet) — prove we can actually find her books.
2. **Phase 2 — Import & metadata:** Wire up EPUBKit, PDFKit, CBZ cover extraction; store book records; basic library grid UI.
3. **Phase 3 — Reader:** EPUB/PDF/CBZ in-app reading views.
4. **Phase 4 — Backup/sync + polish:** iCloud/Google Drive folder picker in Settings, search/sort/tags, empty states, app icon.

---

## 5. Open Questions for Later (not blocking the plan)

- Should duplicate books (same title, different file) be merged or kept separate?
- Any interest in reading progress / "currently reading" tracking?
- Should the app delete/move originals after import, or just copy and leave originals in place? (Leaving originals in place is safer default — avoids ever looking like it "lost" a file.)

---

**Status: Phase 1 scaffolded.** See README.md for setup + next-phase handoff prompts.
