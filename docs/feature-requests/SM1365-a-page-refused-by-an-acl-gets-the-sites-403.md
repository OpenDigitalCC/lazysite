---
id: SM1365
title: "SM1365: a page refused by an ACL gets the site's 403"
subtitle: "A signed-in visitor outside an acls.json read list who opened a page in the governed directory got a bare 103-byte 403 with no layout or theme. They now get the site's 403 page, naming the rule's groups, as a front-matter group gate gives; a file such as an image keeps the short 403."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-06
raised-by: "inbox filing 2026-11-06 (a directory of pages behind an ACL read list); planned as n753"
area: auth
status-note: "SHIPPED on n753: lazysite-processor/acl.pm _acl_refused answers a signed-in refusal of a page through serve_403 with auth_required_groups from the new _acl_read_groups, and keeps the short body for a file, by the new _acl_refusal_is_navigation. t/integration/345."
---

# What happened

A site guards a directory of pages with an `auth/acls.json` entry such as
`{"read": ["@somegroup"]}`. A visitor who is signed in but outside the group
opens the directory. The answer is a 403 of 103 bytes:
`<h1>Forbidden</h1><p>You do not have access to this file.</p>`, with no layout,
no theme and no way back to the site. The log line is `static refused by ACL`.

The same refusal by a page's own `auth_groups:` front matter renders the site's
`403.md` in its layout, says who is signed in and names the groups that would
admit them.

# Cause

`_acl_refused` is the one gate for the ACL store: it covers a page's source, a
`.url` page, the static-HTML fallback and a source-less static file, on every
front end (the static ACL is routed to the engine, t/lint/31). Its signed-in
refusal was written for a static file (SM223) and answered every path with the
same short body, so a page reached through it never got the site's 403.

# Change

- **A page gets the site's 403.** When the refused request is a navigation, the
  refusal goes through `serve_403` with `auth_denied_reason` set to
  `insufficient_groups` and `auth_required_groups` set to the group entries of
  the governing read list, without the `@`. Individual users on the list are
  never named. A navigation is a page source (`.md`, `.url`, `.html`), a
  directory, a request path that ends in `/`, `.html`, `.htm` or `.md` or has no
  extension, or an Accept header that puts `text/html` or XHTML first.
- **A file keeps the short 403.** An image, a PDF, a stylesheet, a script or a
  download asked for by anything other than a browser navigation gets the short
  body, through `output_page` with the security headers, as before.
- **Unchanged:** status 403, the access record (`s` 403, `ar` 1), the log line,
  the domain's content root (`serve_403` resolves it), a draft section's 404, the
  anonymous bounce to sign in, and the read decision (`_acl_allows_read`).

The DAV server's ACL refusals are protocol answers to a client, not pages, and
are left as they are. No front end carries a second copy of this refusal.

# Tests

t/integration/345 builds a site with the shipped 403 page and a read list naming
two groups and one user:

- a signed-in outsider on the directory and on a page in it gets 403 in the site
  layout, signed-in name and both groups named, the user and the `@` not, the
  security headers present; with no Accept header too;
- an image under the same rule, asked for as an image or with no Accept header,
  gets the short 403 with the security headers;
- a member reads the page; a draft section is 404 to an outsider and to the
  public; an anonymous visitor is sent to sign in, for the page and the image.

Sabotage (tmp/n753-sabotage.sh, backup under tmp/): the base `acl.pm`, a
navigation test that always says no, one that always says yes, an empty group
list and the raw read list each fail the test.
