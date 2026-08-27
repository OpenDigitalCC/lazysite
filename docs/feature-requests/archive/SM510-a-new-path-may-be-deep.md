---
title: "SM510: a new path may be deep"
subtitle: "validate_path resolved a new file against its immediate parent only, so /a/b.md validated while /a/b/c.md was 'Invalid path' - a confusing refusal for any caller creating a nested path, and a block on the brief-first authoring the briefings recommend."
brand: plain
standard-margins: true
status: shipped
status-note: "FOUND BY THE SITE AGENT 2026-08-24 mapping the briefs key space: the validator's realpath anchor was dirname(full), so a path whose parent directory does not exist yet resolved to undef and refused as 'Invalid path' - while action_save and action_mkdir both create parent directories, making the refusal answer a question nobody asked. SHIPPED 0.10.30: the anchor walks to the NEAREST EXISTING ancestor (terminating at the docroot, which exists) and the canonical path re-attaches the full missing suffix rather than only the basename; the private-root branch (SM458) gets the identical walk. SECURITY UNCHANGED, deliberately: the F1 `..` rejection runs before any resolution; symlinks in EXISTING ancestors still collapse through realpath (a symlinked ancestor escaping sideways is pinned refused); segments that do not exist cannot hold a symlink; the H3 boundary-safe containment test is untouched. t/unit/manager/67 pins depth-N validation, the unchanged posture, and the deep first save."
---

# The incoherence

`/a/b.md` accepted; `/a/b/c.md` refused "Invalid path"; whether
`/docs/deeper/never.md` worked depended on what happened to exist. The
validator anchored `realpath` at `dirname($full)` - one level only - so
any missing intermediate directory produced undef and a refusal, while
the write paths behind it happily `make_path` parents.

# The fix

The anchor walks up to the nearest **existing** ancestor (the docroot at
worst), and the canonical path re-attaches the whole missing suffix. The
private-root branch gets the identical walk.

# Why it is safe

- `..` is rejected before any resolution (F1, unchanged).
- Symlinks in existing ancestors still collapse through realpath - the
  escape-sideways case is pinned refused in the test.
- Path segments that do not exist yet cannot contain a symlink.
- The H3 boundary-safe containment comparison is untouched.
