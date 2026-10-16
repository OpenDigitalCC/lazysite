---
id: SM997
title: "SM997: a nav address cannot run script"
subtitle: "The nav parser stored a javascript: address as written, and every layout puts a nav address in an href. Refused at write on every surface, neutralised at render, reported by validate and check."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-11
raised-by: WORK-PLAN-0153 follow-up, listed as WORK-PLAN-0154 P23; ruling of 2026-10-12
area: security
status-note: "SHIPPED (0.15.5): nav-save, set_nav, a WebDAV PUT of a nav file and a file-editor save of one refuse an address whose scheme is not http, https, mailto or tel (the | url_safe rule); parse_nav renders one as # and logs it; lazysite validate and lazysite check name it (t/integration/132, t/unit/processor/100, lint 223)."
---

# The ruling

Refuse or neutralise unsafe URL schemes (`javascript:`, `data:`, `vbscript:`,
...) in nav.conf at write (set_nav/nav-save/WebDAV PUT of nav.conf) and at
render; existing entries render as `#`, logged; validate/check report them.

# The rule

The one SM970 gave `| url_safe`: an address may be a link when, read as a URL,
it has no scheme (a relative path, `/abs`, `?q`, `#frag`, `//host`) or one of
http, https, mailto, tel. Anything else is unsafe - which is stricter than a
deny-list of `javascript:`/`data:`/`vbscript:`: `ftp:` or `file:` is refused
too, and the scheme is read through character references and percent-encoding
as `| url_safe` reads it, so `jav&#x61;script:` is caught. One rule for a link
target, in templates and in the nav.

The render path loads nothing from lib/ (ADR 0001), so the writes use a marked
copy, `Lazysite::Util::unsafe_link_scheme`, and `nav_unsafe_entries` reads a
nav file as `parse_nav` does. Lint 223 runs the copy and the processor's
`_url_safe_filter` over 35 texts (the encoded and whitespace spellings
included) and requires the same answer.

# Where it applies

- **Write, refused, nothing written**: `nav-save` (control API) and `set_nav`
  (MCP), through `Manager::Nav::action_nav_save`, kind `nav-unsafe-url` (400,
  listed in lint 139's deliberate-400 set beside `nav-not-here`); a WebDAV PUT
  of any configured nav file, 422 like a form's conf; a save through
  `Manager::Files::action_save` (the editor, MCP `write_file`) of a path that is
  a domain's resolved nav file. The message names each entry (line, label,
  scheme) and what a nav address may be. The refusal carries `audit_detail`,
  so the surface's audit row records it.
- **Render**: `parse_nav` (lazysite-processor/sources.pm) renders such an
  address as `#` and logs WARN "a nav entry whose address has an unsafe scheme
  is rendered as #" with the nav file's relative path, the label and the scheme.
- **Report**: `lazysite validate nav.conf` (any `nav*.conf`) reports each as an
  ISSUE `nav-unsafe-url` with its line, exit 1; `lazysite check` names every
  entry in every nav file the instance renders (lazysite/nav.conf, `nav_file:`
  and each `alias.<host>.nav_file:`), or says there is none.

Not covered at write: upload, copy, move or a site-package apply landing a nav
file. Each still renders through `parse_nav`, so the address is `#` on the
page and `lazysite check` names it.

# Found while building it

- The configuration doc describes a YAML nav format (`- label: ... url: ...`)
  that `parse_nav` does not read: it reads `Label | url` lines only. Not
  changed here; recorded in WORK-PLAN-0154's open questions.
- t/unit/processor/98's `with_log` returns the log with `do { local $/; <$fh> }`
  in list context, which is an empty list for an empty log and shifts the
  results into its place. Test 100 reads it in scalar context; 98 always logs,
  so it is not affected today.

# Tests

t/integration/132: nav-save and set_nav refuse `javascript:`, `data:` in a
child and an entity-spelt scheme, the file unchanged; a safe nav (a path,
mailto:, https:, a heading) saves on both; MCP write_file of the resolved nav
file is refused and of another .conf is not; a WebDAV PUT is refused with 422
leaving no temporary file, a safe one written; validate exits 1 naming the line
and 0 on a safe file; check names the entry and says when there is none.
t/unit/processor/100: four unsafe entries render as `#`, five safe ones pass,
each neutralised entry is logged once by relative path. Lint 223: the copy and
the render agree.
