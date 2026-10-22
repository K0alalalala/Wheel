<p align="center"><img src="Resources/AppIcon-preview.png" width="128" alt="Wheel icon"></p>

# Wheel

A menu-bar utility for macOS. Start dragging a file and hold **Shift**: a radial menu opens under the cursor. Drop the file on a slice to convert or edit it. The result is saved next to the original, which is never modified.

- **Convert wheel**: slices depend on the file type, in a fixed order.
  - Images: PNG, JPG, WEBP, HEIC, TIFF, AVIF, BMP, PDF
  - PDF: JPG, PNG, TIFF, TXT, DOCX, RTF
  - Documents (docx, txt, md, html, rtf): PDF, DOCX, TXT, RTF, HTML
  - Video: MP4, MOV, GIF, WEBM, M4A, MP3
  - Audio: M4A, MP3, WAV, AIFF, FLAC
- **Edit wheel** for images: Compress, Metadata, Edit, Annotate, Add BG, Crop, Redact.
- **Edit wheel** for PDFs (20 tools; the first 8 show on the wheel, **All Tools** opens a searchable launcher with the rest):
  - **Pages:** Organize (drag to reorder, rotate, duplicate, insert blank, delete), Delete pages, Extract pages (one file or one per page), Split (every N pages or at chosen pages), Merge (several PDFs and images into one), Rotate, Reverse.
  - **Stamps:** Watermark (text, size, opacity, angle, colour, centred or tiled) and Page numbers (6 positions, 3 styles, start number, skip first page), both with a live preview.
  - **Security:** Protect (open password, block printing or copying) and Unlock.
  - **Clean-up:** OCR (makes scans searchable on-device with Vision), Flatten, Grayscale (text stays vector), Trim margins, Clean (removes annotations, keeps links), 2-Up, Compress, Metadata.
- **Combine wheel** (drag two or more files): **To PDF** (PDFs, images and documents in one PDF, with an order you set), **Zip** (one drop → `Archive.zip`), **Archive** (ZIP, TAR.GZ, 7Z or RAR, with name and compression level), **Stitch** (images into a strip, row or grid), **GIF** (images into an animation: speed, size, loop, boomerang) and **Join** (audio/video clips back to back). Mixed drags, like a PDF and a photo, or drags with folders, open straight on this wheel. Same-type drags open on Convert, so batch conversion stays one drop away.
- To switch wheels (Convert → Edit → Combine), rest on the centre hub (delay adjustable) or **force click** it on a Force Touch trackpad. Settings lets you pick hover, force click, or both.
- **Fully customizable** (Settings → Appearance): size, hub size, gaps, roundness, rotation, max slices, highlight colour (Wheel orange, system accent, or any colour), glass material and tint, filled/glass/outline slices, label style/font/size/caps, appear animation, hover zoom, bounciness and haptics. There's a live preview you can hover, plus 9 presets (Classic, Compact, Big & Bold, Liquid, Minimal, Neon, Terminal, Bubblegum, Native).
- **Slices tab:** drag to reorder each wheel and toggle slices on/off.
- **Theme files:** export your setup as a `.wheeltheme` file to share or switch between.
- Output names follow the source, e.g. `Page 001.pdf` → `Page 001.jpg` → `Page 001 Cropped.jpg` → `Page 001 Cropped With Background.png`. If a name is taken, ` 2`, ` 3`… is added.

No network calls, no telemetry.

## Install

1. Download `Wheel-x.y.z.dmg` from Releases and drag **Wheel** into **Applications**.
2. Open it. Wheel isn't notarized by Apple, so macOS blocks the first launch:
   - **macOS 15+:** System Settings → Privacy & Security → scroll down → **Open Anyway**.
   - **macOS 14:** right-click Wheel → **Open** → **Open**.
3. A ◎ icon appears in the menu bar. Wheel turns on **launch at login** the first time it runs from Applications; switch it off in Settings.

Wheel needs macOS 14 or later and runs natively on Apple Silicon and Intel.

## Build & run

Needs macOS 14+ and Xcode 15+ (Swift 5.9+).

```bash
scripts/build-app.sh          # builds build/Wheel.app (release)
open build/Wheel.app
```

The script uses `/Applications/Xcode.app` even if `xcode-select` points at the Command Line Tools. Other entry points:

```bash
swift test                                   # unit tests (conversions, edits, naming, registry, hit-testing)
xcodebuild -scheme Wheel -destination 'platform=macOS' build
open Package.swift                           # work on it in Xcode
```

Launch at login switches on automatically the first time Wheel runs from `/Applications`. It is skipped for builds run from elsewhere, so a dev build never replaces the login item.

### Making a release

```bash
scripts/make-dmg.sh           # universal build → privacy check → build/Wheel-<version>.dmg (+ .sha256)
```

The version comes from `Resources/Info.plist`, or from a `v1.2.3` git tag when building exactly that commit. Upload the `.dmg` and paste its SHA-256 into the release notes.

## Permissions

Drag detection needs **no permissions**. It polls the mouse button and modifier keys and watches the system drag pasteboard.

**Accessibility** is optional. It lets **Esc** close the wheel mid-drag, because global key monitoring needs it. The first-run screen links to the right pane: System Settings → Privacy & Security → Accessibility. The build is ad-hoc signed, so after a rebuild macOS may ask again. If Esc stops working, remove and re-add Wheel in that list.

## Logs & crash reports (local only)

Wheel keeps a small diagnostic log so that when something goes wrong, there's a record of what happened. **It never leaves your Mac.** Wheel has no network code at all, and nothing is uploaded, synced or "phoned home".

**Where:** `~/Library/Logs/Wheel/`. It's also visible in Console.app under *Log Reports*.

| File | What's in it |
|---|---|
| `wheel.log` (+ `wheel.1.log`, `wheel.2.log`) | Launch info (Wheel and macOS version, which optional tools are installed), when the wheel opens, which slice you dropped on, how each action went and how long it took, and errors. |
| `crash-<date>.txt` | If Wheel crashes, a short summary of macOS's own crash report: exception, reason and the crashing thread's stack. Registers, other threads and other apps are left out. |

**What's never logged:** file contents, passwords (Protect/Unlock), full paths, your home folder, or your name. File names show as `‹pdf›`, `‹jpg›` unless you turn on *Include file names*.

**How it's protected:** the folder is readable only by you (permissions `700`, files `600`). It's excluded from Time Machine, and capped at three ~1 MB files. Entries older than 14 days delete themselves, and the 10 newest crash summaries are kept.

**Opting out:** Settings → General → Diagnostics → turn off *Keep a local diagnostic log*. Wheel then writes nothing. Existing logs stay until you click **Delete Logs…**.

**Getting help with a problem:**
- **Share with a person:** click **Copy Recent Log** (the last 300 lines plus the newest crash summary), read it over, and paste it into an issue.
- **Share with an AI coding agent:** ask it to read `~/Library/Logs/Wheel/`. Claude Code, Codex and others can open the folder directly, and `AGENTS.md` tells them how to use it.
- **Full macOS report:** macOS also keeps Wheel's complete crash reports in `~/Library/Logs/DiagnosticReports/Wheel-*.ips`.

## Optional tools (Homebrew)

These work without extra installs: all image formats except WEBP output, PDF ↔ images/TXT/DOCX/RTF, DOCX/RTF/HTML/TXT/MD → PDF/DOCX/TXT/RTF/HTML, MP4/MOV/M4A export, and WAV/AIFF from audio.

| Tool | Unlocks | Install |
|---|---|---|
| `cwebp` | WEBP output (ImageIO reads WebP but can't write it) | `brew install webp` |
| `ffmpeg` | MP3, FLAC, GIF, WEBM, and video → WAV/AIFF. Also a WEBP fallback | `brew install ffmpeg` |
| `pandoc` | Better Markdown rendering | `brew install pandoc` |
| `7zz` | 7Z archives | `brew install sevenzip` |
| `rar` | RAR archives (RAR is proprietary; WinRAR's free command-line tool) | `brew install --cask rar` |

Slices whose backend is missing appear greyed out and show the install command on hover. **Settings → Tools** shows what was found.

## Testing by hand

1. **Shell and detection.** Launch the app; a ◎ icon appears in the menu bar. Drag any file in Finder, then press Shift: the wheel appears under the cursor. Release Shift: it hides. Press Shift again: it returns. Drop anywhere off the wheel: nothing happens. Without Shift, drags behave normally.
2. **Convert.** Shift-drag a PDF onto **JPG**. A toast reads "Converting to JPG · 1 of 1 saved", then "Saved Page 001.jpg". Click the toast to reveal the file. A multi-page PDF produces a folder `Name JPG/` with numbered pages, or one multipage TIFF. Shift-drag a PNG and the PNG slice is absent. Drag several files to batch-convert them, and click the toast's **X** to cancel a long batch.
3. **Edit.** Shift-drag a JPG and hover the hub until it says EDIT. Then:
   - Drop on **Crop**: drag the handles, try 1:1 and 16:9, type W/H, then Apply → `… Cropped.jpg`.
   - **Add BG**: pick swatches, adjust the sliders and ratio, then Save → `… With Background.png`.
   - **Compress**: shows the size before and the estimated size after.
4. **The rest.**
   - **Metadata**: lists EXIF/GPS and saves `… No Metadata.jpg`. The orientation is kept.
   - **Redact**: draw boxes and save. The pixels under each box are black in the output.
   - **Annotate**: pen, arrow, box, text.
   - **Edit**: brightness, contrast, saturation, rotate, flip.
   - **Settings** (menu bar → Settings…): change the trigger key, hide slices, pin a default format to the top slot.

For checking visuals without dragging (debug builds only: `scripts/build-app.sh debug`):

```bash
build/Wheel.app/Contents/MacOS/Wheel --preview wheel ~/Desktop/photo.jpg edit 3 --snapshot /tmp/wheel.png
build/Wheel.app/Contents/MacOS/Wheel --preview edit.crop ~/Desktop/photo.jpg
```

## Architecture

```
Sources/
  WheelCore/            library, no app UI: reusable by future front ends
    Actions/
      FileAction.swift      FileAction protocol, FileKind, WheelMode
      ActionRegistry.swift  ActionProvider protocol, registry, Preferences
      ConvertActions.swift  ConvertAction + per-kind target lists
    Engines/            ImageEngine, PDFEngine, DocumentEngine, MediaEngine, ExternalTools, OutputPath
  Wheel/                the menu-bar app
    App/                AppDelegate (menu bar), ActionRunner (toast + batch), Settings
    Drag/DragMonitor    file-drag + modifier detection
    Wheel/              WheelPanel (NSPanel + NSDraggingDestination), WheelView, WheelGeometry
    Editors/            one file per edit tool + EditToolsProvider
    UI/                 glass materials, editor window, toast, settings, onboarding
Tests/WheelTests/       engine, naming, registry, editor-math tests
```

How a drop flows: `DragMonitor` sees a file drag with Shift held → `WheelPanel` shows at the cursor → `ActionRegistry.slices(for:mode:)` picks slices → the drop on a slice goes to `ActionRunner.run` → `FileAction.run` writes new files beside the source → toast.

### Extending

**A new conversion format.** Add the extension to `ConvertAction.targets[kind]` and handle it in the matching engine.

**A new edit tool.** Write a `FileAction` (set `isInteractive` and present an editor with `EditorWindow.present`), then add it to `EditToolsProvider.tools`:

```swift
struct RemoveBackgroundAction: FileAction {
    let id = "edit.removebg", title = "Cut Out", symbol = "person.crop.square", mode = WheelMode.edit
    func supports(_ url: URL) -> Bool { FileKind.of(url) == .image }
    func run(_ urls: [URL], progress: @escaping ProgressHandler) async throws -> [URL] {
        // write new files next to urls[0] with OutputPath.beside(...)
    }
}
```

**A whole family of actions** (e.g. a third wheel, or third-party tools). Conform to `ActionProvider` and call `ActionRegistry.shared.register(...)` at launch. The registry merges providers in registration order, caps the wheel at `maxSlices`, and applies the hidden/pinned settings for you.

**Another front end.** `WheelCore` has no dependency on the app. A Finder Quick Action, a Share extension or a CLI can link it and call the same actions.

Contract for every action: write new files only, never modify or delete inputs, throw `ActionError("clear message")` on failure, and respect task cancellation.

## Publishing safely

This repo is set up so publishing it doesn't leak who you are or anything about your Mac:

| Risk | What's in place |
|---|---|
| Your email in git history | This repo's git `user.email` is your GitHub **noreply** address. The privacy check fails if any commit uses another address. |
| Your username/home path inside the app | Release builds remap source paths and strip debug symbols. The privacy check scans the built binary. |
| Real name in a signing certificate | Builds are ad-hoc signed (anonymous). Developer ID signing is opt-in via `DEVELOPER_ID`. |
| Secrets committed by accident | None are needed. Signing and notarization credentials stay in your keychain, and the check scans for common key/token formats. |
| Files from this Mac in the DMG | The DMG is built from a clean staging folder with extended attributes stripped. |
| Tampered downloads | `make-dmg.sh` writes a SHA-256 checksum to publish alongside the DMG. |

Before every push:

```bash
scripts/privacy-check.sh
```

On GitHub, also turn on **Settings → Emails → "Keep my email addresses private"** and **"Block command line pushes that expose my email"**. Then a slip gets rejected by GitHub too.

**About notarization.** Without it, users click "Open Anyway" once. A $99/year Apple Developer ID removes that step, but the certificate shows your legal name (or a registered company's) to everyone who installs. If you decide to later:

```bash
xcrun notarytool store-credentials wheel-notary      # once; stored in your keychain
DEVELOPER_ID="Developer ID Application: … (TEAMID)" NOTARY_PROFILE=wheel-notary scripts/make-dmg.sh
```

**What the app itself does.** It makes no network connections and has no telemetry or analytics. Its diagnostic log stays in `~/Library/Logs/Wheel` (see [Logs & crash reports](#logs--crash-reports-local-only)). It reads only the files you drop on it and writes only new files next to them. External tools (ffmpeg, cwebp, pandoc) run with argument lists, never through a shell, so odd filenames can't inject commands.

<!-- credits:start (protected: see AGENTS.md) -->
## Credits

| | |
|---|---|
| **K0alalalala** | Visionary. Pasted one HTML file, typed "Continue", and asked for credits. Peak delegation. |
| **Claude** (Anthropic) | Wrote the code, the tests, the installer, the icon, and this joke. Then gave the human top billing. |
| **K0alalalala** | Executive Producer of Holding Shift. |
| **Claude** | Lead Wedge Geometrist. Has opinions about 2pt gaps. |

No humans were overworked in the making of this app. The same credits appear in the app under **About Wheel**.
<!-- credits:end -->

MIT licensed. See [LICENSE](LICENSE).

## Known limits

- Watermark, Page numbers, 2-Up and OCR redraw the pages, so form fields and comments aren't carried over (the visible page is). Flatten removes them on purpose.
- The drag must come from an app that puts real file URLs on the drag pasteboard (Finder, Desktop, most file managers). Mail attachments and Photos use file promises and aren't picked up.
- WEBP output and MP3/FLAC/GIF/WEBM need the Homebrew tools above.
