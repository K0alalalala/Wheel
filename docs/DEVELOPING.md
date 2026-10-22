# Developing Wheel

Everything you need to build, test, extend and release Wheel. If you're an AI coding agent, read [AGENTS.md](../AGENTS.md) first: it has the code layout, the rules, and recipes for common changes.

## Build & run

Needs macOS 14+ and Xcode 15+ (Swift 5.9+).

```bash
make run          # debug build of build/Wheel.app, then launch it
make test         # unit tests
make check        # tests + privacy scan + credits guard (what CI runs)
make dmg          # universal release build → build/Wheel-<version>.dmg (+ .sha256)
make screenshots  # re-render the README images into docs/images
make logs         # where the local log lives, and its last lines
```

The scripts use `/Applications/Xcode.app` even if `xcode-select` points at the Command Line Tools. You can also run `swift build` / `swift test` directly, run `xcodebuild -scheme Wheel -destination 'platform=macOS' build`, or `open Package.swift` to work in Xcode.

Launch at login switches on automatically the first time Wheel runs from `/Applications`. It's skipped for builds run from elsewhere, so a dev build never replaces the login item.

## How it fits together

```
Sources/WheelCore/   engines and the action system: no app UI, reusable by other front ends
Sources/Wheel/       the menu-bar app: drag detection, wheel, editors, settings, diagnostics
Tests/WheelTests/    XCTest: engines on real files, naming, registry, geometry, logging
scripts/             build-app, make-dmg, privacy-check, check-credits, make-icon
docs/images/         README screenshots (generated, see below)
```

[AGENTS.md](../AGENTS.md#layout) has the detailed map.

**How a drop flows:**
1. `DragMonitor` sees a file drag with the trigger key held.
2. `WheelPanel` appears under the cursor.
3. `ActionRegistry.slices(for:mode:)` picks the slices for these files.
4. The drop on a slice goes to `ActionRunner.run`.
5. `FileAction.run` writes new files beside the source, and the toast reports the result.

**Every action follows the same contract:** write new files only, never modify or delete inputs, throw `ActionError("clear message")` on failure, and respect task cancellation.

### Extending

- **Convert format:** add it to `ConvertAction.targets[kind]`, then handle it in the matching engine.
- **Image edit tool:** a `FileAction` with an editor via `EditorWindow.present`, listed in `EditToolsProvider.tools`.
- **PDF tool:** logic in `PDFTools`, then a `PDFBatchAction` or an editor in `Editors/PDF/`, listed in `PDFToolsProvider.tools`.
- **Multi-file action:** `mode = .combine`, decide when it's offered with `accepts(_:)`, and list it in `CombineProvider.tools`.
- **Whole new family:** conform to `ActionProvider` and register it at launch. The registry handles ordering, hiding and the slice cap.
- **Another front end** (Finder Quick Action, Share extension, CLI): link `WheelCore` and call the same actions.

```swift
struct RemoveBackgroundAction: FileAction {
    let id = "edit.removebg", title = "Cut Out", symbol = "person.crop.square", mode = WheelMode.edit
    func supports(_ url: URL) -> Bool { FileKind.of(url) == .image }
    func run(_ urls: [URL], progress: @escaping ProgressHandler) async throws -> [URL] {
        // write new files next to urls[0] with OutputPath.beside(...)
    }
}
```

## Testing by hand

1. **Detection.** Launch the app (◎ appears in the menu bar). Drag a file in Finder and press Shift: the wheel appears. Release Shift: it hides. Drop off the wheel: nothing happens. Without Shift, drags behave normally.
2. **Convert.** Shift-drag a PDF onto **JPG**. The toast shows progress, then "Saved …"; click it to reveal the file. A multi-page PDF gives a folder of pages.
3. **Edit.** Shift-drag a JPG, rest on the hub until it says EDIT, then try Crop, Add BG, Compress, Metadata, Redact, Annotate and Edit.
4. **PDF tools.** Shift-drag a PDF to the Edit wheel and open **All Tools**. Try Organize, Watermark, Protect then Unlock, and OCR on a scan.
5. **Combine.** Shift-drag a PDF and a photo together: the Combine wheel opens. Try To PDF and Zip, then Stitch and GIF with several photos.
6. **Settings.** Change the trigger key, try a preset, reorder slices, and export then import a theme.

Debug builds can render any wheel or editor without dragging:

```bash
build/Wheel.app/Contents/MacOS/Wheel --preview wheel ~/Desktop/photo.jpg edit 3 --snapshot /tmp/wheel.png
build/Wheel.app/Contents/MacOS/Wheel --preview edit.crop ~/Desktop/photo.jpg
build/Wheel.app/Contents/MacOS/Wheel --preview wheel a.pdf+b.jpg combine 0 --snapshot /tmp/combine.png
```

## README screenshots

`make screenshots` renders every image in `docs/images` from the app itself (`Sources/Wheel/App/ReadmeShots.swift`):
- **Content:** sample photos and a report are generated on the fly, and settings come from a throwaway defaults suite, so the images always show the default look.
- **Privacy:** nothing from your screen, files or preferences ends up in them.
- **When to run it:** after any visual change, then commit the updated JPEGs.

The real glass blur can't be captured offscreen, so screenshots use a close stand-in.

## Making a release

```bash
git tag v1.2.3      # optional: the build takes its version from a tag on the exact commit, else Info.plist
make dmg            # universal build → privacy check → build/Wheel-<version>.dmg + .sha256
```

Upload the `.dmg` and `.sha256` to a GitHub release, and paste the checksum into the notes.

## Publishing safely (for maintainers)

The repo is set up so publishing doesn't leak anything about the maintainer or their Mac:

| Risk | What's in place |
|---|---|
| Your email in git history | Use your GitHub **noreply** address for `user.email`. The privacy check fails if any commit uses another address. |
| Your username/home path inside the app | Release builds remap source paths and strip debug symbols. The privacy check scans the built binary. |
| Real name in a signing certificate | Builds are ad-hoc signed (anonymous). Developer ID signing is opt-in via `DEVELOPER_ID`. |
| Secrets committed by accident | None are needed. Signing and notarization credentials stay in your keychain, and the check scans for common key/token formats. |
| Files from your Mac in the DMG | The DMG is built from a clean staging folder with extended attributes stripped. |
| Tampered downloads | `make dmg` writes a SHA-256 checksum to publish alongside the DMG. |

Run `scripts/privacy-check.sh` before every push. On GitHub, turn on **Settings → Emails → "Keep my email addresses private"** and **"Block command line pushes that expose my email"**.

**About notarization.** Without it, users click "Open Anyway" once. A $99/year Apple Developer ID removes that step, but the certificate shows the developer's legal name (or a registered company's) to everyone who installs. To use it later:

```bash
xcrun notarytool store-credentials wheel-notary      # once; stored in your keychain
DEVELOPER_ID="Developer ID Application: … (TEAMID)" NOTARY_PROFILE=wheel-notary scripts/make-dmg.sh
```

## Credits are protected

The credits (in the README, `Sources/Wheel/Credits.swift`, `Info.plist`'s copyright and `LICENSE`) are guarded by `scripts/check-credits.sh` and CI. See [AGENTS.md → Protected](../AGENTS.md#protected).
