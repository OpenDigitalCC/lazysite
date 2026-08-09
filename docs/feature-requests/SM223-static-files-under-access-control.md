---
title: "SM223 - Static files under access control"
subtitle: "A static file is served before any page logic runs, so it is reachable by anyone who knows its path - including on a site whose auth_default is 'required'. Close the gap so 'the site is protected' means every served byte."
brand: plain
status: partial
status-note: "PARTIAL 2026-08-09: the DETECTOR is built (option C, minus its write-time refusal) - audit_site reports unprotected_static_files and site_auth_default, so an operator can see that their configuration and their content disagree. ENFORCEMENT (options A and B) is NOT built and should not be until the four open decisions below are answered: it is a behavioural change that would start refusing assets on live sites. Detect before enforce, which is this filing own recommendation. Raised 2026-08-06 from the Golden Link partner review, where private participant material would have been published as static HTML. Treated as a MISSING FEATURE, not a defect: nothing is behaving contrary to its design, but an operator cannot express an intention the platform lets them believe they have expressed. Overlaps SM181 (subtree protection), which already carries an open 'static-asset caveat' - SM223 is that caveat, scoped as its own decision."
---

# SM223 - static files under access control

## Why

lazysite has two ways to protect content on the anonymous read path:

- a page's own `auth:` front matter, with an optional `groups:` list;
- `auth_default:` in `lazysite.conf`, which sets the level for every page.

Neither covers a static file. An operator who sets `auth_default: required`
has expressed "this site is closed", and the platform accepts the expression -
but a `.html`, `.js`, `.pdf` or image served from the content root remains
world-readable to anyone who knows or guesses its path.

The gap surfaced in a partner review where a set of single-file browser
applications, and the private material they produce, were about to be published
as static HTML on the strength of a site-wide auth default. The material is a
named executive's account of their own working life. The exposure would have
been real, and the operator would have had no way to detect it from the
configuration they had written.

This is a missing feature rather than a defect. Every component behaves as
designed. What is absent is any way for an operator to say "protect this path"
and have it be true of a static asset.

## What is true today

### The web server serves static files without consulting the engine

`installers/hestia/lazysite-app.tpl` maps a clean URL to a sibling static file
and terminates the rewrite:

```apache
RewriteCond %{DOCUMENT_ROOT}%{REQUEST_URI}.md   !-f
RewriteCond %{DOCUMENT_ROOT}%{REQUEST_URI}.html -f
RewriteRule ^/([^.]+)$ /$1.html [L]
```

The `[L]` is the point. On that path `lazysite-processor.pl` never runs, so no
front matter is read, no `auth_default` is consulted, and no access decision is
made by lazysite at all. A direct request for `/private/participant.html` never
reached the engine in the first place.

### The engine's own fallback does not gate either

For non-Apache front ends the processor carries the SM133 static-HTML fallback
(`lazysite-processor.pl:1529`). The auth check that precedes it is enclosed in a
source-file test:

```perl
my @md_stat = stat($md_path);
...
if (@md_stat) {
    $auth_peek   = peek_auth($md_path);
    $auth_result = check_auth( $uri, $auth_peek, \%site_vars_peek );
    ...
}
```

With no `.md` source there is no `@md_stat`, so `check_auth` is never called and
`$auth_result` keeps its `{ ok => 1 }` default. The site-wide `auth_default` is
read *inside* `check_auth`, so it is skipped along with everything else. A
source-less static file is unauthenticated on both front ends, by two
independent routes.

### The per-file ACL does not apply

`Lazysite::Auth::Acl` is loaded by `lazysite-manager-api.pl`, `lazysite-mcp.pl`,
`lazysite-dav.pl` and the `Manager::Files` / `Manager::Upload` modules, and by
nothing else. It governs the authenticated authoring channels. The anonymous
read path never consults `acls.json`. See SM224, which asks whether that
separation is the right long-term model.

### The result an operator can reach

An operator can set `auth_default: required`, see every page bounce to the login
form, reasonably conclude the site is closed, and still be serving private
static assets to the open internet. Nothing in the manager, the configuration,
`audit_site` or the logs contradicts them.

## Built 2026-08-09: the detector

`audit_site` now returns `site_auth_default` and `unprotected_static_files` - the
files with no page source that the web server hands to anyone who knows the path,
listed only when `auth_default` is `required` or `optional`.

Reported only on a protected site, deliberately. On an open site these are simply
the site's assets, and a finding that fires everywhere trains its reader to
ignore it. A rendered page (one with a `.md` source) is excluded, because it is
gated normally.

The extension list is broad on purpose - `.html`, PDFs, office documents, images,
media, archives. The reported case was single-file browser applications, but a
PDF inside a private brief is the same exposure in a different wrapper.

**This detects; it does not protect.** Enforcement is options A and B below and
must wait for the four open decisions, because it would start refusing assets on
live sites that are serving them today. That sequencing is this filing's own
recommendation: the audit warning is "what makes the gap visible on sites that
upgrade without regenerating their vhost", and it is worth having before, not
after, the behaviour changes.

## What this asks for

One expressible intention: **a path prefix is protected, and that protection
covers everything served under it.**

## Options

### Option A - the processor gates static files too

Move the auth decision ahead of the source-file test in the processor, so a
source-less static file is evaluated against `auth_default` and any prefix rule
before it is served.

Correct and cheap on its own. Incomplete on Apache, where the `[L]` rewrite
means the processor never sees the request. Necessary, and insufficient alone.

### Option B - the vhost generator emits the protection

Have `tools/lazysite-apache-vhost.pl` and `tools/lazysite-nginx-vhost.pl` emit a
matching web-server rule for each protected prefix, so the front end refuses
before it serves.

Complete, and it makes "off" observably off from outside - the same argument
SM222 makes about disabled services. The cost is the one SM222 also names: a
configuration change now requires a web-server reload, which couples a content
decision to an operator action. That coupling is the real decision in this
request.

### Option C - protected content is never a static file

Declare that anything requiring protection must be a page, and make the platform
say so: refuse or warn at write time when a file is written under a protected
prefix, and surface it in `audit_site`.

Cheapest, and it needs no reload. It also narrows what an operator may do rather
than widening what they may express, and it does nothing for the assets a
protected page legitimately references - the image inside the private brief is
still public.

### Recommendation

Options A and B together, with C's audit warning as the detector that tells an
operator when their configuration and their content disagree. A alone leaves
Apache exposed; B alone leaves the dev server and any future front end exposed;
the audit warning is what makes the gap visible on sites that upgrade without
regenerating their vhost.

## Relationship to SM181

SM181 (folder / URL-prefix protection) proposes the prefix rule itself, and its
status-note already records that "a static-asset caveat needs a decision". SM223
is that decision. If SM181 is built first, SM223 becomes the second half of the
same work and should not ship separately - a prefix rule that silently omits
static files would make this gap worse by giving operators a second way to
believe they are protected.

If SM181 stays held, SM223 still stands alone against `auth_default`, which is
the case an operator can reach today with no new features at all.

## Open decisions

1. **Does a protected prefix require a web-server reload to take effect?** This
   is the same trade-off SM222 names for service killswitches, and the two
   should be answered the same way rather than diverging.
2. **What happens to an existing site on upgrade?** A site currently serving
   static assets under an `auth_default: required` docroot would begin refusing
   them. That is the correct behaviour and it is a behavioural change; it needs
   a release note and probably an audit warning one release ahead.
3. **Do protected static assets bypass the render cache**, or do they need their
   own no-store handling the way protected pages already do?
4. **Is the ACL in scope?** If SM224 concludes the two models should merge, the
   answer to "who may read this static file" may come from the ACL rather than
   from a prefix rule, and this design changes shape.

## Not in scope

- Authenticating the engine-owned areas. `lazysite/**` and `cgi-bin/**` have
  their own handling and are not content.
- Per-file ACLs on the public path. That is SM224's question to answer first.
- Any change to how the applications themselves are published. A public
  application served as a static file is a correct and supported use.
