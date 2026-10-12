---
id: SM1030
title: "SM1030: preview_page renders a draft and writes nothing"
subtitle: "MCP preview_page accepts draft content and renders it server-side against the site's real layout and theme without writing anything, so an MCP-connected editor can check a page before saving it - the SM887 skill's job, with nothing to install."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: the coordinating session's proposal, ruled by the release manager 2026-10-12 ("yes queue the preview_page draft change"); recorded in SM887
area: mcp
status-note: "SHIPPED (PENDING): preview_page { path, content } renders the draft at path as a public visitor, under the owning domain's Host, and writes nothing; refused for what a save would refuse, capped at 512 KiB (t/unit/mcp/40, 41)."
---

# The ruling

The release manager, 2026-10-12: "yes queue the preview_page draft change" - the
coordinating session's proposal: MCP `preview_page` accepts DRAFT content (a
`content` argument, as validate_page does) and renders it server-side against
the site's real layout and theme WITHOUT writing anything, so an MCP-connected
editor can check a page before saving it (the SM887 skill's job, with nothing
to install).

# What it does

`preview_page { path, content }` renders `content` at `path` in place of the
saved page and answers as `preview_page` does - `status`, `html`, `bytes`,
`truncated` - plus `draft: true` and, for a page a configured domain owns,
`rendered_as_host`. Without `content` the tool is unchanged.

| Decision | Why |
| --- | --- |
| `path` stays required; a draft is never rendered at a neutral path | The path decides the owning domain (its layout, theme and nav), the access rules and where includes resolve, and it is what the dispatcher's scope and carve-out checks ask about. A neutral path would dress every draft as the primary site - for a domain-confined caller, a site it does not reach. A missing path is refused by the schema, naming `path`. |
| The render is the public view, as `preview_page` already gives | An anonymous visitor's render: a gated draft shows the gate (302 to sign-in), a draft declaring `auth: required` likewise. A `db:` binding renders what it renders for a visitor - no `(mine)` rows, none of the caller's own read rights - which is what `preview_page` does for a saved page. |
| Under the owning domain's Host, at the URL it serves the page at | The domain's own layout and theme apply (`content_root_for_path`). The processor refuses (422) if the request does not resolve to exactly the named page, so a Host or content root can never render the draft in another page's place. |
| Refused for what a save would refuse | `Manager::Files::draft_refusal` asks what `action_save` asks: the path (validate_path, both blocklists), the content (`_content_write_refusal` - raw HTML, template parse, brief, nav, form binding - now one sub that action_save calls too) and the file ACL's write gate. Added: `page_bytes_refusal` on the bytes the draft would be written as, and the carve-outs in their WRITE sense (the dispatcher asks every preview in the read sense). Not asked, because nothing is written: the active/served artifact rules (a layout's or theme's files), the edit conflict and the lock. |
| 512 KiB cap | Neither `write_file` nor `validate_page` has a cap to match. The connector's text bound is `$MAX_READ_BYTES`, which `read_file` already refuses above; a draft is held to it, and the processor holds the same number on its side. |
| Not audited when it succeeds | SM943: a read is not audited unless it fails. Each refusal writes its one `fail` row. |

# Nothing is written - how

The draft travels on the processor's STDIN, never through a file, with
`LAZYSITE_DRAFT_PATH` naming the page. The processor (`lazysite-processor/
request.pm`) reads it whole at the top of `main()` - before anything is printed,
so the writer and the reader cannot wait on each other - and only on the
single-shot CGI path for a GET: a pooled worker's STDIN is the FastCGI socket and
a POST's is a visitor's body, and a web server hands a CGI no environment
variable a visitor chose. The bytes must be strict UTF-8 and within the cap.

Two layers keep it off the disk:

1. `main()` marks a draft request protected, as it does a gated page or a
   preview cookie: never read from or written to the page cache, no
   content-type or dependency record, no registry update.
2. Every writer a render can reach refuses a draft request on its own
   (`_draft_requested`): the page cache, the content-type and dependency
   records, the registries, the cached error pages, a form's derived rules
   (which would otherwise overwrite the LIVE form's validation rules with the
   draft's), the form secret's mint, the access log (a draft render is no
   visit), a remote layout's cache, and the TT compile cache (the draft renders
   compile in memory).

The TT compile cache is never keyed by the draft in any case: the content pass
renders a string, which TT does not cache, and the layout's cache entry is keyed
by the layout file. It is still left alone, so the proof below can be "no file
changed" rather than "no file that matters changed".

# Tests

t/unit/mcp/40 (over the MCP CGI, on a COLD site - nothing rendered yet, so
every cache, compile cache, log, secret and registry a first render would make is
still to be made): a draft renders with the primary's theme; a domain's draft
renders under its Host with the domain's theme, at a page and folders that do
not exist yet; a folder path previews its index; a form draft renders its new
field; a gated draft and an `auth: required` draft show the gate. A snapshot of
every file under the site - docroot, private store, engine tree, caches, logs,
forms, history - by mode, size, mtime and SHA-256 is identical after them, and
the live form's rules do not carry the draft's field. Refusals: not UTF-8 (a
lone surrogate, which the wire carries and the server's decoder accepts - offset
named), a form the caller does not reach, a template that does not parse, the
ACL write rule, 512 KiB, the engine tree; scope enforced on the path. The seven
refusals leave seven audit rows and nothing else.

t/unit/mcp/41 (the processor directly): the draft renders in the page's place
with `no-store`; refused (422, marked) on a POST, on a request resolving to
another page, on a climbing, absolute or non-page path, on a surrogate, a stray
byte, one byte over 512 KiB; exactly 512 KiB renders; nothing written; without
the variable STDIN is ignored.

Sabotage (ten, each caught, each restored and compared): the access-log guard,
the form-rules guard, the layout compile-cache guard, the UTF-8 refusal, the
save's refusals, `path_args`, the owning Host, the processor's path binding, the
GET-only rule and the processor's UTF-8 check.

# Found on the way

- **`write_file` can write a page that is not UTF-8.** A JSON body carrying a
  lone surrogate's three bytes (what a JSON encoder writes for one) is accepted
  by the server's decoder, and the text save writes them through the lax `:utf8`
  layer - the page `page_bytes_refusal` exists to keep off the disk, by the one
  door its comment says cannot produce one. A draft is refused for it here; the
  save is not changed by this filing. Ruled 2026-10-12, "Fix all three": SM1031.
- **The saved-page `preview_page` records a visit** in the first-party access
  log, as an anonymous request with no user agent, and runs under the MCP
  request's Host rather than the owning domain's (which `preview_public_page`
  has done since SM441). Both unchanged here; the draft path does neither.
  Ruled 2026-10-12, "Fix all three": SM1031.
