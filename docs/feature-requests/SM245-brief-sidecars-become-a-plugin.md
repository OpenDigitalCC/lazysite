---
title: "SM245 - Move .brief sidecars into an optional plugin"
subtitle: "Every site pays for the brief system whether or not it uses it: the render path checks it, the file manager reports it, move/copy/convert carry it, and the indexer skips it. Make it opt-in."
brand: plain
status: candidate
status-note: "Raised by the operator 2026-08-08. SM073 shipped briefs in 0.4.0 as an always-on convention. The proposal is not to remove them but to make the whole system a plugin, so a site that does not author briefs has no brief behaviour at all. Touches the render path, the files app, the manager, MCP and the docs - the audit of who notices .brief is the first work item and is largely done below."
---

# SM245 - .brief sidecars become an optional plugin

## Why

SM073 (0.4.0) gave every meaningful file an author-maintained sidecar: a short,
append-only record of why a file exists and what each edit changed. Good idea,
and on a site that uses it, valuable.

It is also unconditional. A site that has never written a brief still carries the
behaviour on every surface that touches a file. The cost is small per site and
paid by every site, and - more to the point - it is a **convention baked into the
engine** rather than a feature an operator chooses. The engine should own what
every site needs; a documentation practice that some sites keep should be a
plugin.

There is a second reason, visible in the audit below: `.brief` is special-cased
in six different places by three different rules (never served, never indexed,
carried on move, carried on copy, carried on convert, reported in listings). Each
is correct and none of them is discoverable from the others. Concentrating that
in one enable-able unit makes the whole behaviour legible.

## Where .brief is noticed today

Verified by reading the source. This is the surface the plugin has to take over
or the removal has to account for.

### Render / serve path (`lazysite-processor.pl`)

| Line | Behaviour |
|---|---|
| ~1249 | A request for `<file>.brief` is **refused** - briefs are private and never served publicly |
| ~3913 | Briefs are **skipped by the indexer**, so they never reach sitemap / llms / feeds |

Both are safety properties, and this is the important asymmetry: **if the plugin
is disabled, "never served" must still hold.** A site that once used briefs and
later disabled the plugin must not begin serving its brief files. Whatever else
moves, the refusal stays in the engine, or disabling the plugin becomes a
disclosure event.

### Files app / manager (`lib/Lazysite/Manager/Files.pm`)

| Behaviour | Detail |
|---|---|
| Listing | A `.brief` entry is marked as a sidecar; every other file reports `has_brief` |
| Move | `rename` carries `<file>.brief` alongside, and re-keys its ACL |
| Copy | `copy` carries `<file>.brief` |
| Convert (`.url` to local `.md`) | carries `<file>.brief` |

`starter/manager/files.md` renders the brief affordance (10 references).
`starter/manager/audit.md` names `.brief` among the editable file types.

### MCP surface (`lazysite-mcp.pl`)

- `page_status` returns `has_brief`.
- The `.md` scan excludes `*.md.brief`.
- Three tool descriptions (`move_file`, `delete_page`, `rename_page`) promise
  that the operation "carries its `.brief`".

### Documentation

`ai-briefing-authoring` (2), `ai-briefing-publishing` (5), `ai-connector-tools`
(3), `docs/FEATURES.md` (7), `docs/USER.md` (1), plus the webserver-wiring
reference.

## What to build

### The plugin owns the convention

A `brief` plugin, enabled per site, owning: the listing affordance, the
`has_brief` reporting, the manager editor integration, and the tool-description
promises. Disabled, none of it appears - `has_brief` is absent rather than false,
the files app shows no brief column, and the tool descriptions do not promise
something the site will not do.

### The engine keeps the two safety properties

**Never served** stays in the processor unconditionally, for the reason above.
**Never indexed** should also stay: indexing a `.brief` on a site that disabled
the plugin would publish exactly the private content the refusal protects.

Both are cheap - two pattern checks - and neither depends on the plugin being
loaded. The rule to state plainly: *the engine keeps every rule whose failure
would expose a brief; the plugin owns every rule that merely makes briefs
useful.*

### Move / copy / convert: the open question

Carrying the sidecar on a move is not a safety property - it is data integrity
for a feature that may be off. Two defensible answers, and this is the request's
main decision:

**The plugin hooks the operations.** Correct in principle, and it needs a hook
point that does not exist yet: `Files.pm` would have to offer "after a move,
these paths changed" for a plugin to act on. That hook is worth having for other
reasons.

**The engine keeps carrying them.** A stray `<file>.brief` left behind by a move
is a small mess, and orphaned sidecars accumulate silently. Keeping three
`rename`/`copy` calls costs almost nothing and cannot leave debris.

Recommend the second for the first cut, on the grounds that a disabled feature
should not be able to corrupt data authored while it was enabled - and revisit
if the hook point materialises for other work.

## Back-compat

Sites that use briefs today must keep working. The plugin ships **enabled on
upgrade for any site that already has at least one `.brief`**, and disabled for
everyone else - detectable in one scan at upgrade time. A site with no briefs
gets the new default (off) and notices nothing.

## Verification

- A site without the plugin: no `has_brief` anywhere, no brief column, no tool
  description promising brief handling.
- A site with the plugin: identical behaviour to today.
- With the plugin **disabled** on a site that has existing `.brief` files: they
  are still refused publicly, still skipped by the indexer, and still carried by
  move/copy/convert.
- Upgrade leaves a brief-using site enabled and a brief-free site disabled.
- Documentation describes briefs as an optional plugin, not a convention.

## Not in scope

- Removing the brief system, or migrating existing sidecars.
- Changing the brief format or its append-only discipline.
- The generic post-operation plugin hook, if the recommendation above stands -
  that becomes its own request if the alternative is chosen.
