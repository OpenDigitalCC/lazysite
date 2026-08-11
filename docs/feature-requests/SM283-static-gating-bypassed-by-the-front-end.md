---
title: "SM283 - A protected section gates its pages and serves its images, PDFs and text to anyone"
subtitle: "SM223's enforcement is correct. Most static requests never reach it, because lazysite's own nginx guidance tells the front end to serve them directly - and which ones gate is decided by file extension."
brand: plain
status: candidate
status-note: "FILED 2026-08-11 from the site agent's brief of 2026-08-10, re-confirmed against 0.10.6 on 2026-08-11 with the correct Apache template installed. NOT FIXED. This is a LIVE, FAIL-OPEN DISCLOSURE on deployed sites: anonymous requests retrieve byte-identical copies of gated .png, .pdf, .txt and .bin files. Measured, not inferred - same 11829 bytes uploaded under five extensions into one ACL'd folder, four served, one gated. ROOT-CAUSED 2026-08-11: every template lazysite ships already carries the ACL branch, but all four HESTIA templates are Apache and no Hestia NGINX PROXY template is shipped - so Hestia's own default proxy serves its static extension list directly and Apache never sees those requests. Sized S-M: the logic exists and is proven, it is in the wrong file for this deployment shape."
---

# SM283 - the front end serves what the ACL refuses

## The measurement

One folder, one ACL (`upcoming`, owner/read/write `claude-code`), and the **same
11829 bytes** uploaded under five extensions so nothing varies but the name:

```
upcoming/pricing            302  -> /login?next=%2Fupcoming%2Fpricing
upcoming/probe.dat          302  -> /login?next=%2Fupcoming%2Fprobe.dat
upcoming/secret-asset.png   200  11829 bytes, byte-identical
upcoming/probe.bin          200  11829 bytes, byte-identical
upcoming/probe.txt          200  11829 bytes, byte-identical
upcoming/probe.pdf          200  11829 bytes, byte-identical
```

Fetched anonymously, with no credential of any kind. `cmp` against the source
returns identical for each 200.

Re-measured on 0.10.6, before a rebuild, after a rebuild, and after the new
Apache template was installed - identical status codes and identical response
headers all three times.

## Why `.dat` is the important line

`.dat` gates. That proves [[SM223]] works: **where a request reaches lazysite,
the ACL is enforced exactly as designed.** The failure is entirely about which
requests get there, and that is decided by extension - which is to say, by
whichever list the front end happens to treat as static.

**Deciding this by extension cannot be made safe.** Any list is a list of the
types that happen to be protected, and everything left off it is silently public.

## The cause is ours

Not the guidance, as an earlier draft of this filing said - see ROOT CAUSE below,
which supersedes that reading. `tools/lazysite-nginx-vhost.pl` describes serving
per-domain statics directly, and it pairs that with the ACL branch that makes it
safe. The defect is that on Hestia the layer doing the serving is one we ship no
template for at all.

It is still a product defect rather than a deployment quirk: lazysite supports
Hestia as a first-class target, ships four templates for it, and none of them is
the one that answers these requests.

The disclosed responses point straight at it: a served file carries
`expires: Thu, 31 Dec 2037`, an `etag` and a `last-modified`, and **none** of
`x-content-type-options`, `x-frame-options` or `referrer-policy` - which lazysite
puts on everything it serves, its own 404 included. The auth wrapper is not in
the path.

## Why this is worse than it looks

**The bypassed set is exactly what a protected section is for.** Images, PDFs,
text and binaries. An operator who protects `/upcoming/` and puts a draft price
list, a pre-release PDF or an unpublished photograph in it has protected the page
describing them and published the things themselves.

**It is silent.** The operator sets the ACL, loads the page, is bounced to
`/login`, and has every reason to conclude the section is protected. Nothing in
the manager, the audit trail or the API contradicts that.

**It shipped alongside a loud failure and hid behind it.** H17 was fail-CLOSED -
a static 404ing - and got noticed immediately. This is fail-OPEN, and three probe
runs across two rebuilds produced byte-identical responses. An operator following
the release note has done everything asked of them and has no way to tell from
outside whether anything changed.

## ROOT CAUSE (found 2026-08-11, by reading the shipped templates)

The agent could not determine this from the client side and said so. It is
determinable from the tree, and the answer is narrower than the brief assumed.

**Every template lazysite ships already carries the ACL branch:**

```
installers/apache/vhost-cgi.conf.example   acls.json x4
installers/hestia/lazysite-cgi.tpl         acls.json x4
installers/hestia/lazysite-cgi.stpl        acls.json x4
installers/hestia/lazysite-fcgi.stpl       acls.json x4
installers/nginx/vhost-cgi.conf.example    acls.json x2
installers/nginx/vhost-fcgi.conf.example   acls.json x2
```

So the guidance is right, the generator is right, and SM268 H15 did its job.

**The gap is that all four Hestia templates are APACHE.** `lazysite-app.tpl` is
`RewriteCond`; so are the rest. Lazysite ships **no Hestia nginx proxy
template**.

On Hestia the path is nginx -> Apache. Hestia's own default nginx proxy template
serves a fixed list of static extensions directly from the docroot with
`expires max`, and proxies everything else back. So:

- `.png`, `.pdf`, `.txt`, `.bin` are on Hestia's static list -> **nginx answers,
  Apache never sees it, our correct ACL rules are unreachable**;
- `.dat` is not on that list -> proxied to Apache -> gated, exactly as designed.

That accounts for every observation in the brief: the extension-decided split,
the `expires: Thu, 31 Dec 2037`, the `etag`, and the absence of all three
lazysite security headers on a disclosed file. It also explains why three
rebuilds and a template install changed nothing - every one of them re-rendered
the APACHE template, which was never the layer answering.

## What to build

Ship a **Hestia nginx proxy template** (`lazysite-proxy.tpl` / `.stpl`) whose
static location carries the same ACL branch `installers/nginx/vhost-cgi.conf.example`
already has, and have `install-hestia.sh` select it alongside the Apache one. The
logic is written and proven; it is in the wrong file for this deployment shape.

This also means **the fix is deployment configuration**, so per SM248's lesson a
site does not get it from a package upgrade alone - the proxy template has to be
installed and the vhost re-rendered, and the release note must say so.

## The decision this filing opened, now closed

It asked whether the front end should exclude ACL-covered prefixes or route
protected statics through the wrapper. **Neither needs deciding**: the shipped
nginx template already does the second, gated on the presence of `acls.json`, so
a site with no ACLs keeps direct serving at full speed and a site with them pays
only where it asked to. That choice was made in SM268 H15 and holds. What remains
is to put it in the file Hestia actually reads.

## Acceptance

- The fixture above: one ACL, the same bytes under five extensions, **all five
  gate**. It fails today on four of five, and belongs in `t/` at whatever level
  the fix makes reachable.
- An **observable** that the fix landed. Today there is none - which is its own
  finding. A header, a log line, or a documented probe that returns differently
  before and after, so an operator can confirm rather than trust.
- The nginx guidance in `lazysite-nginx-vhost.pl` no longer tells operators to
  configure the bypass.

## Related

[[SM223]] (the engine enforcement, correct), [[SM267]] (the panel that tells an
operator a section is protected), [[SM248]] (the last time front-end routing made
correct engine code unreachable), [[SM268]] H17 (the fail-closed sibling).
