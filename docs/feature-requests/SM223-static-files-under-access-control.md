---
title: "SM223 - Static files under access control"
subtitle: "A static file is served before any page logic runs, so it is reachable by anyone who knows its path - including on a site whose auth_default is 'required'. Close the gap so 'the site is protected' means every served byte."
brand: plain
status: partial
status-note: "PARTIAL 2026-08-09: the DETECTOR is built (option C, minus its write-time refusal) - audit_site reports unprotected_static_files and site_auth_default, so an operator can see that their configuration and their content disagree. The four open decisions are now ANSWERED (see 'Decisions taken'), and the design they produce is not the one this filing recommended: protection is an explicit per-path entry in the EXISTING acls.json rather than auth_default reaching static files, folder scopes are entries in that same store, the vhost routes source-less statics to the engine only when an ACL file exists (so no reload is ever required), and the upgrade risk is met by observability - an auth-failure report in analyse_visitors plus a documented log-scan pattern - rather than by a release of lead time. ENFORCEMENT is not yet built. Raised 2026-08-06 from the Golden Link partner review, where private participant material would have been published as static HTML. Treated as a MISSING FEATURE, not a defect: nothing is behaving contrary to its design, but an operator cannot express an intention the platform lets them believe they have expressed. SM181 is no longer a prerequisite - folder scope is an ACL entry, so SM181 becomes a manager affordance over the same store rather than a second mechanism."
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

### Recommendation - SUPERSEDED 2026-08-09

The recommendation was options A and B together, with C's audit warning as the
detector. The detector shipped and stands. The rest was overtaken by the
decisions below, in one important respect: **A and B were both framed around
`auth_default` reaching static files, and it does not.** Protection is now an
explicit per-path act carried in the ACL, so the enforcement is still A plus B
in shape - the engine decides, the front end routes to it - but what they
enforce is an ACL entry rather than a site-wide default.

The part of the recommendation that survived intact is the sequencing: detect
before enforce. That is why the detector shipped alone in 0.10.4 and why the
answers below could be made against evidence from live sites rather than from
argument.

## Relationship to SM181

SM181 (folder / URL-prefix protection) proposes the prefix rule itself, and its
status-note already records that "a static-asset caveat needs a decision". SM223
is that decision.

**The 2026-08-09 decisions invert the dependency.** Folder scope is now an entry
in `acls.json` rather than a new prefix rule in `lazysite.conf`, so SM223 no
longer waits on SM181 and can ship on its own. SM181 becomes a manager
affordance over the same store - a way to write a folder-scoped ACL entry
without hand-editing JSON - rather than a second mechanism that would have to be
kept in step with this one.

That is worth stating plainly, because the original concern still applies in
reverse: two mechanisms for "this path is protected" would give operators two
ways to believe they are protected, and only one of them would cover static
files. One store removes that failure mode entirely.

## Decisions taken 2026-08-09

The four questions below were open when the detector shipped. All four are now
answered, by the operator, and the answers are recorded here because the design
they produce is not the one this filing originally recommended.

### The mechanism is the ACL, not a new store

**`lazysite/auth/acls.json` carries the access controls for a source-less file.**
`Lazysite::Auth::Acl` already holds per-path `owner` / `read` / `write` lists with
user and `@group` entries, atomically written and already maintained by the
manager. Folder scopes are expressed as entries in that same file rather than as
a separate prefix rule in `lazysite.conf`.

This answers open decision 4 in the affirmative and settles SM224 by
implication: `read` stops meaning "who may read this in the authoring channels"
and starts meaning "who may read this at all". The operator's reason was that
the store is established and a single place is clearer to understand than two
that have to be kept in step - which is the same argument this whole filing
makes about the permission model.

A sidecar file per asset was considered and rejected: a copy or a move drops it
silently, and SM245 is currently retiring the `.brief` sidecars for related
reasons.

### `auth_default` still does not reach static files

A file with no ACL entry is served, exactly as today. `_acl_allows` already
returns "allowed" for a path with no entry, and that behaviour carries over
unchanged to the public path. Direct static serving is a correct and supported
use, and a site that has expressed nothing about a file has not expressed that
it is closed.

Protecting a static asset is therefore an explicit act, which is the opposite of
the original recommendation that `auth_default: required` should cover
everything. The originating Golden Link case is met by the operator writing one
ACL entry, not by the platform inferring one.

### The front end routes to the engine when an ACL file exists

Apache's `[L]` rewrite hands a source-less static straight to the client, so an
ACL the engine enforces would be invisible there. The vhost generators emit
**one rule, once, at install**: a source-less static routes through the engine
only when `lazysite/auth/acls.json` exists.

```apache
RewriteCond %{DOCUMENT_ROOT}/lazysite/auth/acls.json -f
RewriteCond %{DOCUMENT_ROOT}%{REQUEST_URI}.md !-f
RewriteCond %{DOCUMENT_ROOT}%{REQUEST_URI} -f
RewriteRule ^/(.*)$ /cgi-bin/lazysite-processor.pl [L]
```

The condition is a file-existence test of the kind the rewrite already performs
for the `.md`, so it costs nothing on a site with no ACLs, and such a site keeps
direct static serving untouched. This answers open decision 1: **no reload, ever.**
Adding or changing a protected path is a pure content action with no operator
involvement, which the option-B analysis called the real decision in this
request. SM222's killswitch trade-off is resolved the other way here, and
deliberately: a killswitch is an operator act, a content permission is not.

The cost is stated plainly: on a site with **any** ACL entry, every source-less
static request goes through the engine rather than being served directly. That
is the price of never needing a reload, and it falls only on sites that have
asked for it.

### Upgrade is handled by observability, not by lead time

Existing `acls.json` entries were written to govern authoring. Once the public
path reads them, a `read` list set to keep other editors out also starts
refusing anonymous visitors. Rather than buying a release of lead time or
introducing a second kind of `read` entry, the consequence is made **detectable**:

- `analyse_visitors` gains a report of page auth failures, so an asset that
  became protected by accident surfaces as refusals against a real URL;
- the documentation carries a log-scan pattern an operator can run directly to
  find the files where this condition is already set, at any time rather than
  only in the release before the change.

This is better than a warning one release ahead, which only catches the case for
operators who read that release's notes in that release's window.

### Protected statics are never cached

Open decision 3, answered by consistency: a protected static gets the same
`no-store` handling a protected page already gets. A response whose content
depends on who asked must not be stored by a cache that does not know who asked.

## Consequences for the build

- The public path must call `_acl_allows`, **never** `_acl_denied`. `_acl_denied`
  routes through `_is_operator`, which returns 1 on a site where no group grants
  manager access (`Acl.pm:118`). On an anonymous request that would bypass the
  ACL entirely, and it would do so on exactly the sites least equipped to notice.
- `Auth::Acl` pulls in `JSON::PP`, `File::Path` and `Auth::Settings`, so the
  processor gets a module-free reader rather than a `require` - the same
  treatment ADR 0001 already gives `_groups_grant_cap`.
- SM181's prefix rule is no longer a prerequisite. Folder scope is an ACL entry,
  so SM223 can ship on its own and SM181 becomes a manager affordance over the
  same store rather than a second mechanism.

## Not in scope

- Authenticating the engine-owned areas. `lazysite/**` and `cgi-bin/**` have
  their own handling and are not content.
- Per-file ACLs on the public path. That is SM224's question to answer first.
- Any change to how the applications themselves are published. A public
  application served as a static file is a correct and supported use.
