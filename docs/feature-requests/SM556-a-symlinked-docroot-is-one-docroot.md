---
title: "SM556: a symlinked docroot is one docroot"
subtitle: "Under a symlinked document root three manager modules refuse and two succeed, because they confine against different spellings of the same tree."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.32 (EDGE): fixed at the two dispatchers as the report puts it - lazysite-manager-api.pl and lazysite-mcp.pl take their docroot through the new Lazysite::Paths::canonical_docroot, which resolves DOCUMENT_ROOT only when both spellings find the same engine tree (an unmigrated site) and keeps the given spelling when a migrated -lazysite tree is found by one spelling only, so canonicalising can never move the engine tree out from under the front end; the per-module comparisons stay as they are. Proving test t/unit/manager/103-a-symlinked-docroot-is-one-docroot.t loads the control API and drives the MCP under a symlinked docroot: the three refusing actions succeed, the two that already did still do, and a migrated tree is left to the spelling that finds it. FOUND 2026-08-25 by the themes structural review, PROVEN by probe tmp/tl-probe-symlink-docroot.pl; class: correctness; recommended timing: later. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. With DOCUMENT_ROOT a symlink to the real tree, Themes::action_theme_delete refuses with Invalid theme path (Manager/Themes.pm 1334-1336), action_cache_invalidate('/page') answers blocked (1746-1749) and Plugins::action_form_submissions refuses with Invalid submissions file (Manager/Plugins.pm 958-961) - all three compare realpath of the target against the unresolved DOCROOT string. Layouts::action_layout_delete (Manager/Layouts.pm 636-639) and the Domains purge (Manager/Domains.pm 971-976) resolve both sides and succeed. Fix at the two dispatchers: canonicalise DOCROOT once, at manager-api 71 and the MCP setup_context."
---

# The finding

With `DOCUMENT_ROOT` a symlink to the real tree:
`Themes::action_theme_delete` refuses (`Invalid theme path`,
`Manager/Themes.pm 1334-1336`), `action_cache_invalidate('/page')`
answers `blocked` (`Manager/Themes.pm 1746-1749`),
`Plugins::action_form_submissions` refuses (`Invalid submissions file`,
`Manager/Plugins.pm 958-961`) - all three compare `realpath($target)`
against the unresolved `$DOCROOT` string, the same shape as Common's
H3 check (`Manager/Common.pm 158-161`). `Layouts::action_layout_delete`
(`Manager/Layouts.pm 636-639`) and the Domains purge (`Manager/Domains.pm
971-976`) resolve both sides and succeed. The house convention assumes
the dispatcher's DOCROOT is canonical; two modules stopped assuming it.

# Why it matters

Correctness: one site, one tree, and five modules give two answers to
whether a path is inside it. An operator whose hosting layout uses a
symlinked docroot finds some actions working and others refusing with a
message about an invalid path that is in fact valid.

# The proving test

NEW `t/unit/manager/103-a-symlinked-docroot-is-one-docroot.t`: the probe
as assertions, `is($td->{ok}, 1)`.

# Fix shape

Canonicalise `$DOCROOT` once at the two dispatchers
(`lazysite-manager-api.pl 71` and the MCP `setup_context`), so every
module confines against the resolved tree; the per-module comparisons
then stay as they are.
