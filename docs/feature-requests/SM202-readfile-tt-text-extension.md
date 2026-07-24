---
title: "SM202 - read_file refuses layout.tt as binary (text-extension allowlist gap)"
subtitle: "Template Toolkit templates (.tt) are plain text but absent from the editable-text allowlist, so read_file / git-show / git-restore refuse them as binary - which blocks the sanctioned copy-nearest-layout-then-adapt authoring workflow over the connector."
brand: plain
status: candidate
status-note: "IMPLEMENTED on main 2026-07-24 (unreleased, 0.9.14 line); scoped from the theme-authoring / Figma design-transfer briefing (item 1). Audited: root cause confirmed as an extension-allowlist gap, NOT file corruption - all 23 shipped layout.tt files are clean UTF-8. Small, self-contained."
---

# SM202 - read_file refuses layout.tt as binary (text-extension allowlist gap)

## Why

Over the MCP connector, `read_file` on a layout's `layout.tt` (a ~13 KB Template
Toolkit text template) is refused as binary:

```
{ ok: 0, binary: 1, kind: "binary", error: "Binary file - download instead of edit" }
```

The sanctioned workflow for changing a design is *copy the nearest layout, then
adapt* - the active layout is write-locked by design, so an author copies a
sibling `layout.tt` and edits it. That workflow REQUIRES reading `layout.tt`. An
agent asked to adapt a layout is dead in the water if the source template trips
the binary detector. The Figma design-transfer pipeline is the first consumer to
hit this, but it is a general theme-authoring gap.

## Root cause (audited)

The binary/text decision is **purely extension-based**, not content-based, and
`.tt` is missing from the allowlist:

- `lib/Lazysite/Manager/Upload.pm` - `%TEXT_EXTENSIONS` (the allowlist) omits `tt`.
- `sub is_editable_text($path)` returns 1 only when the lower-cased extension is in
  `%TEXT_EXTENSIONS` (an unknown extension defaults to binary).
- Three read paths gate on it and all three refuse `.tt`:
  - `lib/Lazysite/Manager/Files.pm` `action_read` (the MCP `read_file` surface),
  - `action_git_show` (history view),
  - `action_git_restore` (history restore).

Because detection is extension-based, the briefing's alternate hypothesis - a
single stray latin-1 byte in a template making the whole 13 KB file unreadable -
does NOT apply to this code path. Audit of all 23 shipped `layout.tt` files
(`/srv/projects/lazysite-layouts/layouts/*/layout.tt`) plus the manager
`starter/lazysite/manager/layout.tt` found every one to be valid UTF-8 with no
control bytes. The fix is the allowlist, not a per-file repair.

## What

1. Add `tt` to `%TEXT_EXTENSIONS` in `Lazysite::Manager::Upload.pm`. This unblocks
   all three read paths at once (`read_file`, git-show, git-restore) and WebDAV,
   which share the same helper.
2. Review the allowlist for the other authoring text types the theme/layout tree
   uses, and add any that are plain text and legitimately editable. `.tt` is the
   confirmed miss; `registries/*.json` and `theme.json`/`layout.json` are already
   covered by `json`. Do NOT add binary/asset extensions.
3. Regression test in `t/unit/manager/03-download-content-type.t` (which already
   exercises `is_editable_text`): assert `layout.tt` is editable text, and add a
   lint-style assertion that every shipped `layout.tt` in the layouts repo
   round-trips through `is_editable_text` as editable.

## Scope and risk

Small and low risk. `.tt` is plain text in every context lazysite uses it; adding
it only unblocks legitimate reads and never causes a genuine binary (`.png`,
`.pdf`) to be mis-served as text (those extensions stay off the list). No render,
capability, or write-path change.

## Not in scope

- Content-based (byte-sniffing) detection. The extension allowlist is sufficient
  and predictable; a lossy-decode-with-warning mode is a larger change with no
  demonstrated need here (no shipped template carries a bad byte). If a stray-byte
  case is ever reported on an allowlisted text file, that is a separate item -
  the reader would need a tolerant `:utf8` decode - and should be filed then.

## Verification

- Over the connector, `read_file` every shipped `layout.tt`; all return content.
- `t/unit/manager/03-download-content-type.t` green with the new `.tt` assertions.
- Existing suite stays green.
