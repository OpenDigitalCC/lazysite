---
id: SM878
title: "SM878: drag and drop onto the Files page, beside the Upload button"
subtitle: "Uploading needs a button press and a file-picker round trip. Dropping files onto the listing is how every other file manager works, and the whole delivery path already exists - uploadFiles() takes a FileList, which is exactly what a drop event carries. The button STAYS: drag-and-drop is undiscoverable on its own and unusable by keyboard."
brand: plain
standard-margins: true
status: shipped
status-note: "RAISED 2026-09-14 by the release manager as 'can be done later', then BUILT the same day on claude/sm880-attribution-guard-and-drop-upload once it was confirmed to be front-end only. uploadFiles(files) already accepts a FileList, which is exactly what a drop event's dataTransfer.files is, so the drop handler CALLS it rather than adding a second upload path - the POST, overwrite confirmation, partial-success reporting and audit behaviour are unchanged. Drops land in currentDir, the folder on screen. The browser's default action on a dropped file is to NAVIGATE TO IT, discarding the page, so dragover and drop are suppressed on the whole document, not only the target - the misses are precisely the drops that would throw the page away. A dropped FOLDER is refused by name (webkitGetAsEntry().isDirectory), because walking a directory tree is a larger change and silently uploading nothing is the worst option. Only drags carrying 'Files' activate the target, so a dragged text selection or link does not flash one. The Upload button STAYS: a drop zone advertises itself to nobody, is keyboard-inaccessible and absent on touch. CORRECTION to the original filing below: it claimed the page already drags rows for move/reorder and that internal drags would need excluding. It does not - files.md had no drag handling of any kind. The claim was written from plausibility, not from the file, and checking it was what found that out."
---

# SM878 — drag and drop onto the Files page

Raised by the release manager, 2026-09-14, alongside SM877: *"file apps — drag
drop file uploader required as well as upload — file it, can be done later."*

**Not 0.14.1.** Filed to be scheduled.

## What exists now

`starter/manager/files.md`:

- line 32: a hidden `<input type="file" multiple>`
- line 33: an `Upload` button calling `triggerUpload()`
- line 1106: `triggerUpload()` clicks the hidden input
- line 1108: `uploadFiles(files)` takes the resulting `FileList`, POSTs to
  `action=file-upload&path=<dir>`, and handles the partial-success and
  overwrite-confirmation cases

So uploading works, and costs a click plus a file-picker round trip even when
the files are already visible in another window.

## Why it is small

`uploadFiles()` already takes a `FileList`. A `drop` event's
`event.dataTransfer.files` **is** a `FileList`. The feature is therefore a new
way to *call* the existing function, not a second upload path — which is the
condition that keeps one piece of code answering for everything that reaches
the content tree, with its existing conflict, error and audit behaviour intact.

If that stops being true — if a drop needs its own request shape — the change
has grown into something that needs its own review.

## What the design has to get right

- **The target directory is the one on screen.** `uploadFiles()` reads the
  current `dir`; the drop handler must not introduce a second idea of where
  "here" is.
- ~~**Do not fire on internal drags.** The page already drags items for move and
  reorder.~~ **Wrong, and worth recording.** `files.md` had no drag handling of
  any kind — no `draggable`, no `dragstart`, nothing. I wrote that from what a
  file manager usually does rather than from the file, and only found out by
  checking before building. What the handler actually needs is the narrower
  test that the drag carries `Files` at all, so a dragged text selection or link
  does not light up a drop target.
- **Cancel the browser's default on the whole drop surface.** An unhandled drop
  makes the browser navigate to the file, discarding unsaved state elsewhere on
  the page. This must be suppressed even outside the intended zone.
- **Folder drops.** A dropped directory arrives as an entry needing
  `webkitGetAsEntry()` to walk, not as files. Decide deliberately: walk it, or
  refuse it by name ("drop the files, not the folder") — the one thing not to
  do is silently upload nothing.
- **The Upload button stays.** A drop zone advertises itself to nobody and
  cannot be operated from a keyboard. This is additive.
- **Say where it will land** while a drag is over the page, so a drop into the
  wrong folder is prevented rather than undone.

## Related

[[SM877]] came from the same session. This one is UI-only and touches no
delivery or access path.
