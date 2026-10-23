---
id: SM1296
title: "SM1296: get_permissions on a page's stem answers the rule that governs the page"
subtitle: "On edge, get_permissions on /zz76/b answered acl: null while /zz76/b.md was a draft, because the move had folded the draft into the page's own key. A stem that names a page, and the page itself, now answer the page's rule and name the key that holds it, on MCP, the control API and the CLI."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-23
raised-by: "edge walk of 0.16.1, observation O-3"
area: acl
status-note: "SHIPPED (PENDING) on n736: Acl::page_rule (sharing fold_page_stem's folder test and merge), Files::action_acl_get (MCP get_permissions, the control API acl-get, lazysite acl show). t/unit/manager/412."
---

# What happened

The edge walk of 0.16.1 (O-3): `/zz76/b.md` was a draft through the rule that
[[SM1257]]'s fold had moved to its `.md` key when the page was moved there. `get_permissions`
on the page's stem, `/zz76/b`, answered `acl: null`. `action_acl_get` read the one key
it was asked (`zz76/b`) and nothing else, while the engine reads a page's own key and
then its stem (SM268 H14). So a caller who had drafted a page through its stem, and
checked it after a move, was told there was no rule. The same read, asked by the page's
path, missed a rule held at the stem.

# What shipped

- **`Lazysite::Auth::Acl::page_rule($docroot, $rel)`**. A stem names a page when no folder
  of that name exists (in the docroot or the private store - the test `fold_page_stem`
  uses, now one function, `_stem_is_folder`) and a page of it exists (`.md`, `.url` or
  `.html`, in either tree, or as a key in the store). Asked by that stem or by the page,
  it answers the page's own record with the stem's value wherever the own record has
  none, which is how the engine reads the two and what the fold writes (one merge,
  `_stem_folded`). It returns the key that holds the rule - the page's own key when both
  hold part - and every key that contributed. A folder, a static file, or a stem naming
  no page answers the exact key as before.
- **`action_acl_get`** answers that rule, with `key` (the key holding it, or null) and,
  when the page and its stem both hold part, `keys`. It is MCP `get_permissions`, the
  control API `acl-get` and `lazysite acl show`, which prints a `key:` line when the rule
  is held somewhere other than the path asked. The site-wide rule's answer carries `key`
  too. The owner check reads the answered rule.
- **What writes back reads the key as stored.** `acl-set`'s before-image for the audit
  (single and list form) and `lazysite acl reapply`, which reads a rule and writes the same
  values back, pass `{ exact => 1 }`, so an audit row says what the written key was, and a
  re-apply never copies a page's rule onto its stem.
- The MCP tool description and docs/ai-connector-tools say so.

# Tests

t/unit/manager/412 (new), through the control API and the CLI: a page drafted through its
stem and moved answers its draft at the new stem, with `key` `zz76/b.md`, and at its own
path; a rule at the stem answers for the page, naming the stem key; with both holding part
the stem answers the merged rule with both keys; a folder of the stem's name keeps its own
(empty) answer; an acl-set at the stem audits `new -> ...`, not the page's draft;
`lazysite acl show` prints where the rule is held. With the old Files.pm and CLI four
subtests fail; with acl-set's before-image read through the new answer the audit subtest
fails.
