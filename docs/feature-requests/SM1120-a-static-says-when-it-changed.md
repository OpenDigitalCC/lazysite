---
id: SM1120
title: "SM1120: an engine-served static says when it changed"
subtitle: "Last-Modified on every response, If-Modified-Since answered, and an If-Range carrying that date honoured, so a client can resume a partial copy of a file that has not changed."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-17
raised-by: release manager, 2026-10-17 (task #336, SM1113 follow-up)
area: serving
status-note: "SHIPPED on n623: lazysite-processor/pipeline.pm _serve_content_static, _http_date, _parse_http_date; t/unit/processor/131, t/integration/261."
---

# What happened

SM1113 gave an engine-served static a byte range and left one case behind. Its
filing says: "`If-Range` gets the whole file. RFC 9110 13.1.5 says If-Range
uses the strong comparison. The serve's only validator is the weak SM388 ETag,
which never passes a strong comparison, and the serve sends no Last-Modified."

A browser resuming a download or a player re-fetching the rest of a clip sends
`If-Range` with the validator it was given. With only a weak ETag to give, every
such request got the whole file again. The release manager, 2026-10-17: "yes to
Last-Modified".

# What shipped

`_serve_content_static` sends `Last-Modified`: the file's mtime as an RFC 9110
IMF-fixdate in GMT, built by hand so the names never follow the process locale.
It is on every 200, 206, 304 and 416 and on HEAD, which agrees with GET.

- `If-Modified-Since` answers `304` when the file is not newer than the date,
  to the second. It is read only when the request has no `If-None-Match`
  (RFC 9110 13.2.2): a client that sent an ETag and did not match is sent the
  file whatever its date says. A date that is not an IMF-fixdate is ignored.
  The 304 carries `Last-Modified` and the ETag.
- `If-Range` with an HTTP-date honours the range (`206`) only when the date
  equals `Last-Modified` exactly AND `Last-Modified` is at least a second behind
  the clock (RFC 9110 13.1.5: a date is a weak validator if the file could
  change again within the second it names). Any other date, a date that does
  not parse, or a file written this second gets the whole file with `200`. An
  `If-Range` carrying an entity-tag keeps today's answer, the whole file,
  because the ETag is weak.
- Not changed: Cache-Control, the ETag, the order of the ACL check, the SM388
  ETag conditional, compression, or the range code beyond the If-Range decision.

An ACL-governed file sends `Last-Modified` too, beside its `no-store`. It leaks
nothing: the response already goes only to a reader the ACL passed, and a
modification time tells that reader nothing the bytes do not. A refused reader
gets the redirect or the 403 and no date.

# Other places that serve a static

SM1112 found four content-type maps. Whether each sends `Last-Modified` today:

- `lazysite-processor/pipeline.pm` (`%STATIC_CT`, `_serve_content_static`): did
  not; now does. The only one changed.
- `lazysite-dav.pl` GET: already sends `Last-Modified` (strftime, GMT) and an
  ETag, no Range and no conditional handling. Not changed.
- `lib/Lazysite/Manager/Upload.pm` (`%CONTENT_TYPE_MAP`): a type table for
  uploads, serves nothing. Not changed.
- `tools/lazysite-server.pl` (`%MIME`, the dev server's direct static serve):
  sends no `Last-Modified`, no ETag, no Range. It stands in for nginx's fast
  path, which sends all three itself. Not changed.

`t/unit/processor/131` drives the processor CGI: the date on 200, 206, 416, 304
and HEAD and on an ACL-governed file, If-Modified-Since both ways, If-None-Match
winning, and If-Range with the exact date of an old file, a different date, an
unparsable date, a file newer than the clock, and an entity-tag. `t/integration/261`
checks the header through a real Apache.
