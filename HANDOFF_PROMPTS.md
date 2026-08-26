# Handoff Prompts — Stoa

Project location: `~/Documents/Stoa`
Status: Phase 1 (scaffold + folder scanning) is done.

Give these to your coding agent **one at a time, in order**, in a terminal opened
at `~/Documents/Stoa`. Each prompt is self-contained — the agent
doesn't need memory of this conversation, just the project on disk. Let it
finish and build successfully in Xcode before moving to the next prompt.

---

## Prompt 0 — First build (do this yourself, or give it to the agent first)

```
Open ~/Documents/Stoa in Terminal. Run:
  brew install xcodegen   (skip if already installed)
  xcodegen generate
  open Stoa.xcodeproj

In Xcode, build and run the Stoa scheme (Cmd+R). Fix any compile
errors you hit — the source was written without a local Xcode to verify it,
so there may be small issues (an import, an API signature). Do not change
the app's architecture or file layout while fixing errors, just make it
compile and run. Confirm it launches, shows the permission prompts for
Documents/Desktop/Downloads, and lists found .epub/.pdf/.cbz files.
```

---

## Prompt 1 — Phase 2: Import & Metadata (rewritten — supersedes the original)

The version below replaces the original Prompt 1 in this file. That one was
written before the design pass — it assumed a flat-list ContentView and no
LibraryStore, which is stale now. Use only this version.

```
I'm building a macOS SwiftUI app called Stoa, at ~/Documents/Stoa. Read
PLAN.md, README.md, and this file's earlier prompts (up through the "Real
design pass" one) for context — but trust the CODE on disk over any of the
handoff prose if they ever disagree, since a few things have moved since
those were written.

Current real state, so you don't have to rediscover it: Phase 1 (scanning,
permissions) is done. There's a full library grid (ContentView.swift) with
a "Recently added" HeroBand, sidebar filtering by format/watched-folder,
and a MattedCoverView that renders PDF covers as a colored mat with the
real page thumbnail inset (loaded async via CoverThumbnailCache), while
EPUB/CBZ currently fall back to a full-bleed gradient+monogram placeholder
because there's no real cover extraction for them yet. DesignTokens.swift
is the single source of truth for colors/type/spacing — an indigo-violet
accent, warm dark/light backgrounds, serif headers. BookDetailView still
shows a plain format-icon placeholder cover (not matted) and hardcoded
fake tags ["Fiction", "Science Fiction"] — both need fixing in this phase.
Everything today operates on `DiscoveredFile` (raw scan result, no real
metadata) — there is no persisted library yet, so nothing survives a
relaunch; a "rescan" recomputes the whole grid from disk every time.

Phase 2 — Import & Metadata — turns that raw scan into a real, persistent
library:

1. Bump the deployment target to macOS 14 (project.yml:
   `options.deploymentTarget.macOS` and `targets.Stoa.settings.base.
   MACOSX_DEPLOYMENT_TARGET`, both to "14.0") — needed for SwiftData, which
   is the right call here (built into the OS, no extra package, versus
   GRDB). Re-run `xcodegen generate` after.

2. Add two Swift Package dependencies to project.yml's `packages` +
   target `dependencies` (then `xcodegen generate`):
   - EPUBKit (https://github.com/witekbobrowski/EPUBKit) for EPUB
     metadata/manifest/cover parsing.
   - ZIPFoundation (https://github.com/weichsel/ZIPFoundation) for reading
     CBZ archive entries — don't hand-roll a zip reader or shell out to
     /usr/bin/unzip, this is a well-tested standard choice.

3. Convert `Book` (Sources/Stoa/Models/Book.swift) from a plain struct to
   a SwiftData `@Model` class. Keep its existing fields (title, author,
   format, sourceURL, libraryURL, coverImagePath, addedAt, tags,
   readingProgress) — this struct was deliberately shaped for exactly this
   in Phase 1, don't redesign it. Add a `contentHash: String` field for
   dedup (see step 5).

4. Create `LibraryStore` (Sources/Stoa/Services/LibraryStore.swift): owns
   the SwiftData `ModelContainer`/`ModelContext`, and the "Library folder"
   location — default this to `~/Documents/StoaLibrary` for now (Phase 4
   makes this configurable between iCloud Drive / Google Drive; don't
   build that picker yet, just isolate the path behind one property so
   Phase 4 is a small change). Expose `@Published var books: [Book]`
   (LibraryStore itself should be an `ObservableObject` / `@MainActor`,
   same pattern as ScannerService) plus `add(_:)`, `remove(_:)`,
   `contains(hash:) -> Bool`, and `updateTags(for:tags:)`.

5. Create `ImportPipeline` (Sources/Stoa/Services/ImportPipeline.swift)
   that, given a `DiscoveredFile`, produces a `Book`:
   - Compute a SHA256 content hash of the file first (CryptoKit, built
     in — no package needed). If `LibraryStore.contains(hash:)` is already
     true, skip the file entirely — this is the dedup check, and it means
     a file that got renamed or moved doesn't get re-imported as a
     duplicate.
   - EPUB: EPUBKit for title/author/language + cover image data.
   - PDF: PDFKit — title from document metadata, falling back to the
     filename if metadata has none; cover = a thumbnail rendered from
     page 1 (you can factor this out of CoverThumbnailCache's existing
     `renderPDFThumbnail` rather than duplicating that logic — that
     in-memory cache is for the grid's live display; ImportPipeline needs
     to additionally persist a copy to disk, see next bullet).
   - CBZ: ZIPFoundation — find the first image entry in filename order,
     that's the cover; use the filename (minus extension) as the title.
   - For EPUB and CBZ, save the extracted cover image to disk as a JPEG
     under the Library folder (e.g. `StoaLibrary/Covers/<hash>.jpg`),
     and set `Book.coverImagePath` to that relative path. PDFs don't need
     a saved cover file — MattedCoverView already renders PDFs live from
     CoverThumbnailCache, keep that as-is, just leave `coverImagePath`
     nil for PDFs.
   - Do NOT move or copy the original source file into the Library folder
     in this phase — PLAN.md's open question about copy-vs-reference
     stays open; `Book.sourceURL` continues to point at wherever the file
     already lives, `Book.libraryURL` stays nil for now. Keep that
     decision easy to change later (i.e. still copy/persist cover art
     images, just not the source ebook file itself).

6. Wire scanning into import: after `ScannerService.scan()` completes,
   for each `DiscoveredFile` not already in the library (by content hash),
   run it through `ImportPipeline` and add the resulting `Book` to
   `LibraryStore`. Do this somewhere sensible — either ContentView's
   `.task` block driving both scan and import in sequence, or a small
   coordinator — and show a progress indicator while importing runs (the
   grid should already show whatever's in LibraryStore immediately, with
   new books appearing as they finish importing, not a blocking spinner
   that hides everything).

7. Update the UI to read from `LibraryStore.books` (real `Book` records)
   instead of `scanner.discoveredFiles` (raw `DiscoveredFile`) for
   anything the user sees as "the library" — the grid, the hero band, the
   detail view, the sidebar's format/folder filtering. Concretely:
   - `HeroBand`, `BookCoverTile`, and `MattedCoverView` currently take a
     `file: DiscoveredFile` — change them to take a `book: Book` instead.
     `MattedCoverView`'s matted-vs-full-bleed branch was written as "PDF
     gets matted, everything else is full-bleed placeholder" specifically
     because EPUB/CBZ had no real covers yet — now that they do, EPUB/CBZ
     with a non-nil `coverImagePath` should render that real image
     full-bleed (it's genuine cover art, no matting needed), and only
     fall back to the gradient+monogram placeholder if the cover image
     is missing or fails to load. PDF keeps the exact matted treatment
     as-is.
   - `BookDetailView` currently takes `file: DiscoveredFile` and shows a
     plain icon-on-gradient placeholder cover — switch it to take a
     `book: Book` and reuse `MattedCoverView` for its cover section too
     (same treatment as the grid, just larger), instead of the separate
     `coverGradient(for:)` placeholder it has now.
   - Replace `BookDetailView`'s hardcoded `["Fiction", "Science Fiction"]`
     tags with `book.tags`, plus simple add/remove UI (a text field +
     "Add" button, and a small "x" on each tag pill to remove it),
     calling `LibraryStore.updateTags(for:tags:)`.
   - Sidebar format/folder filtering and search currently filter
     `DiscoveredFile` — move that filtering logic to operate on `Book`
     instead (same rules: format match, or folder-path prefix against
     `book.sourceURL`).
   - `NavigationLink`/`.navigationDestination` currently route on
     `DiscoveredFile` — switch the value type to `Book` (it'll need
     `Identifiable`/`Hashable`, which SwiftData `@Model` gives you for
     free via its persistent identifier plus `Hashable` conformance you
     add).
   Keep every visual detail exactly as it is today — hero band layout,
   matted-cover shadow/badge/skeleton, sidebar styling, accent color,
   Settings — this step is a data-source change, not a redesign.

8. Add a sort menu to the toolbar (title / author / recently added /
   format) operating on `LibraryStore.books` — mentioned in the original
   plan, not built yet.

9. Keep ScannerService, SettingsView, and folder management working
   exactly as they are — they're the scan/permissions layer, Phase 2 only
   touches what happens after a scan.

Build and run after each numbered step, not just at the end — steps 3-4
(SwiftData model + store) are the riskiest part to get wrong, verify that
compiles and a book can be added/persisted before moving to the import
pipeline. Commit to git with a clear message once scan → import → real
persisted library with real covers is working end-to-end, and again after
relaunching the app to confirm the library survives a restart (this is the
actual point of Phase 2 — right now nothing does).
```

---

## Prompt 1.5 — Apple-quality visual design pass, exact tokens (do this right after Prompt 1)

```
Give the library grid a real visual design pass, matching a specific set of
design tokens below exactly (these came from an approved design mockup, not
a vague "make it nicer" ask). Stay within SwiftUI + AppKit interop, no new
dependencies.

DESIGN TOKENS

Colors (define these once, e.g. as a Theme enum or Color extension, and use
everywhere instead of ad hoc values):
  - Background: light #F4F3F1, dark #1E1E20 -> but prefer the semantic
    Color(nsColor: .windowBackgroundColor) if it renders close to these;
    only hardcode if you need the exact tone.
  - Accent (selection, active nav item, progress bars, primary button):
    a refined indigo-blue, approx #4F63D2 (roughly oklch(0.52 0.14 255)).
    Define as Color("AccentIndigo") in the asset catalog with light/dark
    variants, and set it as the app's accentColor.
  - Text: use SwiftUI's semantic .primary / .secondary / .tertiary
    everywhere -- don't hardcode text colors, they already track light/dark
    correctly and are close to the mockup's ink colors.
  - Hairlines/dividers: default Divider() / .separator is correct, no
    custom color needed.

Sidebar & toolbar:
  - Sidebar and toolbar use `.regularMaterial` (this is what
    NavigationSplitView's sidebar already renders -- don't override it with
    a solid background).
  - Sidebar width ~220pt, row height ~30pt (padding: 6pt vertical, 8pt
    horizontal), row corner radius 6pt, 9pt gap between icon and label,
    13pt font, .medium weight for section labels, .semibold for the
    selected "Library" row with the accent color and an accent-tinted
    background (accent at ~12% opacity).
  - Section labels ("WATCHED FOLDERS", "COLLECTIONS") are 11pt, .semibold,
    positive letter-spacing (~0.02em via .tracking(0.2)), .tertiary color,
    uppercase.

Library grid (ContentView):
  - LazyVGrid, adaptive columns, minimum 150pt, gap 20pt both directions.
  - Each cover: 2:3 aspect ratio RoundedRectangle, 6pt corner radius, filled
    with the cover image (or, until Phase 2 wires real covers, a colored
    gradient placeholder). Shadow: two-layer -- a tight
    `.shadow(color: .black.opacity(0.10), radius: 1, y: 1)` plus a soft
    `.shadow(color: .black.opacity(0.28), radius: 14, y: 10)` (heavier in
    dark mode: bump the soft shadow to ~0.4 opacity).
  - Format badge (EPUB/PDF/CBZ) as a small pill in the top-right corner of
    the cover: 9pt bold, positive tracking, white text at 75% opacity, on a
    black-at-22%-opacity rounded background, 2pt vertical / 6pt horizontal
    padding.
  - Title below cover: 13pt .semibold, .primary, 2-line max. Author: 12pt,
    .secondary.
  - Hover: scale to 1.015 and lift -3pt on the Y axis, animated with
    `.animation(.spring(response: 0.35, dampingFraction: 1.0), value: isHovered)`
    -- not a linear/eased transition.
  - Section headers ("Currently Reading", "Recently Added"): 26pt, .bold,
    tight tracking (`.tracking(-0.5)` or similar negative value at this
    size), .primary color. A trailing item count in 13pt .tertiary next to
    "Recently Added".
  - "Currently Reading" section: same cover treatment plus a 3pt-tall
    rounded progress bar directly under the cover (track at 8% black
    opacity, fill in the accent color, width = reading percentage).

Book Detail (new BookDetailView, replacing the plain "Open"/"Read" button
flow):
  - Two-column layout: cover on the left (220pt wide, 2:3 aspect, 10pt
    corner radius, heavier shadow than grid covers -- radius ~24-40,
    y ~24, opacity ~0.4), metadata on the right.
  - Title 32pt .heavy/.bold, tight tracking, .primary. Author 16pt,
    .secondary, directly below.
  - Tag pills row: 12pt .semibold, .secondary text, on a 6%-opacity black
    (8% in dark mode) rounded-capsule background, ~4pt vertical / 10pt
    horizontal padding, 8pt gaps between pills.
  - Primary action button ("Resume Reading" / "Read"): filled accent
    background, white text, 14pt .semibold, 10pt vertical / 22pt
    horizontal padding, 8pt corner radius. On hover: lift -1pt Y with a
    accent-tinted shadow appearing underneath, spring-animated
    (`response: 0.2-ish`, snappy). Secondary button ("Show in Finder"):
    outlined, 1pt hairline border, transparent background, .secondary text.
  - Below the buttons, a 2x2 metadata grid (Format+size, Added date,
    Location/folder, Progress-with-inline-bar) -- 11pt .semibold uppercase
    .tertiary labels with positive tracking, 14pt .primary values.

General craft:
  - Every spacing value comes from the 4/8pt rhythm (4, 8, 12, 16, 20, 24,
    32) -- nothing arbitrary.
  - Font throughout: the system font (San Francisco) via semantic styles
    or explicit sizes as specified above -- no custom font unless I ask.
  - Verify both light and dark appearance: none of the above should
    require different code paths except where a specific dark-mode value
    is called out (accent, shadows).

Build and run after this pass. This should look like it belongs next to
Apple Books or Apple Music -- deliberate hierarchy, real shadows and
materials, not default SwiftUI list styling.
```

---

## Prompt 2 — Phase 3: Reader (EPUB only — rewritten, supersedes the original)

PDF and CBZ readers were already implemented directly (not by you) and are
committed. This prompt is scoped to the one remaining piece: the EPUB reader.
Read the existing code before writing anything — the patterns below already
exist in the codebase and your EPUB reader should match them, not invent new
ones.

```
Continuing Stoa at ~/Documents/Stoa (see PLAN.md).
Phase 1 (scanning), Phase 2 (import/metadata + SwiftData library), and the
PDF + CBZ halves of Phase 3 are done and committed. Book is a SwiftData
@Model now (Sources/Stoa/Models/Book.swift). Look at these two files first —
your EPUB reader should follow the exact same shape:

- Sources/Stoa/Views/PDFReaderView.swift
- Sources/Stoa/Views/CBZReaderView.swift

Both are presented as a `.sheet` from BookDetailView's `readerSheet`
@ViewBuilder (see BookDetailView.swift — there's already an `.epub: EmptyView()`
case there for you to replace), both take `let book: Book` plus
`@EnvironmentObject private var library: LibraryStore`, both have a header
(title, page indicator, close button) built from DesignTokens.serifFont/
sansFont/Spacing/surface — reuse that exact header pattern rather than
restyling, and both persist reading position via
`library.updateProgress(for: book, progress:)` — the same method you'll call
here (0.0–1.0, based on how you define "position" for EPUB — see below).

Build Sources/Stoa/Views/EPUBReaderView.swift:

1. EPUBKit is already a dependency (resolved at 0.5.0, see
   Stoa.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved)
   and is already used for metadata extraction in
   Sources/Stoa/Services/ImportPipeline.swift (`EPUBDocument(url:)`,
   `.title`, `.author`, `.cover`) — read that file first to see the exact
   API surface already proven to compile in this project. Use EPUBKit's
   manifest/spine to get the ordered list of chapter HTML resources and
   their file URLs (EPUBKit unpacks the EPUB to disk internally — inspect
   the actual EPUBDocument properties in Xcode's Quick Help / jump-to-
   definition before guessing at method names, since the exact spine/
   manifest API isn't proven yet in this codebase the way the metadata
   fields are).
2. Render one chapter at a time in a `WKWebView` (wrapped via
   `NSViewRepresentable`, same pattern as PDFReaderView's
   `PDFKitRepresentedView` — a private struct with a Coordinator).
   Load each chapter's HTML file directly via
   `webView.loadFileURL(chapterURL, allowingReadAccessTo: ...)` so the
   chapter's local CSS/images resolve. No custom pagination — chapter-level
   navigation is enough for v1 (forward/back chapter, not forward/back
   "page" within a chapter).
3. Header: same layout as PDFReaderView/CBZReaderView (title left, close
   button right). Instead of "Page X of Y", show "Chapter X of Y" where Y is
   spine.count.
4. Footer: prev/next chapter buttons (disable at the ends, same disabled-
   state pattern as CBZReaderView's footer), matching CBZReaderView's
   footer layout (buttons + a thin accent progress capsule) rather than
   inventing new chrome.
5. Progress: since there's no natural "page" for EPUB, use
   `chapterIndex / (spine.count - 1)` as the progress value passed to
   `library.updateProgress`, same idea as the other two readers' page-index
   math. On open, resume at
   `Int(round(book.readingProgress * (spine.count - 1)))` if
   `book.readingProgress` is set, same pattern PDFReaderView/CBZReaderView
   use in their `load()`/`openArchive()`.
6. Update BookDetailView.swift: in `readerSheet`, replace the `case .epub:
   EmptyView()` with `EPUBReaderView(book: book).environmentObject(library)`.
   In `buttonsRow`, the primary button already branches on
   `book.format == .pdf || book.format == .cbz` for "Read" vs "Open" — extend
   that condition to include `.epub` now that there's a reader for it, so all
   three formats say "Read" and open the in-app sheet, and none of them fall
   through to `NSWorkspace.shared.open` anymore by default.
7. Don't touch PDFReaderView.swift, CBZReaderView.swift, ScannerService,
   LibraryStore, ImportPipeline, or the signing/entitlements setup.

Build and run. Test with a real EPUB from the library grid — verify chapter
navigation both directions and that closing and reopening the book resumes
at roughly the same chapter. Commit when it works.
```

---

## Prompt 3 — Phase 4: Backup/Sync + Polish

```
Continuing Stoa at ~/Documents/Stoa (see PLAN.md).
Phases 1-3 (scan, import/metadata, reader) are done.

Now build Phase 4 — Backup/Sync + Polish:

1. In SettingsView, add a way to choose where the Library folder lives:
   - Detect the iCloud Drive folder if available (typically
     ~/Library/Mobile Documents/com~apple~CloudDocs) and offer
     "iCloud Drive/Stoa" as the default option.
   - Let Sam pick any other folder via NSOpenPanel as a fallback (this covers
     Google Drive's local sync folder — no Google API integration, just
     pointing at whatever folder Google Drive already syncs on her Mac).
   - On change, move the existing Library folder contents to the new location
     (don't lose data; confirm with an alert before moving).
2. Add tags/collections: a simple tag field on Book, a way to add/remove tags
   from Book Detail, and a sidebar filter list in the library grid (similar to
   the Watched Folders sidebar section already there).
3. Polish pass:
   - Proper empty states (no books yet, no search results, folder access
     denied).
   - An app icon (ask me for one, or use a simple SF Symbols-based placeholder
     if I don't provide one — don't spend excessive time generating icon art).
   - Sensible window sizing/restoration, keyboard shortcuts for common actions
     (Cmd+F for search, arrow keys in the reader).
   - Review PLAN.md's "Open Questions" section and make sure each one has
     actually been resolved by what's been built; update the doc to reflect
     the final decisions.
4. Do a full pass: fresh scan on a clean library folder, import a handful of
   real EPUB/PDF/CBZ files, read each format, change tags, switch the sync
   folder, quit and relaunch to confirm everything persists correctly.

Commit as v1.0 once this pass is clean.
```

---

## Notes for whoever runs these

- These prompts intentionally don't name a specific coding agent/tool — paste
  them into whatever agentic coding tool you're using locally.
- Do these **in order** — each phase assumes the previous one compiles and
  runs.
- If an agent goes off-script (rewrites unrelated files, changes the
  architecture), stop it and point it back at PLAN.md and the specific
  prompt — the scope is intentionally tight per phase.
- `project.yml` (XcodeGen) is the source of truth for the Xcode project, not
  a checked-in `.xcodeproj` — anyone regenerating the project after a fresh
  clone runs `xcodegen generate` first.

---

## Prompt — Fix: app re-asks for folder permission on every launch

```
Stoa (~/Documents/Stoa) keeps re-prompting for Documents/Desktop/Downloads
folder access every time it's launched, even when nothing changed. Root
cause: project.yml has no DEVELOPMENT_TEAM / CODE_SIGN_IDENTITY set, so
Xcode is using "Sign to Run Locally" (ad-hoc signing). Ad-hoc builds get a
slightly different code signature each rebuild, and macOS's TCC permission
system ties folder-access grants to that signature — so every rebuild
looks like a brand-new app and it asks again.

I have a paid Apple Developer account, so fix this properly rather than
with a throwaway personal-team signature:

1. Open Stoa.xcodeproj in Xcode (regenerate first with `xcodegen generate`
   if needed). Go to the Stoa target → Signing & Capabilities.
2. Turn on "Automatically manage signing" and select my paid Developer
   Team (not "None", not a personal free team). Note the Team ID Xcode
   shows (looks like "AB12CD34EF").
3. Add that team id to project.yml so it survives future `xcodegen
   generate` runs — under targets.Stoa.settings.base add:
     DEVELOPMENT_TEAM: <the paid team ID from step 2>
     CODE_SIGN_STYLE: Automatic
   (leave CODE_SIGN_IDENTITY unset — Automatic will pick "Apple Development"
   for local runs; that's correct and enough to stabilize TCC).
4. Clear out the old ad-hoc-signed permission grants that are currently
   confusing macOS, from Terminal:
     tccutil reset SystemPolicyDocumentsFolder com.sam.stoa.Stoa
     tccutil reset SystemPolicyDesktopFolder com.sam.stoa.Stoa
     tccutil reset SystemPolicyDownloadsFolder com.sam.stoa.Stoa
   (bundle id is com.sam.stoa.Stoa per project.yml's bundleIdPrefix — check
   Signing & Capabilities if it's actually something slightly different).
5. Product → Clean Build Folder, then rebuild and run once. Approve the
   three folder prompts this one time.
6. Quit and relaunch Stoa two or three times without rebuilding, and again
   after a small unrelated code change + rebuild, to confirm it does NOT
   re-prompt anymore. If it still does, check that DEVELOPMENT_TEAM in
   project.yml actually matches what Xcode has under Signing &
   Capabilities — a mismatch there will keep the signature unstable.

Don't touch ScannerService.swift or the entitlements file — this is purely
a signing/project-settings fix. (Separately, later — once the app is
otherwise finished — we can go further and do a "Developer ID Application"
signed + notarized release build so Gatekeeper stops requiring
right-click-to-open on first launch too. Not needed for this fix, just
flagging it's available since there's a paid account now.)
```

---

## Prompt — Correction: signing resolves to ad-hoc from the CLI

```
Stop — don't create a new "Mac Development" certificate. Apple retired
that as a separate cert type years ago; "Apple Development" (which is
already in the keychain, W3YMY5PN2X) is the correct unified certificate
for macOS too. Making another one won't fix this.

The real cause: when CODE_SIGN_STYLE=Automatic is resolved by `xcodebuild`
run from the command line (not Xcode.app itself), it needs explicit
permission to talk to the Developer Portal to create/fetch the
provisioning profile automatic signing depends on. Without that
permission it fails quietly and falls back to ad-hoc ("-") instead of
throwing a real error — which is exactly the symptom we're seeing.

Fix, in order of preference:

1. Add `-allowProvisioningUpdates` to whatever `xcodebuild` command
   builds/runs Stoa. E.g.:
     xcodebuild -project Stoa.xcodeproj -scheme Stoa -configuration Debug \
       -allowProvisioningUpdates build
   That flag is what lets automatic signing actually create the profile
   from the CLI instead of silently giving up.

2. If that alone doesn't do it: open Stoa.xcodeproj in Xcode.app itself
   (the GUI, not terminal) once, go to Signing & Capabilities, and just
   let it sit on the Stoa target for a few seconds — Xcode.app resolves
   automatic signing more reliably than the CLI and will create a local
   "Xcode Managed Profile" on disk under
   ~/Library/MobileDevice/Provisioning Profiles/. Once that profile
   exists locally, subsequent CLI builds with -allowProvisioningUpdates
   should find and reuse it consistently.

3. Sanity check regardless: confirm Xcode is actually signed into my
   Apple ID under Xcode → Settings → Accounts, and that account shows the
   paid team (W3YMY5PN2X) — automatic signing can't create profiles at
   all without that.

Note: Stoa's entitlements only set com.apple.security.app-sandbox to
false — no capability that actually requires a provisioning profile
(no iCloud, no push, no sandbox). So there's also a simpler fallback if
steps 1-3 keep fighting Xcode: since no real capability needs
provisioning, we could sign with a plain Developer ID identity and skip
automatic-signing profile resolution entirely — worth trying if this is
still stuck after step 1-2, but try the flag first since it's the
standard fix for this exact "resolves to ad-hoc from CLI" symptom.

After a successful build with a real identity (verify via `codesign -dv
--verbose=4 <path to Stoa.app>` — should show "Authority=Apple
Development: ..." not "Signature=adhoc"), rerun the tccutil reset +
relaunch test from the previous prompt to confirm folder permissions now
persist across rebuilds.
```

---

## Prompt — Real design pass: hero section + matted PDF covers

```
Stoa's library grid still reads as generic even with the current
shadow/rounding/badge treatment, because most scanned files are plain
business PDFs (specs, PRDs, screen maps) whose actual first page is a
flat white document — no framing fixes that. Two structural changes,
both shown in this mockup: https://claude.ai/code/artifact/39c9453d-7525-46ec-b266-ee34cc08df5c
(dark mode, matches our current palette — DesignTokens colors unchanged).

### 1. Continue Reading / Recently Added hero

Add a hero band above the format-grouped grid in ContentView's
detailContent, full width, ~140pt tall:

- Background: DesignTokens.surface, 18pt corner radius, 1px hairline
  border, plus ONE subtle radial accent glow behind it (accent color
  at ~10% opacity, large soft blur, positioned top-left of the band —
  this is the single "wow" moment for the screen, don't repeat it
  elsewhere).
- Left: the most recently modified file (scanner.discoveredFiles
  sorted by modifiedAt descending, first one) shown as a small matted
  cover (see #2 below), ~112pt wide, 2:3 aspect.
- Right: eyebrow label "Recently added" (11pt tracked uppercase,
  tertiary — matches existing sidebar section label style), then the
  title in serif 32pt semibold tight tracking, then format + relative
  date in 13pt secondary, then an "Open" button (accent-filled,
  9pt corner radius) that calls NSWorkspace.shared.open(file.url) —
  same action BookDetailView's openButton already uses.
- We don't have reading-progress data yet (that's Phase 3), so it's
  "Recently added" + "Open" for now, not "Continue reading" + "Resume"
  + a progress bar — the mockup shows the resume/progress variant
  because that's the end state once Phase 3 lands, but build the
  Recently Added version now. Structure it so swapping in progress
  tracking later is a small change (e.g. an enum HeroState: .recentlyAdded(file)
  vs .continueReading(file, progress) that the view switches on), not
  a rewrite.
- If discoveredFiles is empty, hide the hero entirely rather than
  showing an empty one.

### 2. Matted cover treatment for every PDF

Right now BookCoverTile.coverArt renders the real PDF thumbnail (or
gradient placeholder) full-bleed inside the rounded card. Change this
so PDFs always render as a "matted" card instead:

- Outer card: same per-book hashed gradient background that
  placeholderGradient already computes (keep using
  DesignTokens.placeholderGradient(for:) for the mat color — don't
  invent a new gradient system), same 2:3 aspect, same corner radius,
  same two-layer shadow as now.
- Inset "paper": a rectangle centered in the mat at 78% width / 84%
  height, corner radius ~4-5pt, background = a light warm paper tone
  (add DesignTokens.paper — light: NSColor(white/warm ~0.94), dark:
  same value works fine since the paper itself doesn't need to theme
  separately from the mat), its own small shadow (radius ~6, y~3,
  black 25%).
- The real PDF thumbnail (from CoverThumbnailCache, same async load
  you already have) renders INSIDE that inset paper rect, clipped to
  its rounded corners — not filling the whole outer card like now.
  If the thumbnail hasn't loaded yet or fails, show the paper rect
  with a few placeholder line-shapes (thin rounded bars) standing in
  for text, like a skeleton — same idea as the mockup's card grid.
- Format badge stays where it is now (top-right corner of the outer
  mat, not on the inset paper).
- This treatment applies to ALL PDFs uniformly — real cover-like PDFs
  and boring document PDFs alike. Don't try to detect which is which;
  the matting makes both look intentional, which is the point.
- EPUB/CBZ covers (once Phase 2 adds real cover extraction) should
  stay full-bleed as now — this matting is specifically because a raw
  PDF page isn't cover art. Leave BookFormat handling ready for that
  branch (full-bleed for epub/cbz, matted for pdf) even though epub/cbz
  don't have real thumbnails yet.

Keep everything else (hover spring, context menu, format badge
styling, section headers) as-is. Build and run after each of the two
pieces; this is a ContentView/BookCoverTile/DesignTokens change only,
don't touch ScannerService or the entitlements/signing setup.
```
