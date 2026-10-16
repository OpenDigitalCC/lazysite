---
id: SM1114
title: "SM1114: a failed WebDAV PUT leaves nothing behind and says why"
subtitle: "The temp file goes on every failure, a cut-off body is refused rather than stored, a full disk is a 507, and a leftover is neither listed nor kept."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: the xisl.com site session, 2026-10-16
area: dav
status-note: "SHIPPED on n617: lazysite-dav.pl do_put / _stream_body / _write_failure; t/unit/dav/33. The bare 500 itself is the hosting front's, see What the front does."
---

# What happened

From the xisl.com report (video assets, item 3):

> On xisl.com, after about 3.6 MB of video had gone in, every PUT larger than
> about 150-300 KB answered `500 Internal Server Error`. The body was the
> hosting front's generic page, with nothing from the engine. [...] One failed
> 7.5 MB PUT left `/assets/video/xitext-motif-print-room.mp4.tmp.545808` in
> the tree, visible over WebDAV, until it was deleted by hand.

and its correction the same evening:

> it was probably not the disk. [...] A failure that clears with time and not
> with space points at a time-windowed limit or the front proxy's request-body
> buffering, ahead of the engine. The engine's own WebDAV throttle answers 429
> and its write failures 507/500 with a body, and none of those appeared.

The engine removed its temp file on only three failures (open, over-size,
close). Four more left it, or worse:

- A body shorter than CONTENT_LENGTH (client gone, proxy cut it off) was
  renamed into place as if it were the whole file.
- A write error was looked for only at close.
- A die between creating the temp and renaming it left the temp behind and
  answered nothing from the engine.
- SIGTERM or SIGPIPE, which is how a front's timeout reaches a CGI, ended the
  process with the temp on disk.

A leftover `name.tmp.<pid>` was listed by PROPFIND like any file.

# What shipped

- Every exit from a PUT removes the temp: the handler, an END guard, and
  handlers for SIGTERM, SIGPIPE and SIGHUP that exit so the guard runs.
- A body that ends before CONTENT_LENGTH answers 400, saying how many bytes
  arrived of how many, and stores nothing.
- A write error is caught at the write, not only at close. ENOSPC and EDQUOT
  answer 507 Insufficient Storage with a body naming the cause and who must
  act; any other error answers 500 with the errno text in the body.
- A die between create and rename answers 500 from the engine ("Cannot store
  the file"), logs the cause, and removes the temp.
- PROPFIND does not list names ending `.tmp.<digits>`.
- A successful PUT removes older-than-an-hour `<name>.tmp.<digits>` siblings of
  the same name. A fresh one is kept: it is another client's upload in flight.
  The scheduler has no docroot sweep (its jobs are session, connector and
  stats records), so none was added for a leftover that only a SIGKILL can now
  produce.

Not shipped: free space against quota in `lazysite check` or the manager. The
engine cannot read an account quota portably; that is a separate request.

# What the front does

The engine cannot fix a bare 500 from the front. The shipped templates set:

- `installers/hestia/lazysite-proxy.stpl:85` (and `.tpl:63`):
  `client_max_body_size 64m;`. A larger body is a 413 from nginx, not a 500.
- No `proxy_request_buffering`, `proxy_read_timeout`, `proxy_send_timeout` or
  `proxy_connect_timeout` anywhere in the hestia templates, so nginx defaults
  apply: the body is spooled to nginx's own `client_body_temp_path` before it
  is passed on, and each proxy read or send gives up after 60 seconds.
- `/dav` is passed to Apache (`lazysite-proxy.stpl:109`) and run there as a
  CGI through `ScriptAlias` (`lazysite-cgi.tpl:27`, `lazysite-fcgi.tpl:31`).
  Neither Apache template sets `LimitRequestBody` or a `Timeout`.
- The stock Apache examples set `LimitRequestBody 67108864` (64 MB, for
  example `installers/apache/vhost-cgi.conf.example:34`) and the nginx
  examples set the same 64 MB (`installers/nginx/vhost-fcgi.conf.example:49`).

Nothing here gives a bare 500 at 150-300 KB, and no template was changed. A
500 that depends on size and clears with time is outside the templates. The
operator should look at, in this order:

1. nginx's error log for the domain, around the failed PUT: a line naming the
   body temp file ("failed (28: No space left on device)", a permission or
   quota error on `client_body_temp_path`) is a 500 produced by nginx, and
   would not be visible to the account.
2. Apache's `/var/log/apache2/domains/<domain>.error.log`: "Premature end of
   script headers", a script timeout, or a suexec refusal is a CGI fault; the
   engine log (`lazysite/logs`) then has no `dav put` line for that request.
3. Anything on the account that throttles by time: Hestia's per-account
   resource limits, fail2ban or rate-limit rules in the front.

If the engine log has a `dav put died`, `storage full` or `write failed` line
for the request, the engine answered and the front replaced the body.
