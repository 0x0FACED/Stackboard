# Development

[Back to Stackboard](../README.md) · [Maintainer release guide](releases.md)

This guide covers local builds, the source layout, icon generation, and development checks. Commands below are instructions to run from the repository root unless stated otherwise; they are not a record of checks or releases performed.

## Build from source

You need macOS, **full Xcode 26.4** or a compatible newer version, **Python 3**, and Git. Select the active Xcode through `xcode-select` or `DEVELOPER_DIR`; Command Line Tools alone are not sufficient.

```sh
git clone https://github.com/0x0FACED/stackboard.git
cd stackboard
bash scripts/package-release.sh 0.0.0
open dist/0.0.0/Stackboard.app
```

`0.0.0` is an example version for a local build. The [packaging script](../scripts/package-release.sh) builds a Universal app for Apple Silicon and Intel, signs it ad hoc, and verifies the resulting archive. No signing certificate or Apple Developer account is required, and the Xcode project's local signing settings are not changed. The app is **not notarized**; macOS may require explicit approval to open it. See the [README](../README.md) for installation and permission guidance.

The output directory `dist/0.0.0/` contains:

| File | Purpose |
| --- | --- |
| `Stackboard.app` | App to run locally |
| `Stackboard.zip` | Archive for distribution |
| `SHA256SUMS` | SHA-256 checksum of the archive |
| `release.json` | Version, build number, minimum macOS version, architectures, and SHA-256 for automation |

For IDE development, open [`Stackboard.xcodeproj`](../Stackboard.xcodeproj/) and select the **Stackboard** scheme. The project uses automatic signing with the author's team. To build directly in Xcode, select your own team under **Signing & Capabilities**, or use the packaging script above to build without certificates.

### Build options

Versions must use stable, canonical `X.Y.Z` notation, optionally prefixed with `v`. The output directory must not exist or must be empty: the script refuses to overwrite completed output. The default build number is `1`.

To specify a positive integer build number and a different output directory:

```sh
BUILD_NUMBER=17 bash scripts/package-release.sh v0.0.0 /tmp/stackboard-package
```

The build number must not contain leading zeroes.

### Verify an existing package

To verify a package on macOS without rebuilding or modifying its ZIP:

```sh
bash scripts/package-release.sh --verify-existing 0.0.0 dist/0.0.0
```

Verification checks the checksum, archive paths and symlinks before extraction, the app version and bundle identifier, architectures of every packaged Mach-O binary, signatures for both architectures, and the absence of the debug `get-task-allow` entitlement.

`Stackboard.zip` and `SHA256SUMS` from the same version are required. If `Stackboard.app` or `release.json` is missing, the script reconstructs it from the verified archive; existing copies must match the archive. Unrelated files and mismatching results are not replaced.

## Project map

Stackboard uses **Swift, SwiftUI, and AppKit**. Clipboard history is stored in **SQLite**, and global hotkeys use **Carbon**. The Xcode project has no third-party package dependencies.

| Area | Sources |
| --- | --- |
| Menus, windows, and application actions | [`AppController.swift`](../Stackboard/AppController.swift), [`MenuBarMenuView.swift`](../Stackboard/MenuBarMenuView.swift) |
| Clipboard monitoring and history storage | [`ClipboardMonitor.swift`](../Stackboard/ClipboardMonitor.swift), [`ClipboardService.swift`](../Stackboard/ClipboardService.swift), [`ClipboardHistoryStore.swift`](../Stackboard/ClipboardHistoryStore.swift) |
| Screen capture and region selection | [`ScreenshotCoordinator.swift`](../Stackboard/ScreenshotCoordinator.swift), [`DesktopCapture.swift`](../Stackboard/DesktopCapture.swift) |
| Editor and annotations | [`EditorDocument.swift`](../Stackboard/EditorDocument.swift), [`EditorAnnotationGeometry.swift`](../Stackboard/EditorAnnotationGeometry.swift), [`ScreenshotEditorView.swift`](../Stackboard/ScreenshotEditorView.swift) |
| Crop frame and gestures | [`EditorCropOverlay.swift`](../Stackboard/EditorCropOverlay.swift) |
| PNG/JPEG saving | [`ScreenshotEditorWindowController.swift`](../Stackboard/ScreenshotEditorWindowController.swift), [`ScreenshotExport.swift`](../Stackboard/ScreenshotExport.swift) |
| Image opening and commands | [`EditorImageImport.swift`](../Stackboard/EditorImageImport.swift), [`ImageOpenCoordinator.swift`](../Stackboard/ImageOpenCoordinator.swift) |
| Global hotkeys | [`GlobalHotKeyCenter.swift`](../Stackboard/GlobalHotKeyCenter.swift), [`HotkeySettingsStore.swift`](../Stackboard/HotkeySettingsStore.swift) |
| App and menu bar icons | [`StatusBarIcon.swift`](../Stackboard/StatusBarIcon.swift), [`Assets.xcassets`](../Stackboard/Assets.xcassets/), [`generate-icons.swift`](../scripts/generate-icons.swift) |
| Packaging and publication | [`scripts/`](../scripts/), [GitHub Actions workflows](../.github/workflows/), [release guide](releases.md) |

## Generate icons

The icons share a stack-of-cards motif. The color app icon includes a capture frame; the menu bar icon is simplified for 18 points. The menu bar icon is a system template image with a transparent background and 1×/2× variants, with its color chosen by macOS. AppIcon includes all sizes from 16 to 1024 pixels.

The source geometry and palette are in [`scripts/generate-icons.swift`](../scripts/generate-icons.swift). Regenerate the PNGs on macOS without third-party dependencies:

```sh
xcrun swift scripts/generate-icons.swift
```

## Development checks

Run these commands from the repository root:

```sh
bash -n scripts/package-release.sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.12 -shellcheck shellcheck
```

The last command requires Go and ShellCheck in `PATH`. Full package verification requires macOS: run `package-release.sh`, then `--verify-existing` as described above. The [CI workflow](../.github/workflows/ci.yml) checks workflows, shell syntax, and release-tool behavior, builds a Universal package, and verifies the same ZIP again.

### Test coverage and limits

The Python suite tests the release tools. On macOS with Xcode, it also exercises the real editor model using synthetic images: erasing, transparency, Undo/Redo, branching and independent histories, selection, movement, resizing, styling, deletion and duplication of objects, text re-editing, Cyrillic text, and line wrapping. It checks restoration of identifiers, annotation ordering, and exported pixels. Editor checks are skipped on other platforms.

The tests do not make network requests, modify the Homebrew tap, or read the system clipboard or user history. They do not replace manual testing of the app's interface.

Additional image checks cover:

- **PNG/JPEG export:** decode saved files to check Retina resolution, annotation pixels, PNG transparency, white backgrounds for transparent JPEG regions, the effect of quality on image fidelity, and document preservation when writing fails.
- **Cropping:** compare pixels with the corresponding source region, including Retina images, partially cropped shapes, arrows and text, eraser masks, and Blur at the new boundary. Checks include repeated crops, alternating crops with object edits, Undo/Redo, cancelling the crop frame, preserving the Redo branch, and boundary sizes down to one pixel.
- **Native crop and composite rasterization:** use explicit 1× and 2× bitmap contexts, including odd Retina dimensions and Undo restoration. Cropped images keep an explicit `NSBitmapImageRep`, so pixel dimensions must not depend on display scale or a headless CI environment.
- **Image import:** use temporary files and separate named pasteboards to check original resolution and PNG transparency, JPEG EXIF rotation, Retina TIFF, preference for explicitly stored PNG over reduced or synthesized representations, input errors, and independent documents. Source files and pasteboard contents are checked for changes after opening, editing, and export.

## README demo media

The [README demo](media/stackboard-demo.gif) records the real region selector and SwiftUI screenshot editor built from the repository sources. The surrounding page and destination message are staged sample content, not Stackboard features. Inputs were automated within an isolated demonstration process because external UI automation was unavailable.

The demo uses a separate named pasteboard to transfer the rendered image into the sample message. It does not read clipboard history or replace the system clipboard. The opening editor shot is a still taken from the same recording; a [static preview](media/stackboard-editor.png) and [H.264 video](media/stackboard-demo.mp4) are also available.

## Feedback and roadmap

Report bugs and suggestions in [GitHub Issues](https://github.com/0x0FACED/stackboard/issues). For a bug, include the Stackboard and macOS versions, Mac architecture, installation method, reproduction steps, and expected and actual results. Do not attach secrets from clipboard contents or screenshots.

The editor and history roadmap is in [`TODO.md`](../TODO.md). Roadmap entries are not already available features.
