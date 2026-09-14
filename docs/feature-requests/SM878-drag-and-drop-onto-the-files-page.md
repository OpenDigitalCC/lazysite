---
id: SM878
title: "SM878: drag and drop onto the Files page, beside the Upload button"
subtitle: "Uploading needs a button press and a file-picker round trip. Dropping files onto the listing is how every other file manager works, and the whole delivery path already exists - uploadFiles() takes a FileList, which is exactly what a drop event carries. The button STAYS: drag-and-drop is undiscoverable on its own and unusable by keyboard."
brand: plain
standard-margins: true
status: candidate
status-note: "RAISED 2026-09-14 by the release manager, explicitly 'can be done later'. NOT 0.14.1. The mechanism is already in place: files.md:1108 uploadFiles(files) accepts a FileList and does the POST, retry and conflict handling, so a drop handler is a new way to CALL it rather than a second upload path - which is the condition that keeps this small and keeps one code path answering for what lands on disk. Must land in the CURRENT DIRECTORY the listing is showing, must not fire on a drag that started inside the page (a file being reordered or moved is not an upload), and must not let the browser navigate away when a drop misses the target - the default action on a stray drop is to open the file, losing whatever is on screen. ADDITIVE ONLY: the Upload button stays, because a drop zone is invisible until you already know it is there and cannot be reached from a keyboard at all."
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
- **Do not fire on internal drags.** The page already drags items for move and
  reorder. A drop that originated inside the page is not an upload, and
  treating it as one would re-upload a file onto itself.
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
