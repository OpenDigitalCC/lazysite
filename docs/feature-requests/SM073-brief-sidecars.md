---
title: "SM073 - Per-file .brief sidecars"
subtitle: "Author-maintained intent records alongside content, layout and theme files"
brand: plain
---

::: widebox
Every meaningful file an agent authors gets a sidecar `<file>.brief` next to
it: a short, append-only record of *why* the file exists and *what* each edit
changed. Briefs are writable over WebDAV and in the manager editor, but are
**never served publicly** - they document intent for the next agent, not the
visitor.
:::

## 1. Summary

A publishing agent edits a page, a theme, a layout - and the reasoning behind
each change is lost the moment the session ends. SM073 gives every authored
file a **sidecar brief**: a sibling file `<file>.brief` carrying the file's
purpose and an append-only log of edits. The next agent (or the operator) reads
the brief to understand intent before changing anything, and appends its own
entry when it does.

The sidecar is plain Markdown, lives in the same directory as the file it
describes, is writable through the same channels that wrote the file (WebDAV,
manager editor), and is blocked from public serving at every layer.

## 2. Principles

Intent travels with the file
: The brief sits beside the file, not in a separate registry, so a `MOVE`/`COPY` or a directory browse keeps them together and the relationship is obvious.

Append-only, never rewritten
: An edit adds a log line; it does not rewrite history. The brief accumulates the file's story.

Private by construction
: A brief is denied at Apache, the dev server, and the processor, and is excluded from `sitemap.xml` / `llms.txt`. It is reachable only to an authenticated agent over WebDAV or an operator in the manager.

Encouraged and visible, not hard-gated
: v1 does not reject a content `PUT` that lacks a brief. Instead the convention is documented, the editor surfaces the brief, and the Files page flags files missing one. A hard enrolment gate is a later toggle, not a v1 requirement.

## 3. The sidecar

```datatable
columns: Property | Value
widths: 4.5cm | X
bold: 1
tone: medium
---
Name | `<source-filename>.brief` - append `.brief` to the full filename (e.g. `index.md.brief`, `main.css.brief`). One brief per file; unambiguous.
Format | Markdown. A one-line `intent:` and an append-only `## Log` of `date · action · actor · summary` lines.
Location | The same directory as the file it describes - content tree, `lazysite/layouts/**` (layouts and themes).
Write path | WebDAV (content + layouts scope) and the manager editor. Not blocked by `is_blocked` (it is not a privileged path or extension).
Public serving | Denied: Apache `FilesMatch`, the dev server, the processor. Excluded from `sitemap.xml` and `llms.txt`.
```

A brief looks like:

```markdown
# Brief - index.md

intent: the site landing page; hero + three feature cards + contact CTA.

## Log

- 2026-06-23 · created · claude · initial landing page
- 2026-06-24 · edit · claude · reworded hero, added the contact CTA
```

## 4. Enforcement layers

```datatable
columns: Layer | Rule | Why it is needed
widths: 4cm | X | 6cm
bold: 1
tone: medium
---
Apache vhost | `<FilesMatch "\.brief$"> Require all denied` | `FallbackResource` only routes *non-existent* paths to the processor; an existing `.brief` is otherwise served raw. This is the primary guard in production.
Dev server | add `brief` to the static-serve skip list so the request routes to the processor | the dev server serves existing files raw unless excluded.
Processor | a request whose resolved path ends `.brief` returns 404 | backstop for processor-routed requests (dev server, non-existent paths).
Registries | `scan_pages` skips `*.brief` | keeps briefs out of `sitemap.xml` / `llms.txt`.
```

## 5. WebDAV and the manager

WebDAV
: `.brief` is not a blocked extension or path, so a PUT in the agent's content scope - or under `lazysite/layouts/**` with the theme/layout capability - is allowed exactly like the file it accompanies. No dav change is required beyond confirming this with a test.

Manager editor
: `brief` joins the text-editable extension list (front-end and server), so the manager renders a brief in the textarea editor. The Files-page surfacing (a "brief" indicator, and editing the brief from the file row) lands with the file-manager extensions that follow this spec.

## 6. Build sequence

```datatable
columns: Phase | Scope
widths: 3cm | X
bold: 1
tone: medium
---
1 (this spec) | The sidecar mechanism: block public serving at all four layers, confirm WebDAV writability, make briefs editable in the manager, document the convention, full test coverage.
2 (file-manager) | Surface briefs on the Files page - a has-brief / missing-brief indicator and an inline edit link - delivered with the Files-page list-by-type work.
```

## 7. Out of scope / deferred

- Hard enrolment gate (reject a content PUT without a brief) - `[DEFER]`; v1 is encouraged-and-visible.
- Structured/validated brief schema - `[DEFER]`; the format is a documented convention, parsed leniently.
- Per-file ACLs keyed off the brief - tracked separately (the roadmap "per-page ownership + per-file ACLs" item); the sidecar model here is a natural carrier for it later.

## Status (reconciled)

**SHIPPED.** Per-file .brief sidecars: authored beside any file (`<file>.brief`), surfaced in the Files page (is_brief / brief view in Manager::Files), denied at the origin so they never serve publicly. Pinned by t/integration/05-brief-sidecar.t.
