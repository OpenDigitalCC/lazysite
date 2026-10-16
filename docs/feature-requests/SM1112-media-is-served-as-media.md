---
id: SM1112
title: "SM1112: video, audio and captions are served with their own types"
subtitle: "The engine's four content-type maps know mp4, webm, ogv, mp3, ogg, wav, m4a, opus, flac and vtt, and a lint holds them to one answer per extension."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: field report, publishing interface clips to xisl.com (0.14.4), 2026-10-16
area: serving
status-note: "SHIPPED on n616: lazysite-processor.pl %STATIC_CT, lazysite-dav.pl, Lazysite::Manager::Upload, tools/lazysite-server.pl; t/lint/264, t/unit/processor/130."
---

# What happened

From the report (inbox, 2026-10-16, item 1):

> `https://xisl.com/assets/video/xitext-gtk3-print-room.mp4` answers
> `content-type: application/octet-stream` with `x-content-type-options: nosniff`.
> `.png` and `.jpg` beside it get their image types, so the MIME map lacks the
> video types (`video/mp4`, `video/webm`, and probably `video/ogg`, `audio/*`,
> `text/vtt` for captions).
>
> Chrome and Firefox still play a `<video>` from it. It is still wrong, and any
> client that trusts the type (a CDN, a crawler, a download manager) treats the
> file as an opaque binary.

Every response carried `x-lazysite-front: hestia-proxy/acl`. That is the SM283
proxy template. On a site with an ACL store, that template sends every static
to Apache, and Apache's SM223 rule sends every existing file to
`lazysite-auth.pl`. The wrapper then runs the processor, and
`_serve_content_static` takes the type from `%STATIC_CT`. That map had no media
entries, so a video fell back to `application/octet-stream`.

The engine has four content-type maps, one for each surface that hands out a
file:

- `lazysite-processor.pl`: `%STATIC_CT`, used by the public static serve.
- `lazysite-dav.pl`: `%CONTENT_TYPE_MAP`, used by DAV GET. It is kept separate so that GET loads no manager module.
- `Lazysite::Manager::Upload`: `%CONTENT_TYPE_MAP`, used by manager downloads.
- `tools/lazysite-server.pl`: `%MIME`, used by the dev server when it serves a file directly.

None of the four had media entries, and they gave different answers for the
same extension. `.ico` was `image/x-icon` on the public serve and
`image/vnd.microsoft.icon` over DAV. The dev server sent `.js` as
`application/javascript`, and sent css, txt, xml and json without the charset
that production sends.

The front-end templates set no types of their own. The only `AddType` in
`installers/` is `text/html .shtml`. nginx's fast path, used on a site with no
ACL store, uses nginx's own `mime.types`, which already has these types.

# What shipped

All four maps carry the same media set:

| Extension | Type |
|---|---|
| mp4, m4v | `video/mp4` |
| webm | `video/webm` |
| ogv | `video/ogg` |
| mp3 | `audio/mpeg` |
| ogg, oga, opus | `audio/ogg` (opus as Apache's `mime.types` has it) |
| wav | `audio/wav` |
| m4a | `audio/mp4` |
| flac | `audio/flac` |
| vtt | `text/vtt; charset=utf-8` |

Where the maps disagreed, they now give one answer. `.ico` is `image/x-icon`
everywhere, which is the public serve's spelling and nginx's. The dev server's
css, js, txt, xml and json match the processor's.

`t/lint/264` parses all four maps. It checks that every map has the media set,
and that an extension listed in more than one map has one type. The maps may
still list different extensions: the processor's map is kept small on purpose,
and an extension it does not list is served as a download.
`t/unit/processor/130` requests a file of each media type through the
processor and checks the type that comes back.
