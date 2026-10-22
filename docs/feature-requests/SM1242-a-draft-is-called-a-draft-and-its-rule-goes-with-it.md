---
id: SM1242
title: "SM1242: a draft is called a draft, and a page's rule goes with it"
subtitle: "set_permissions called a page in a draft or gated folder open to anyone, and said nothing of what a draft does. Deleting a page left a rule keyed by its stem. Both are fixed; an MCP tool that removes a rule is a question for the release manager."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-20
raised-by: "the xisl.com site agent, inbox 2026-10-20-set-permissions-says-a-draft-is-readable.md (task #372 a and b)"
area: acl
status-note: "SHIPPED (PENDING) on n725: acl-set's reply asks the engine's walk for the nearest draft and read rules after the save, and says what a draft does (draft_note). action_delete drops a page's stem-keyed rule when no folder of that name exists. Acl's walk takes a draft mode. t/integration/65, t/unit/manager/160."
---

# What happened

The xisl.com site agent reported two things:

1. `set_permissions { path, draft: true }` with no read list answered
   `reads_unrestricted: 1`, "anyone may still fetch these pages". The page answered
   404 to anonymous visitors.
2. `delete_page` removed the page, its draft rule stayed in the store, and no tool
   removes a rule.

# What was measured on this tree

- **(1), the page's own rule, was already fixed** by [[SM937]] (0.15.10). The reply asks
  `_acl_gates_public`, which counts `draft`. **The same defect remained for an inherited
  rule.** The reply judged the page's own record only. An owner-only rule on a page
  inside a draft folder was told "anyone may still fetch these pages", and so was one
  under a folder's read list. No reply said what a draft does, which the reporter asked
  for.
- **(2), the page's own key, was already fixed** by CF-2 (`action_delete` calls
  `Acl::forget_path`; t/unit/manager/160 AO1). **A rule keyed by the page's stem was not
  dropped.** `set_permissions` on `/about` stores `about`, which governs `about.md`
  ([[SM268]] H14). Deleting `about.md` left `about` in the store, and the next page
  written there was born a draft.

# What shipped

- **acl-set's reply asks the rule that decides.** After the save it takes the nearest
  entry carrying `draft` and the nearest carrying a read list. It uses
  `Lazysite::Auth::Acl::governing_key`, which now takes a `draft` mode the way the
  processor's walk does (SM981). `reads_unrestricted` and its note are given only when
  neither governs.
- **A draft says what it does.** When a draft rule governs and no read list does, the
  reply carries `draft_note`. It names the rule (this one, or the folder's), says the
  pages answer 404 to the public and are left out of the sitemap and search, says any
  signed-in account may preview them, and says how a read list limits who may preview.
- **A page's stem-keyed rule goes with the page.** `action_delete` (the manager, the
  control API `delete` and MCP `delete_page`) also drops the exact stem key, but only
  while no folder of that name exists in the docroot or the private store. While one
  does, the key is the folder's rule. Rules beneath the stem are never touched.

# Tests

- t/integration/65: an owner-only rule on a page in a draft folder does not say reads are
  open, and its `draft_note` names the folder. A page under a folder read list does not
  say reads are open and has no draft note. An owner-only rule with nothing above it
  still says reads are open. A page's own draft rule carries the note. With Files.pm
  reverted, the new assertions and the SM937 subtest's note assertions fail. With Acl.pm
  reverted, the inherited-draft assertions fail.
- t/unit/manager/160: a stem-keyed draft rule goes when the page is deleted. A folder's
  stem rule and a rule beneath it stay when the folder's landing page is deleted. With
  Files.pm reverted, the first two fail.

# Not done

- **A tool that removes a rule.** The control API has `acl-remove` (and the CLI has
  `lazysite acl remove`), but MCP has no tool for it. It is not needed for a deleted
  page any more, but it is needed for a rule an agent set by mistake, or one on a path
  that never had content. Adding an MCP tool changes the published surface, so that is
  for the release manager.
- **A move leaves a stem-keyed rule behind** (found while measuring this). `action_move`
  re-keys the page's own key and its descendants, not the stem. A page drafted through
  `/about` and moved to `/other` loses its draft: the rule stays at `about`, and
  `other.md` is published. It is not fixed here.
- **WebDAV's DELETE** drops the path's own key (SM212) but not a stem key. It is not
  changed here.
