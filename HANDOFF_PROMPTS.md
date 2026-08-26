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

## Prompt 1 — Phase 2: Import & Metadata

```
I'm building a macOS SwiftUI app called Stoa, at
~/Documents/Stoa. Read PLAN.md and README.md in that folder for
full context. Phase 1 is done: ScannerService finds .epub/.pdf/.cbz files
across Documents/Desktop/Downloads + user-added folders, and there's a
placeholder flat-list UI (ContentView) plus a Book/DiscoveredFile model.

Now build Phase 2 — Import & Metadata:

1. Add EPUBKit as a Swift Package dependency (add it to project.yml's
   `packages` + target `dependencies`, then re-run `xcodegen generate`).
2. Create an `ImportPipeline` service (Sources/Stoa/Services/) that,
   given a `DiscoveredFile`, produces a `Book`:
   - EPUB: use EPUBKit to pull title, author, language, and cover image.
   - PDF: use PDFKit — title from document metadata (fall back to filename),
     cover = a thumbnail image rendered from the first page.
   - CBZ: unzip (Foundation's built-in Compression or a small zip reader),
     grab the first image entry as the cover, use the filename as the title.
   - Compute a content hash (e.g. SHA256 of the file) for dedup — skip files
     whose hash is already in the library.
   - Store the cover image on disk under the Library folder as a small JPEG/PNG,
     save its relative path on the Book record.
3. Create a `LibraryStore` backed by SwiftData (`@Model` on a persisted version
   of `Book`) that lives at a "Library folder" location — for now default this
   to `~/Documents/StoaSync` (Phase 4 will make this configurable
   between iCloud Drive / Google Drive). Books are copied into this folder on
   import (leave originals in place per the plan's open question).
4. Wire the scanner's `discoveredFiles` into the import pipeline: after a scan,
   files not already in the LibraryStore get imported automatically. Show
   progress in the UI (a simple progress indicator while importing).
5. Replace the flat-list ContentView with a real library grid view: covers,
   title/author underneath, search bar (already have `.searchable`), and a
   sort menu (title / author / recently added / format).
6. Keep everything else (ScannerService, SettingsView, folder management)
   working as-is — only extend, don't rewrite it unless something is actually
   broken.

Build and run after each major step. Commit to git with a clear message when
Phase 2 is working end-to-end (scan → import → grid view with real covers).
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

## Prompt 2 — Phase 3: Reader

```
Continuing Stoa at ~/Documents/Stoa (see PLAN.md).
Phase 1 (scanning) and Phase 2 (import/metadata + library grid) are done.

Now build Phase 3 — the in-app Reader:

1. Add a `ReaderView` (Sources/Stoa/Views/) that's shown when a
   book is opened from the library grid or Book Detail screen, dispatching by
   format:
   - PDF: use PDFKit's `PDFView` directly (AppKit interop via
     `NSViewRepresentable`) — page navigation, zoom, and a page-thumbnail
     sidebar if reasonable.
   - EPUB: render via `WKWebView` loading the EPUB's unpacked HTML content
     (EPUBKit gives you the manifest/spine); implement forward/back chapter
     navigation. Keep formatting simple for v1 — no need for custom
     pagination animations.
   - CBZ: a paged image viewer — swipe/arrow-key through the archive's images
     in order, fit-to-width, with a page counter.
2. Add a "Book Detail" screen (metadata, cover, an "Open"/"Read" button) that
   sits between the library grid and the reader, per the plan's architecture.
3. Track basic reading progress (current page / percentage) on the `Book`
   model and persist it via LibraryStore so reopening a book resumes roughly
   where you left off. Surface "Currently Reading" somewhere reasonable (a
   filter or a section at the top of the grid) — this was an open question in
   the plan; make the simplest reasonable call and note it in PLAN.md's open
   questions section as resolved.
4. Don't break the Phase 1/2 scan → import → grid flow.

Build and run after each reader type is wired up. Commit when all three
formats open and display correctly.
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
