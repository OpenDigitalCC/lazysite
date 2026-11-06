---
id: SM1295
title: "SM1295: a ready-made sign-in page for a site whose sign-in is the Odoo login"
subtitle: "SM1160 left the login page of an opted-in site to the operator: a page carrying a data-ls-odoo-signin button, named in auth_redirect. /odoo-signin is now that page, a system page like /login and /forgot, served while odoo_site_signin is on, in the site's layout, with no inline style."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-23
raised-by: "plan 0.16.2 row n736, #340 (the follow-up of SM1128 and SM1160)"
area: auth
status-note: "SHIPPED (0.16.3) on n736: lazysite/templates/system/odoo-signin.md and the built-in component lazysite/templates/components/odoo-signin.tt; the processor's %SYSTEM_PAGES and _odoo_site_signin_on (render.pm, shared with the banner). t/unit/processor/171. The questions it left were ruled 2026-10-23 (rulings 36-39) and built as [[SM1299]]."
---

# What was asked

#340: a ready-made sign-in page for sites that opt in to an identity provider. The
filing that describes it is [[SM1160]]'s follow-up: "A login page for an opted-in site:
set `auth_redirect` to a page carrying a `data-ls-odoo-signin` button (or the banner); a
ready-made page is not part of this filing." [[SM1128]] is the identity-provider plan;
of its routes, the trusted-header one signs a visitor in at the proxy (no page of ours
is involved) and its native OIDC relying party (phase 2) is not built. So the provider a
site opts in to, and for which a sign-in page is missing, is SM1160's: the person's Odoo
login as the site sign-in.

# What shipped

- **`/odoo-signin`**, a system page in the [[SM201]] fallback chain beside `login`,
  `forgot` and `account`: a domain's content root, then the docroot root, then the
  protected default `lazysite/templates/system/odoo-signin.md`. A site's own copy wins,
  and deleting it restores the default.
- **Only while the provider is configured.** The default is served only while the Odoo
  extension is enabled and `odoo_site_signin` is on (`_odoo_site_signin_on`, the reader
  the banner already used, now one function in render.pm); otherwise the path is not
  found, as `account` is not with `account_page: disabled`. To send a visitor there for
  a page that needs a sign-in, the operator sets `auth_redirect: /odoo-signin`.
- **The page.** A short paragraph (the sign-in is the Odoo login, the authenticator code
  where Odoo asks, and signing out ends both), then the built-in component
  `::: odoo-signin`: a "Sign in with your Odoo login" button carrying
  `data-ls-odoo-signin`, which opens the existing sign-in dialog through
  `/assets/lazysite-odoo.js` (the processor adds the helper for any page carrying
  `data-ls-odoo-*`), and a "Signed in as <name>" line with "Go to the site" and a
  sign-out, which the helper shows in place of the button once someone is signed in.
  The component is the [[SM1043]] account components' shape, so a layout restyles it
  with its own `components/odoo-signin.tt` and any page may use it.
- **No inline style.** No `<style>` block and no `style` attribute: the button sits in
  `.lazysite-form .form-field.form-submit`, which the fallback chrome styles
  (lazysite-chrome.css) and, under a theme, the base form rules do. The markup is one
  line on purpose: the Markdown pass ends an HTML block early at an indented or repeated
  tag and wrapped the rest in `<p>`.
- Docs: starter/docs/odoo.md, the site sign-in section.

# Left for a ruling

- **The name.** `/odoo-signin` names the provider it serves. A second provider (SM1128's
  OIDC, when built) would want its own page or a shared one; which is a product decision.
- **Back to where the visitor was going.** After `auth_redirect` the visitor arrives with
  `?next=<page>`. The page does not follow it: once signed in they see "Go to the site"
  (`/`). Following `next` needs the Odoo helper to navigate after a successful sign-in
  and a check that `next` is a path on this site, the open-redirect question /login's
  `next` answers in the auth CGI. Not built until ruled.
- **Who points at it.** Nothing sends a visitor to `/odoo-signin` by itself: `/login`
  still offers the local account form on an opted-in site, and `auth_redirect` still
  defaults to `/login`. Whether an opted-in site's `/login` should offer the Odoo sign-in
  (or the default `auth_redirect` become `/odoo-signin`) is not decided by the filing.
- **Maintenance.** Like any page other than the sign-in pages and `auth_redirect`, the
  page is behind maintenance unless it is the site's `auth_redirect`.

# Tests

t/unit/processor/171 (new): the default and its component ship, with no `<style>` and no
`style=`; switched on, `/odoo-signin` renders in the site's layout with the button, the
signed-in line and the Odoo helper, as one block with no stray paragraph tags, and the
page's content carries no inline style; under the fallback layout it wears the fallback
chrome, whose stylesheet styles this markup; with the opt-in off, absent, or the
extension not enabled, it answers 404; a layout's own component wins; a site's own copy
wins and deleting it restores the default. Sabotage: the processor without the system
page fails four subtests; without the opt-in gate the 404 subtest fails.

# Ruled (2026-10-23)

Rulings 36-39 answered the questions above: the name stands (36); the page follows
`?next=`, same-site only (37); `/login` on an opted-in site links to it, carrying `next`
(38); and it is reachable during maintenance (39). The three changes are [[SM1299]].
