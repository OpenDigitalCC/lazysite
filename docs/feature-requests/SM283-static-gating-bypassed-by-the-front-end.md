---
title: "SM283 - A protected section gates its pages and serves its images, PDFs and text to anyone"
subtitle: "SM223's enforcement is correct. Most static requests never reach it, because lazysite's own nginx guidance tells the front end to serve them directly - and which ones gate is decided by file extension."
brand: plain
status: shipped
status-note: "SHIPPED on main (unreleased). FILED 2026-08-11 from the site agent's brief of 2026-08-10 and root-caused the same day: every template lazysite shipped already carried the ACL branch, but all Hestia templates were APACHE and no Hestia NGINX PROXY template existed, so Hestia's own default proxy served its static extension list directly and Apache never saw those requests. BUILT: installers/hestia/lazysite-proxy.tpl/.stpl, which hand a static request back to the origin whenever lazysite/auth/acls.json exists and change nothing for a site without one. The proxy layer also needed the .brief deny, the /lazysite/ deny (a stock proxy would have served lazysite/backups/*.tar.gz - a full pre-install snapshot of the site - on any host whose extension list includes gz), the SM248 registry routes and a raised body cap for /dav, because every one of those lives in the Apache half and a request the proxy answers never reaches it. THE OBSERVABLE the filing asked for: the template answers X-Lazysite-Front: hestia-proxy/acl, checkable with curl and no credentials; t/lint/33 binds the header to the ACL branch so it cannot appear without it. FLEET VISIBILITY: lazysite-hestia-list.sh flags a domain with an ACL store on a stock proxy as ACL-BYPASSED-BY-PROXY(SM283) and shows the rest with their proxy template; lazysite-hestia-update-all.sh --proxy stages and applies it host-wide, and says on EVERY run whether the layer was checked. THIS IS NOT DELIVERED BY A PACKAGE UPGRADE - per SM248's lesson the template must be installed and each domain moved onto it, which the release note must say. Tests: t/lint/33 (new, verified failing both with the templates absent and with the ACL branch stripped while the header stayed), t/integration/35 gains the five-extension fixture at the level the engine can be held to, t/tools/30 pins the packaging and the README steps. THEN nginx was installed on the build host and the behavioural half became reachable: t/integration/42 STARTS nginx against the shipped template and reproduces the measurement (all five extensions leave nginx with an ACL store; three served directly with a far-future Expires without one), and t/lint/34 runs nginx -t over all four shipped nginx configs. Verified by breaking the template five ways - ACL branch, /lazysite/ deny, .brief deny, registry routes, and the OVER-FIX of routing every static to the origin - each caught. Running it also FALSIFIED a claim this work had made in three places (that the ^~ modifier was what refused a pre-install backup; it is the deny location itself, since the extension regex is nested inside location /) - the protection was real, the explanation was wrong, and no text match would ever have contradicted it. What remains manual is narrower and stated as such in docs/MANUAL-CHECKS.md: a real Hestia host has its own proxy_extensions list, its own rendering, and a live origin, so a person confirms THAT DEPLOYMENT behaves, not that the template is right."
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

## What was built

Against each of those, and one thing they did not ask for.

The five-extension fixture is in `t/integration/35`, pinning the half the engine
owes: **the read decision never consults the extension.**

And then nginx was installed on the build host, which changed what was
reachable. `t/integration/42` now **starts nginx** against the shipped proxy
template and reproduces the field measurement outright: five extensions, one
folder ACL, and all five must leave nginx. With no ACL store, three are served
directly with a far-future `Expires` and two are proxied because they are off
the extension list - the original split, reproduced deliberately. `t/lint/34`
runs `nginx -t` over all four shipped nginx configs, so one that will not start
cannot ship.

Verified by breaking the template five ways and confirming the test catches each:
ACL branch removed (the original defect), `/lazysite/` deny removed, `.brief`
deny removed, registry routes removed, and the **over-fix** - routing every
static to the origin unconditionally, which would have "fixed" SM283 by making
every site pay for a feature it never asked for.

The observable is a response header, `X-Lazysite-Front: hestia-proxy/acl`, and
the lint binds it to the ACL branch: a template may not claim the header without
carrying the rule. That matters more than the header does. An observable nobody
can trust is worse than none, because it converts "I do not know" into "I
checked". At fleet scale `lazysite-hestia-list.sh` names the affected domains,
and `lazysite-hestia-update-all.sh` reports on **every** run whether the layer
was touched - including, especially, when it was not.

The guidance item needed nothing: `Lazysite::DomainRewrites` already emits the
ACL branch, which is what the ROOT CAUSE section above corrected.

The thing not asked for: the proxy also has to carry the `/lazysite/` deny, the
`.brief` deny, the SM248 registry routes and a body cap for `/dav`. All four
live in the Apache template, and a request the proxy answers never gets there.
The first is the one to notice - `lazysite/backups/preinstall-*.tar.gz` is a
complete snapshot of the site taken at install, and `gz` is on many stock
extension lists. Nobody reported it, and the same measurement would have found
it. **When a layer is missing, every protection at that layer is missing**, not
the one that happened to be observed.

## A correction the running server forced

Worth recording, because it is the argument for the test rather than a detail
of it.

The first version of this work asserted - in the template's own comments, in
`t/lint/33`, and in a `pass()` in the behavioural test - that the `^~` modifier
on the `/lazysite/` deny was what stopped the static-extension regex serving a
pre-install backup. Every one of those said the same thing, confidently, and it
was **wrong**. The extension regex is nested inside `location /`, so a URI
matching the longer `/lazysite/` prefix never reaches it, `^~` or not. What
refuses the backup is the deny location existing at all.

The protection was real throughout; only the explanation was false. But a wrong
explanation is what the next person edits against, and no text match would ever
have contradicted it - three separate checks agreed with it, because all three
were reading the same file I had reasoned about. It took starting nginx and
deleting the location to find out.

The assertion that replaced it is a control rather than a claim: the same
`.tar.gz` extension, served normally from an ordinary path. That proves the
refusal is about the path rather than the file type, and it cannot be satisfied
by a rationale.

## Related

[[SM223]] (the engine enforcement, correct), [[SM267]] (the panel that tells an
operator a section is protected), [[SM248]] (the last time front-end routing made
correct engine code unreachable), [[SM268]] H17 (the fail-closed sibling).
