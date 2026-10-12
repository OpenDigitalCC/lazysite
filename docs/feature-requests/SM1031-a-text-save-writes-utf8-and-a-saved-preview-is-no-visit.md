---
id: SM1031
title: "SM1031: a text save writes UTF-8, and a saved-page preview is no visit under the owner's Host"
subtitle: "Three findings from SM1030, ruled together: a text save wrote bytes that are not UTF-8, and preview_page on a saved page recorded a visit and rendered under the MCP request's Host."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: found working SM1030 (its "Found on the way"); ruled by the release manager 2026-10-12, "Fix all three"
area: mcp
status-note: "SHIPPED (PENDING): every text save refuses content that would not be written as valid UTF-8 (page-encoding-refused); a saved-page preview_page writes no access-log line and renders under the owning domain's Host at the URL it serves the page at (t/unit/mcp/50)."
---

# The ruling

Release manager, 2026-10-12: "Fix all three" - the three findings SM1030
recorded and left unchanged.

# What was found

(a) **A text save wrote bytes that are not UTF-8.** `write_file_checked`
encodes through the lax `:utf8` layer, which writes a character string's
internal bytes as they are. A JSON body carrying the raw bytes `ED A0 80`
decodes to U+D800, a lone surrogate, and was written back as `ED A0 80`;
`F4 90 80 80` decodes to U+110000 and was written the same way; and a page
put on disk by git or SSH with an overlong form (`C0 AF`), read laxly by
`copy_file` or `replace_text`, was written on unchanged. Q15h's
`page_bytes_refusal` keeps such bytes off the disk on every RAW door; its
comment said a text write could not produce them.

(b) **A saved-page `preview_page` recorded a visit** in the first-party
access log. A draft preview never did (SM1030).

(c) **A saved-page `preview_page` rendered under the MCP request's Host.**
A domain's page was shown in the primary's layout and theme, and a primary
page asked for over a domain's Host was resolved against that domain's
content root - measured: `/about` over `mine.test` rendered the domain's own
about page. `preview_public_page` has rendered under the owning domain since
SM441, and a draft preview always has.

# What was built (n481)

- `Manager::Common::text_save_refusal` asks of the bytes a text save WOULD
  write what Q15h asks of raw bytes, for any file (a text save is text whatever
  its extension). It is the first check in `Files::_content_write_refusal`, so
  every text door - the control API's `save`, MCP `write_file`, `replace_text`,
  `copy_file`, `create_page`, `create_form`, and a draft preview - answers
  `page-encoding-refused`, naming the offset, and writes nothing. A string with
  no wide characters is written byte for byte as Latin-1, which is always
  UTF-8, so only a character string is judged.
- `preview_page` on a saved page sets `LAZYSITE_PREVIEW`, and the processor's
  access log leaves such a render out, as it leaves out a draft.
- `preview_page` on a saved page renders under the Host of the domain that
  owns the path, at the URL that domain serves it at, with every credential
  and identity marker stripped as the draft render strips them; with no owning
  domain it renders as the primary, whatever Host the request came in on. The
  answer names `rendered_as_host` when a domain owned the path.

Tests: t/unit/mcp/50 - a surrogate and a code point past U+10FFFF over
`write_file` (a new page, an existing page, a non-page file),
`replace_text` and `create_page`; an overlong page through `copy_file` and
`replace_text`; the control API `save`; the access log before and after a
saved and a draft preview; a domain's page and a primary page over a domain's
Host. Reproduced on n480 first. Sabotage (four, each caught, restored and
compared): the text-save refusal, the access-log guard, the owner Host, the
owner-relative URL.

# Not changed

`preview_public_page`, the manager's preview and the domain preview also
render through the processor; whether they record a visit was not measured
here (a probe could not run the manager's processor path in the test rig).
