---
id: SM1225
title: "SM1225: a report is a download"
subtitle: "A report came back as base64 inside a JSON answer. A binding with answer: download is answered to a GET with the document itself, its content type, a safe file name and a size cap."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-20
raised-by: "OOM Lab findings L-22 (payslip PDF, 2026-10-19) and the quotation app (2026-10-17); ruled 2026-10-20"
area: odoo
status-note: "SHIPPED (PENDING) on n710: binding option answer: download (+ download_max_kb, download_disposition); GET answers the document, no-store, nosniff, safe name, 413 over the cap. t/unit/odoo/100, 101, t/integration/330."
---

# What happened

OOM Lab L-22: "A report PDF through the endpoint takes about 5 s, which is Odoo
rendering, and comes back as ~31 KB of base64 in one JSON answer. That works at this
size; a large report would want a download route." The quotation app met the same
with `core.report inline=1` (OOM 0.32+), which returns each document as
`report.rows[].content_base64`. Ruling, 2026-10-20 (OOM Lab questions): "build the
download route (a binding option answering the report as a GET with its content type
and a size cap; replaces base64-in-JSON; covers the quotation PDF and L-22)".

# Cause

The endpoint (lazysite-odoo.pl) answered every successful call with the engine's answer
as JSON (`_answer`), so a document could leave only as text inside it, and a page had to
decode it in JavaScript and build a Blob.

# What shipped

- Binding option `answer`: `json` (the default, unchanged) or `download`. Saving a
  download binding on an operation that writes, or with `scheduled` in its modes, is
  refused; so is `download_max_kb` / `download_disposition` on a binding that answers JSON.
- `download_max_kb` (default 10240, ceiling 20480) and `download_disposition`
  (`attachment`, the default, or `inline`; html is always an attachment).
- A GET of such a binding runs the call exactly as before (gate, callers, session or
  visitor key, rate caps, record, audit; in-process or oomd) and answers the one
  document it returned: `Content-Type` from OOM, `Content-Disposition` with a safe name
  (last path part, ASCII letters, digits, `. _ -` and space, at most 100; no quote,
  semicolon, line break or control character), `Content-Length`,
  `Cache-Control: private, no-store`, `X-Content-Type-Options: nosniff` and a sandbox
  `Content-Security-Policy`. A type that is not a `type/subtype` name is
  `application/octet-stream`.
- Over the cap: `413 too-large`, JSON, naming the size and the cap, read from the
  base64's length before it is decoded; never truncated. Not exactly one document:
  `400 invalid`. A POST of a download binding: `405 method`.
- The manager's binding editor lists the three keys; Lazysite::Odoo::Binding validates
  them. Documented in starter/docs/odoo.md.
- New module Lazysite::Odoo::Download; test operation shop.document (t/lib).

Tests: t/unit/odoo/100 (OOM's fake Odoo: bytes and headers, JSON unchanged, cap, one
document, hostile file names, inline, gate, POST, rate), 101 (the real oomd),
t/integration/330 (a signed-in group member is given the binary document; signed out,
outside the group and a forged cookie are refused with nothing reaching Odoo).

# Not done

- The control API and MCP (`odoo-run`) still return the JSON report for such a binding:
  they are not a browser fetching a link.
- A page binding (`odoo:ID`) of a download binding would put the base64 in the page
  variable; it is not refused.
- A report over OOM's own `max_inline_bytes` (10 MiB by default) is refused by OOM
  first; a larger download needs a streaming route (OOM `dir`, not `inline`).
