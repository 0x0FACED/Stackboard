# User guide

[Back to Stackboard](../README.md)

Stackboard is a macOS menu bar app for annotating screenshots and existing images, and for returning to text, images, and file references you have copied. This guide covers everyday use, local data, installation, and troubleshooting.

## First launch

Stackboard requires **macOS 13.5 or later**. Release archives contain a Universal app for **Apple Silicon and Intel**. If you have not installed it yet, see [Installation and updates](#installation-and-updates).

### Allow the app to open

Releases are **ad-hoc signed**, without Developer ID signing or Apple notarization. macOS may block the first launch, including after a Homebrew installation.

After attempting to open Stackboard, go to **System Settings → Privacy & Security** and choose **Open Anyway**, if that option is available and you trust the downloaded app. Do not disable Gatekeeper globally. An organization-managed Mac may have policies that prevent this kind of launch.

### Allow screenshots

When you take your first screenshot, Stackboard requests permission to capture the screen. Allow it in **System Settings → Privacy & Security → Screen Recording**. On newer macOS versions, the setting's name also mentions system audio.

Restart Stackboard if macOS asks you to. An update to an ad-hoc-signed app may require you to grant permission again; Homebrew does not grant it automatically. Screen Recording permission is **not needed** to open an existing image or use clipboard history.

Once the app is running, its main actions are available from the Stackboard icon in the menu bar.

### Keyboard shortcuts

| Action | Default shortcut |
| --- | --- |
| New screenshot | `⌘⇧S` — Command + Shift + S |
| Open clipboard history | `⌘⇧V` — Command + Shift + V |
| Open an image file | `⌘O` — while Stackboard is active |

The screenshot and history shortcuts are global. To change them, choose **Keyboard Shortcuts…** from the menu, click a shortcut field, and enter a combination with at least one modifier key. **Reset Defaults** restores the defaults.

If macOS or another app already uses a combination, the settings window shows a conflict. Choose another combination or use the menu actions. `⌘O` is a regular app command, not a global shortcut.

## Screenshot editor

### Capture and finish

1. Press `⌘⇧S` or choose **New Screenshot** from the menu.
2. Drag to select a screen region. Press `Esc` to cancel region selection.
3. Add annotations using the editor's left sidebar. Scroll the sidebar if its settings do not fit in the window.
4. Optionally zoom with a trackpad gesture, or use **Crop** to refine the image boundaries.
5. Choose **Save…** / `⌘S` to export a file, or **Copy to Clipboard** to put the result in the clipboard and clipboard history.

**Saving leaves the editor open. Copying closes it.** You can take another screenshot without closing existing editors, including a screenshot of an editor itself. Each window has independent annotations, settings, crop selection, and Undo/Redo history. Every new editor starts with red selected; changing one window's color does not change the others.

Save or copy a result before closing its window or quitting Stackboard. Exported PNG and JPEG files are finished images, not documents that preserve editable annotation objects.

### Annotation tools

| Tool | Use |
| --- | --- |
| **Move** | Select, move, resize, and edit existing annotations. |
| **Crop** | Adjust the image boundaries and apply the crop. |
| **Pen** | Draw freehand. |
| **Eraser** | Erase parts of annotations without changing the underlying image. |
| **Arrow** | Draw an arrow. |
| **Rectangle** | Draw a rectangle; hold `Shift` for a square. |
| **Ellipse** | Draw an ellipse; hold `Shift` for a circle. |
| **Blur** | Blur a rectangular area. |
| **Text** | Click to add multiline text or reopen an existing text annotation. |

Use the sidebar to adjust line width, shape appearance, eraser size, blur strength, or text formatting. For rectangles and ellipses, **Outline** draws only the border and **Filled** adds a fill. **Line width** is measured in pixels of the original image.

The **Custom color** swatch beside the quick colors opens the macOS color picker, including opacity. A color choice applies to new drawings, arrows, shapes, and text, and to a selected colored annotation.

**Blur is not a reliable way to remove secrets from an image.** Do not treat it as secure redaction.

### Select, move, resize, and remove annotations

With **Move**, click a drawing or arrow's line, a shape's outline, or the interior of a filled shape, text box, or blur region. Overlapping annotations select the topmost visible object. The empty center of an outline shape does not block objects beneath it, and erased parts cannot be selected.

Drag the selected part to move an object without snapping it to the pointer. Arrows have separate start and end handles. Drawings, shapes, and blur regions have a bottom-right resize handle; hold `Shift` while resizing to preserve proportions. Text has a separate width handle, described below.

Sidebar settings apply to the selected object: drawing or arrow color and width, shape fill and outline, blur strength, or text formatting.

- **Delete** or the `Delete` key removes the selected object.
- **Duplicate** or `⌘D` adds a copy above the existing annotations, offset slightly if the image has room. Previous eraser strokes are not applied to the duplicate.
- During text entry, `Delete` edits characters rather than removing the text object. Finishing an empty text annotation removes it.

### Erase annotations

Set the brush diameter with **Eraser size**, measured in original-image pixels. Erasing reveals the original image beneath the annotations; it does not erase the image itself. You can draw over an erased area again. One eraser stroke is one Undo step.

### Add and edit text

Text is entered directly on the image without a background panel. `Enter` adds a line. **Done**, `⌘Enter`, or `Esc` finishes text entry without copying the image or closing the editor.

To edit text again, click it with **Text**, double-click it with **Move**, or select it and press `Enter` or choose **Edit**.

With **Move**, drag the text box to reposition it. Its right-middle handle changes the box width and line wrapping, not the font's proportions. **Text size** accepts a slider value or a number from **8 to 256**, in original-image pixels; the initial size accounts for Retina scaling.

The font, color, position, and wrapping are consistent during entry, after editing, and in the exported image. Text outside the image boundaries is clipped in the preview and export, but remains in the text object. Move the box back inside the image or increase its width to reveal it.

### Crop without flattening annotations

Choose **Crop** to create or adjust a crop rectangle:

- Drag one of its eight handles to change an edge or corner.
- Drag inside the rectangle to move it, or outside it to select a new region.
- Check the resulting pixel dimensions in the sidebar.
- Choose **Apply** or press `Enter` to crop.
- Choose **Cancel** or press `Esc` to discard the rectangle without copying or closing the editor. Selecting another tool also cancels it.

**Save…**, `⌘S`, and **Copy to Clipboard** apply a pending crop before continuing.

Cropping keeps the native pixels and Retina scale. Annotations move with the image and remain editable. Parts crossing a crop boundary are hidden without changing their shape or text wrapping; objects entirely outside the crop are removed. Eraser and blur results are preserved in the remaining area.

One **Undo** restores the previous image boundaries, pixels, and annotations; **Redo** reapplies the crop. If the rectangle has not been applied yet, Undo only cancels the rectangle.

### Undo, Redo, and Escape

Use **Undo** / `⌘Z` and **Redo** / `⌘⇧Z` for adding, erasing, moving, resizing, formatting, editing text, deleting, duplicating, and cropping. One object drag, slider drag, or applied crop is one history step.

After Undo, a new edit replaces the Redo branch. Simply selecting an object, leaving a value unchanged, or canceling a crop rectangle or gesture does not clear Redo.

While typing text or a number, the Undo/Redo buttons and shortcuts use that field's native editing history instead of changing other objects. Finishing the input turns the whole text or numeric-field edit into one document-history step.

In the editor, `Esc` first cancels a crop rectangle, finishes text entry, cancels an in-progress drawing, erasure, move, or resize, or clears the selection. **When no action or selection is active, `Esc` copies the result and closes the editor.**

### Export PNG or JPEG

Choose **Save…** / `⌘S`, then select a name, folder, and **Format**:

- **PNG** is lossless and preserves transparency.
- **JPEG** has a **JPEG quality** slider from 0–100%. Transparent areas are exported against a white background.

Export includes annotations at the native resolution of the image, or of the remaining cropped area. The window size and canvas zoom do not change the exported resolution. Active text or numeric input is finished before the save dialog opens.

Canceling the dialog leaves the editor open. A write error also leaves it open and shows a message.

## Open an existing image

Choose **Open Image…** from the Stackboard menu bar icon or **File → Open Image…**. While Stackboard is active, you can also press `⌘O`. Select one file in the dialog.

For image pixels already on the clipboard, choose **Open Image from Clipboard** from the menu bar icon or **File** menu. This command reads an image, not a path, link, or file copied in Finder. Ordinary `⌘V` during text entry is unchanged.

Each opening creates a separate editor. Existing windows, annotations, crop rectangles, and histories are unaffected. Canceling the file dialog or an import error does not close existing editors.

### Supported formats and limitations

- PNG, JPEG, TIFF, HEIF, and other raster formats supported by the macOS system decoder can be opened.
- **PDF, SVG, and RAW are not supported.**
- Only the first frame or page of animated or multipage images is opened.
- Native resolution, transparency, and Retina size metadata are preserved; EXIF orientation is applied on import.

Imported images support the same annotation tools, cropping, Undo/Redo, copying, and PNG/JPEG export as screenshots. The title shows the file name or **Clipboard Image**.

Opening and editing do not overwrite the source file or change the clipboard contents. **Save…** suggests a separate name with an **edited** suffix; a file is written only after you confirm the save dialog.

## Clipboard history

While Stackboard is running, it automatically records supported clipboard content. The history persists between app launches.

1. Choose **Open Clipboard History** or press `⌘⇧V`.
2. Search by text, file name/path, or date. Search does not recognize text inside images.
3. Select an entry to preview it.
4. Choose **Copy Again**, then paste into the destination app with its normal `⌘V` command.

The eight most recent entries are also available directly from the menu bar menu. Use **Pin** to protect an entry from automatic cleanup, or **Delete** to remove an individual entry.

### Retention and clearing

The cleanup menu offers **7 days**, **30 days**, **90 days**, or **Keep Forever**. The default is **30 days**. Pinned entries are excluded from automatic cleanup.

**Clear** in the history window and **Clear History** in the menu remove the entire history, **including pinned entries**. Pins do not protect against explicit deletion or clearing.

Turning off age-based cleanup does not remove the entry-count limit. Clipboard history is not an indefinite archive; keep important content separately.

## Privacy and storage

History is stored locally on your Mac, with no cloud synchronization. Local storage alone does not protect sensitive data from someone with access to your Mac.

| Data | Location |
| --- | --- |
| SQLite history database | `~/Library/Application Support/Stackboard/clips.db` |
| Stored images | `~/Library/Application Support/Stackboard/images/` |
| Shortcuts, pins, and retention settings | macOS preferences in the `dev.0xfaced.Stackboard` domain |

### What is retained

- **Text** is saved without its original formatting.
- **Images** are stored in the history's image directory.
- **Files** are recorded as paths, not copies of their contents. Moving or deleting the source file makes copying it again from its old path unavailable.
- When several files are copied together, only the first file reference is saved.

There are currently **no per-app exclusions, recording pause, or filtering of private clipboard markers**. **Passwords and other sensitive text can enter the history.** Account for this when working with secrets; do not assume that another app's private clipboard marker will prevent recording.

Use **Delete** for individual history entries or **Clear History** for all entries, including pins. Normal app uninstallation leaves history and settings in place; see [Uninstall](#uninstall).

## Installation and updates

### Install with Homebrew

If [Homebrew](https://brew.sh) is installed:

```sh
brew install --cask 0x0faced/stackboard/stackboard
open /Applications/Stackboard.app
```

An `untrusted tap/cask` error has a separate [Homebrew trust procedure](#homebrew-reports-an-untrusted-tap-or-cask). Homebrew installation does not bypass Gatekeeper or grant Screen Recording permission; follow [First launch](#first-launch).

### Install manually and verify the download

1. Open the [latest release](https://github.com/0x0FACED/stackboard/releases/latest).
2. Download **`Stackboard.zip`** and **`SHA256SUMS`** from the same release into the same folder.
3. In Terminal, with that folder as the current directory, verify the archive:

   ```sh
   shasum -a 256 -c SHA256SUMS
   ```

4. After verification succeeds, extract the ZIP and move `Stackboard.app` to `/Applications`.
5. Open the app and follow [First launch](#first-launch).

SHA-256 verifies archive integrity; it does **not** authenticate the publisher. Releases are ad-hoc signed and are not Developer ID signed or notarized.

### Update

Before updating, save or copy anything you need from open editors, then choose **Quit Stackboard**.

For a Homebrew installation:

```sh
brew update
brew upgrade --cask 0x0faced/stackboard/stackboard
open /Applications/Stackboard.app
```

For a manual installation, download and verify the new release as above, replace the app in `/Applications`, and launch it again.

Replacing the `.app` does not update an already-running process: **quit and relaunch after either update method**. You may need to grant Screen Recording permission again after an ad-hoc-signed update.

### Uninstall

To remove a Homebrew installation:

```sh
brew uninstall --cask 0x0faced/stackboard/stackboard
```

For a manual installation, move `Stackboard.app` to the Trash.

Normal uninstallation leaves history and preferences in place. To remove history entries, choose **Clear History** before quitting and uninstalling. This clears pinned entries too; it does not remove app preferences.

## Troubleshooting

### macOS blocks the app

The releases are ad-hoc signed, without Developer ID or notarization. Attempt to open the app, then check **System Settings → Privacy & Security → Open Anyway**, as described in [First launch](#allow-the-app-to-open). Only proceed if you trust the download. Do not disable Gatekeeper globally; a managed Mac's policies may prevent an override.

### Screenshots need permission after installation or an update

Check **System Settings → Privacy & Security → Screen Recording**, enable Stackboard, and restart it if requested. Updates can require renewed permission. Homebrew does not grant access automatically. Existing-image editing and clipboard history do not require Screen Recording access.

### A keyboard shortcut conflicts

Open **Keyboard Shortcuts…** and choose a different combination with at least one modifier key. You can use the menu actions instead, or **Reset Defaults** to restore the original combinations.

### Homebrew reports an untrusted tap or cask

Homebrew 7 may require explicit trust for a third-party cask. **Only if installation reports an `untrusted tap/cask` error**, and you trust its Homebrew configuration, run:

```sh
brew trust --cask 0x0faced/stackboard/stackboard
brew install --cask 0x0faced/stackboard/stackboard
```

This trusts the Ruby configuration used by Homebrew; it does not bypass Gatekeeper. Older Homebrew versions may not have the `trust` command.

### An image will not open from the clipboard

**Open Image from Clipboard** requires actual image pixels. It does not import a copied Finder file, file path, or URL. For an image file, use **Open Image…** instead. Check the [supported formats and limitations](#supported-formats-and-limitations) for files that cannot be imported.

### A history file cannot be copied again

File history stores a path, not the file contents. If the source was moved or deleted, the old entry cannot restore it. Find the original file at its current location and copy it again if available.
