---
id: SM1113
title: "SM1113: an engine-served static answers a byte range"
subtitle: "One bytes= range gets 206 with Content-Range, an unsatisfiable one gets 416, and every response says Accept-Ranges: bytes. Safari can play a clip from a site with an ACL store."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: field report, publishing interface clips to xisl.com (0.14.4) and edge (0.15.5), 2026-10-16
area: serving
status-note: "SHIPPED on n616: lazysite-processor/pipeline.pm _byte_range, _serve_content_static; t/unit/processor/130, t/integration/260."
---

# What happened

From the report (inbox, 2026-10-16, item 2):

> A request with `Range: bytes=0-99` gets `200` and the whole file, with no
> `Accept-Ranges` header, on xisl.com (a 3.2 MB mp4 and a png) and on edge (a
> favicon). Every response carries `x-lazysite-front: hestia-proxy/acl`.
>
> Safari and iOS will not play a `<video>` whose server ignores Range, so on
> Apple devices the clips show their poster and do not play. Seeking in other
> browsers re-downloads from the start. Video on a lazysite site needs `206
> Partial Content` for at least the asset tree.

The component that answers is the engine. The request travels this path:

1. `x-lazysite-front: hestia-proxy/acl` is the SM283 proxy template.
2. When the site has an ACL store, `installers/hestia/lazysite-proxy.stpl` sends every static extension to `@fallback`, which is Apache: `if (-f $document_root/lazysite/auth/acls.json) { return 418; }`.
3. The Apache template sends every existing file to the auth wrapper: `RewriteRule ^/(.*)$ /cgi-bin/lazysite-auth.pl [PT,L]`.
4. The wrapper checks the session and runs the processor.
5. The processor's `_serve_content_static` answers the request.

That serve had no Range handling at all. `lazysite-front.pl` said so: "byte
ranges NO. Media seeking fails wherever the engine answers a static".

Both front layers could serve these files themselves, ranges included. They
are configured not to, on purpose: SM223 hands the engine every static on a
site with an ACL store, because a file that the web server hands over cannot
be gated. That routing stays. A site with no ACL store still gets nginx's
direct serve, and nginx handles ranges natively there.

# What shipped

`_serve_content_static` honours one `bytes=` range. The range is handled after
the ACL decision and after the SM388 conditional GET, so a protected file is
refused before any byte of it is served, and a matching `If-None-Match` still
gets 304.

- `bytes=a-b`, `bytes=a-` and `bytes=-n` get `206 Partial Content`, with `Content-Range: bytes first-last/size` and a `Content-Length` equal to the span. A last byte past the end of the file is clamped to the end. A suffix longer than the file returns the whole file as a 206.
- A first byte at or past the end, or `bytes=-0`, gets `416 Range Not Satisfiable` with `Content-Range: bytes */size`.
- Multi-range, `b < a`, another unit or bad syntax: the header is ignored and the whole file is sent with 200. RFC 9110 14.2 allows this. A `multipart/byteranges` body would be a second response format for a request that no media client makes.
- `If-Range` gets the whole file. RFC 9110 13.1.5 says If-Range uses the strong comparison. The serve's only validator is the weak SM388 ETag, which never passes a strong comparison, and the serve sends no Last-Modified. A client resuming a partial copy therefore gets a fresh copy, never bytes added onto a file that changed.
- Every 200 and 206 carries `Accept-Ranges: bytes` and `Content-Length`. Cache-Control (SM387/SM416, and `no-store` on an ACL-governed file), the ETag and the security headers are the same as before.
- HEAD gets the same headers as GET and no body, and does not read the file.
- A range seeks to its first byte and reads only its span, in the same 64 KiB blocks as before (SM389).

Compression does not touch a range. The engine compresses nothing.
`t/integration/260` runs a real Apache with `SetOutputFilter DEFLATE` on every
response. In that test a whole text file comes back gzipped, and a 206 of the
same file comes back as plain bytes, because mod_deflate leaves a response
with `Content-Range` alone. nginx's gzip filter acts only on 200, 403 and 404.

That run also measured something about Apache's CGI handler: it drops the
script's `Content-Length`. A span that Apache can buffer whole gets a length
that Apache computes. A larger span goes out chunked, with or without DEFLATE.
A chunked 206 is valid HTTP/1.1, because `Content-Range` carries the span.

`t/unit/processor/130` drives the processor CGI. It covers each range form,
416, the cases that are ignored, If-Range, 304 winning over a range, HEAD
against GET, and the ACL coming before the range. `t/integration/260` drives
real Apache, the auth wrapper and the processor behind the template's SM223
rewrite.

The dev server, `tools/lazysite-server.pl`, still serves a site with no ACL
store directly, over HTTP/1.0, with no Range support. That is the stand-in for
nginx's fast path, which does handle ranges.
