---
id: SM1162
title: "SM1162: a binding takes a file (a receipt photo is one multipart request)"
subtitle: "A binding may map a request file field to an operation's file parameter; the Odoo endpoint takes multipart/form-data under a size cap the binding states, the type is read from the bytes, and the bytes reach the operation, in the process or through oomd, without being written or echoed."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-17
raised-by: lazysite-sites agent, OOM Lab expense app (inbox 2026-10-17-oom-lab-expense-app-a-binding-cannot-carry-a-file.md, L-9); OOM agent, inbox 2026-10-19-oom-0.34-file-cache-json.md
area: odoo
status-note: "SHIPPED on n656 (base 4c4798a6c, OOM 0.34 by SM1177): file_params, file_max_kb and file_types on a binding; multipart on the Odoo endpoint; the helper sends a File as FormData; tests t/unit/odoo/66 (endpoint, in-process), 67 (the real oomd) and 68 (the helper, in node)."
---

# The finding

OOM Lab, expense app, L-9 (lazysite-sites agent, 2026-10-17):

> A binding takes no file, and a value is at most 1,000 characters in a request
> of at most 64 KB. A receipt photo can therefore reach Odoo only by the page
> compressing it to about 35 KB of JPEG and sending it as 48 text parameters (the
> lab does this; it works, and it caps the photo's quality). A `file` parameter
> type - multipart upload on the endpoint, a size cap set on the binding, the file
> handed to the operation without passing through a request value, never echoed -
> would make attachments (receipts, delivery photos, signed documents) an ordinary
> binding.

# What OOM shipped

OOM 0.34 (inbox 2026-10-19-oom-0.34-file-cache-json.md, "File parameters"), taken
into the tree by SM1177:

> - **The value** in the library and `Odoo::Ops::Client::Daemon`: `{ name =>
>   'receipt.jpg', bytes => $raw, mimetype => 'image/jpeg' }`. `mimetype` is
>   optional; absent, OOM reads it from the first bytes (JPEG, PNG, GIF, WebP,
>   PDF), else `application/octet-stream`.
> - **On the oomd socket** the client sends `{"name","base64","mimetype"}`; the
>   daemon decodes it. No path on the OOM host is needed.
> - **Checks:** `bytes` at most the declaration's `max_bytes` (default 25 MB), else
>   `refused/too-large`; `name` a plain file name (no slash, backslash or NUL, not
>   `.` or `..`, at most 255 bytes).
> - **Bytes never appear** in a plan, journal, audit line, `--json` output or error:
>   the plan shows `{name, bytes, sha256, mimetype}`, and the bytes sit in the run's
>   blob store.
> - **Takers:** `core.attach` (`file` with `model` and `record`, optional `name`,
>   `mimetype`, `replace`); `crm.attach` (`file`); `discuss.post` (`files`, a list,
>   with paths at most 10); `core.make` and `core.set` (`set.<field>` of a binary
>   field).
> - **Your own form check:** `Odoo::Ops::File->check($op, $name, $value, \%decl)`
>   applies the same rule and throws the same error.

# What shipped

- **Three binding keys** (flat, like `rows_max`; offered in the Handlers form):
  `file_params` (`field=parameter`: a request file field into a parameter the
  operation declares as `file` or `files`, or a `set.<field>`), `file_max_kb` and
  `file_types`. A file is a source of its own: a parameter has one source, and a
  plain `params` mapping into a file parameter is refused at save, naming
  `file_params`.
- **`file_max_kb` is required** when a file is mapped (refused at save, as
  SM1166's R2 does for rows), never above the operation's `max_bytes` for that
  parameter (checked when the operation's declaration can be read, at save and at
  the call) and never above the endpoint's **ceiling of 20 MB** for one file
  (`$Lazysite::Odoo::Binding::FILE_CEILING_KB`), which is the binding's own error
  and not OOM's. A body is also never held above 32 MB (`$Lazysite::Odoo::Upload::MAX_BODY`).
- **Multipart on the endpoint**, `lazysite-odoo.pl`: `POST multipart/form-data` with
  `?binding=ID` in the query. The binding is in the query because its cap decides
  the body's allowance before the body is read. Order of refusals: a boundary, the
  binding named, found, reachable from the address, mapping a file, then the declared
  `CONTENT_LENGTH` against the binding's allowance (`file_max_kb` for each file the
  operation can be given, the 64 KB JSON part, the framing; the operation's own
  `files` `max` counts), `413 too-large` naming the cap, **the body unread**. Then
  the body is read, parsed strictly (`Lazysite::Odoo::Upload`: the part `json`, a part
  per file; a text part, a nameless part, a duplicate `json` is refused, not ignored)
  and handed to `_post_one`, the function every JSON call goes through, so the
  tokens, the mode, the callers, the address rules, SM1168's sign-in-first answer,
  the rate caps and the call record all run unchanged. The JSON limit of 64 KB stays
  for the JSON part. A **multipart batch is refused by name** (`a batch carries no
  files`), and so is a confirm, a sign-in and a sign-out.
- **The type is read from the bytes.** OOM's `Odoo::Ops::File->sniff` decides; the
  operation is given that type, not the browser's. `file_types` (type/subtype
  names, lower case, no wildcard) holds it: a PDF sent as a `.jpg` is
  `application/pdf` and is refused where only images are taken. A type the browser
  claimed that the bytes contradict is refused whether or not `file_types` is set.
  Then OOM's own `check` (a plain name, `max_bytes`) runs on the value, with the file
  name cut to its last component.
- **To the operation as `{name, bytes, mimetype}`**, in the process and through the
  daemon client alike (test 67 runs the real oomd and the operation, in another
  process, reports the sha256 of the bytes it saw). For `discuss.post`'s `files` the
  binding may map a list: up to the operation's `max` (10), each file checked, a
  refusal naming which (`'shots' file 2`). A `file` parameter takes exactly one.
- **Never written, never echoed.** The bytes are held in memory from the read to the
  operation: no temporary file exists, so none can be left by a success, a refusal or
  an operation that dies, and nothing is written to the served tree. They are taken
  out of the context before it is copied (`Lazysite::Odoo::call` removes `files` at
  once). The answer, the call record (its fixed field list is unchanged), the audit
  line and the log carry no bytes; the log has one line per file, `a file was given
  to an operation`, with the call id, the binding, the operation, the name, the size,
  the SHA-256 and the type. Where an operation puts a file in its plan (OOM keeps an
  attachment's bytes once in the plan's `blobs/` folder so that a confirm can apply
  them), they sit in that plan's own folder in the private store
  (`lazysite/odoo/plans/<id>/`, 0600, base64), which is removed with the plan
  after its days.
- **The helper** (`starter/assets/lazysite-odoo.js`): `LazysiteOdoo.write(binding,
  params)` with a `File`, a `Blob` or a list of them among the params sends a
  `FormData` (the plain params and the token as the part `json`, a part per file, the
  binding in the query), with the JSON path's retries (a stale token once, a sign-in
  once, the body built again each time). A call with no file is the JSON POST it
  was. `batch` rejects a call that carries a file, by name, before sending.
- `starter/docs/odoo.md` documents the three keys, the multipart request, the
  helper's use of it and the `too-large` kind.

# Not decided here

Whether a plan's blobs should be removed as soon as the plan is applied rather than
with the plan's days (OOM's journal may still read them for a rollback). Nothing in
this change touches that.

# Evidence

`t/unit/odoo/66-a-binding-takes-a-file.t`, on OOM's fake Odoo, driving the endpoint
as a CGI: a file under the cap reaches the operation with the right sha256, name and
type (and a list of three); saving refuses a file with no `file_max_kb`, a cap above
the operation's `max_bytes` or the ceiling, a file into a non-file parameter, a
second source; a `CONTENT_LENGTH` of 10 MB or 900 MB with a short body is refused
`413 too-large` and `tell(STDIN)` is 0; PDF bytes under a `.jpg` name and a jpeg
claim, JPEG bytes claimed as PNG and text claimed as an image are refused; the whole
site tree and the log are searched for a marker in the bytes and hold none; no
temporary file appears after a success, a refusal and an operation that dies; the
token, mode and sign-in-first checks answer as before; a multipart batch is refused.
`t/unit/odoo/67` runs the real oomd. `t/unit/odoo/68` runs the helper in node.
Before the change the first test fails at the first binding (`file_params` is not a
key of an Odoo binding). Sabotage: see the commit message.
