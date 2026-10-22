---
id: SM1255
title: "SM1255: the shipped docs say what the engine does"
subtitle: "Seven facts in starter/docs and FEATURES.md that the lazysite.io content check found out of step with the engine, each settled from the code and fixed in the doc, and a lint that asks the code."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-22
raised-by: the lazysite.io site agent, inbox 2026-10-22-shipped-docs-out-of-step-with-0-15-16.md (D-1 to D-5, D-7, D-8)
area: docs
status-note: "SHIPPED (PENDING) on n728: views.md removed and its links repointed, per-host keys and env allowlist, session pruning, connect code, CSP default, block-list page, page serving; t/lint/274. D-6 is SM1256."
---

# What was found, and what the code says

Each finding was checked against the code before the doc was touched. All
seven were right.

D-1, views.md
: `starter/docs/features/configuration/views.md` described `view.tt` and a
  `lazysite/templates/view.tt` fallback chain. The layouts rework removed both
  (lazysite-processor.pl, the D013 note above `$LAYOUT_DIR`): a layout is
  `lazysite/layouts/NAME/layout.tt` and the only fallback is the built-in
  template. The page is deleted. Its three links (configuration.md, nav-conf.md,
  layout-override.md) point at Layouts. layout-override.md itself described the
  same retired resolution (`lazysite/themes/NAME/view.tt`, a site `theme:` it
  overrides, a fall back to `view.tt`) and is rewritten from `get_layout_path`:
  a missing page layout renders through the built-in fallback, not through the
  site's layout. troubleshooting.md's two `view.tt` mentions and the
  `author-layout` quickstart in Lazysite::Capabilities name `layout.tt`. The
  site's own feature data (`website/data/`) linked the page too: the feature
  index entry is removed and the "Multiple views" feature points at the
  per-page override.

D-2, per-host keys
: configuration.md listed nine keys; `%ALIAS_OVERRIDE_KEYS` holds 29 now (the
  CSP allow-lists, the app keys and, since 0.16.0, the maintenance keys). The
  list is complete. reference.md's entry for `alias.<host>.<key>` listed five
  and said "conf-file only - not settable via the manager or API", which the
  Domains page and `domain-set` contradict; it points at the full list and says
  where the keys are set. The same paragraph's environment allowlist missed
  `REQUEST_URI`, which `Lazysite::Util::env_allowlist` includes.

D-3, session registry
: auth.md and manager.md said the registry self-prunes after 24 hours. Both the
  login-time rewrite (lazysite-auth.pl `_session_register`) and the hourly
  sweep (`Manager::Sessions::sweep_expired`) prune at `session_lifetime`,
  24 hours only by default.

D-4, connect code
: onboard-ai-agent.md said 15 minutes; `$CONNECT_CODE_TTL` in
  tools/lazysite-users.pl is 1,800 seconds (SM200). ai-connector-setup.md
  already said 30.

D-5, the CSP
: reference.md says `csp` defaults to report-only; FEATURES.md's 0.10.15 entry
  said the CSP "ships enforcing". The code reads report-only for an unset or
  unknown value (`_csp_mode`, in the processor and Lazysite::SecurityHeaders),
  and did at the v0.10.15 tag too, so reference.md is right and the FEATURES
  entry was wrong when written. It is corrected.

D-7, the block list
: plugins/bad-url-blocker.pl's header put the blocked-address list on the Stats
  page; its own description (shown on its config page) says "on this page".
  The list is on the plugin's config page (starter/manager/plugin-config.md,
  moved there by SM703). The header is corrected.

D-8, who serves a cached page
: FEATURES.md said the web server serves the cached `.html` directly. A page's
  address has no file behind it (`/about` is `about.md`, cached as
  `about.html`), so every shipped front end hands it to the processor, which
  answers from the cache (docs/reference/webserver-wiring.md). Corrected.

# Generated copies

`tools/regen-generated.sh` was run: `docs/reference/quickstarts.md` changes
with the Capabilities quickstart, and `docs/INDEX.md` does not list the
configuration pages, so it is unchanged.

# Not changed

starter/docs/development.md and ai-briefing-development.md say the homepage's
`index.html` is served by `DirectoryIndex`. That is false for the nginx, Apache
and Hestia `lazysite-cgi`/`lazysite-fcgi` templates, but true for the plain
Hestia `lazysite.tpl` (`DirectoryIndex index.html index.htm`). It was not in the
report, and which template is meant needs a ruling.

# Tests

t/lint/274 asks the code for each fact: no shipped doc or the descriptor names
`view.tt` (bar the sentence saying it is gone); every `/docs/` link in a
shipped doc names a shipped page; configuration.md's per-host key list equals
`%ALIAS_OVERRIDE_KEYS` and its env list equals `env_allowlist()`; auth.md and
manager.md name `session_lifetime`; the connect code's minutes are
`$CONNECT_CODE_TTL / 60`; `_csp_mode(undef)` is what reference.md gives and
FEATURES.md does not say enforcing; the blocker's header does not say Stats;
FEATURES.md does not say the web server serves the cache. With the docs
restored to the base, 13 of its 20 assertions fail.
