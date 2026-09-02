---
id: SM734
title: "SM734: theme assets compile to the docroot, so a content-root domain never gets its CSS"
subtitle: "A multi-site domain with a non-empty content_root renders unstyled however many times its theme is activated, while the manager preview shows it correctly. Reported and proved on edge; the module already knows how to resolve a host's content root and does not use it here."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED with the content-root option, on the release manager's decision - n copies rather than a front-end rule, because SM286 refuses asking anything of the front end and a theme's assets are small while activation is rare. _all_content_roots() reads the same conf lines as _host_content_root, which had known how since SM315 and was used only for cache invalidation. A content root that cannot be written is REPORTED, not fatal: the docroot mirror is already there and the primary host serves, so refusing the whole activation would take a working site down for a broken sibling. Traversal and absolute paths are refused - operator-written config, but it names a directory this code creates. NOT YET PROVED IN THE FIELD: the outcome test must use the LIVE host, because the preview renders through the engine while the live host serves a static file and passed throughout this defect's life."
---

# What happens

Reported by the edge testing agent, 2026-09-02, verified on 0.11.10.

`edge2.explore.lazysite.io` (`content_root: sites/edge2`) renders structure with
no CSS. Its `<head>` emits the correct links; **every one of them 404s on that
host**, as does every path under `/lazysite-assets/`, for every theme - so it is
not theme-specific. Reactivating the theme, and swapping it out and back, change
nothing. **The manager preview renders correctly throughout**, which is the part
that makes this expensive to diagnose from the outside.

The reporter's evidence is decisive on its own:

- `/lazysite-assets/atelier/atelier-noir/main.css` → **200** on the `edge.explore`
  host (`content_root: ""`), **404** on the `edge2` host.
- `sites/edge2/lazysite-assets/` does not exist.

# The cause, and the sharp part

A domain with a content root serves `/lazysite-assets/` **from that content
root** - the vhost points its document root there, so the request is a static
file the engine never sees. Theme activation compiles into
`$DOCROOT/lazysite-assets/...` (`Themes.pm:938`), the INSTANCE docroot.

The two disagree, and nothing notices.

**What makes this a defect rather than a gap: `Themes.pm` already knows how to
resolve a host's content root.** `_host_content_root` sits at line 1658 and is
used at 1712 - for cache invalidation. The asset compiler, 700 lines above,
hardcodes `$DOCROOT`.

So the knowledge is present, correct, and one function call away from the place
that needs it. This is not "theme activation is not multi-site aware"; it is
multi-site aware for one purpose and not for the other.

# Why the preview hid it

The preview renders through the engine, which resolves assets by a different
path from the web server serving a static file. So the one surface an operator
naturally checks after activating a theme is the one surface that cannot show
the fault. That is worth recording separately from the fix: **a preview that
cannot fail the way production fails is a preview that will hide this class of
defect again.**

# Scope, before anyone estimates it

Not just `main.css`. Every path under `/lazysite-assets/` on such a domain -
theme tokens, fonts, every layout's assets. A content-root domain has never had
any of them.

**Which means the blast radius is every multi-site domain with a content root**,
on every release since the asset mirror was introduced. On this estate that is
several. Anyone reading this should assume such a domain has been unstyled since
it was created rather than that it regressed recently.

# What needs deciding

Where the assets should live for a content-root domain: compiled into each
domain's content root (n copies, each activation writing several), or served
from the instance docroot by a front-end rule (one copy, but it asks something
of the front end, which SM286 refuses).

**SM286 makes that a real decision rather than an obvious one**, so it is named
here and not taken.

# Outcome test

- A domain with a non-empty `content_root`, after activating a theme, serves
  `/lazysite-assets/<layout>/<theme>/main.css` with a 200 on **its own host**.
- The same for tokens and fonts.
- A domain with an empty `content_root` is unaffected.
- The check is made against the LIVE host, not the preview - the preview passed
  throughout this defect's life.
