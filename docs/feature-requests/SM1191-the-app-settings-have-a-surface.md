---
id: SM1191
title: "SM1191: the app settings have a surface"
subtitle: "The app_* settings of SM1155 are on the Config page and in the config-set allow list, each checked as the engine reads it."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-19
raised-by: inbox/2026-10-19-test-plan-01510-results.md (F-5)
area: manager
status-note: "SHIPPED (PENDING) on n680: lib/Lazysite/Manager/Config.pm _app_setting_fault, starter/manager/config.md; t/unit/manager/367."
---

# What happened

The 0.15.10 walk (row Y8: "Config: set app_name") found:

> F-5, the app settings have no surface: Y8 says "Config: set app_name", but
> the `app_*` keys (`app_name`, `app_scope`, icons, colours) are in neither the
> config-set allow list nor the Config page, so an operator without shell
> cannot make a site an app.

config-set refused them ("not settable via the API"), the Config page had no
app fields, and WebDAV cannot write `lazysite/`.

# What shipped

All eleven keys SM1155 reads: `app_name`, `app_short_name`, `app_scope`,
`app_start_url`, `app_theme_colour`, `app_background_colour`, `app_icon_64`,
`app_icon_192`, `app_icon_512`, `app_icon_maskable`, `app_shell`. They are in
config-read, the config-set allow list (each clearable; clearing `app_name`
turns the app off) and a Config page section, "Install as an app", with a note
on each field.

Each is checked as the engine reads it, and a refusal names the key:

- scope: `/` or `/dir/…/`, no dot segments;
- start page: a path inside the stored scope (the whole site when none);
- a scope is refused when it would leave the stored start page outside it;
- colours: `#rgb` or `#rrggbb`;
- icons: a site path to a png, webp, svg or jpg that exists under the content
  root or the docroot;
- offline files: site paths, no `..`.

The engine (`lazysite-processor/app.pm`) loads nothing from `Lazysite::` (ADR
0001), so the patterns are restated in the manager and t/unit/manager/367 runs
the same values through both, so they cannot drift.

Authority: like other site settings these need `manage_config`, over a cookie
session or a token. They are not in the cookie-only set (SM612, SM1140): they
change what the site installs as and cannot lock the operator out of the
manager.

The Config page writes the scope and the start page one after the other, not in
parallel, clearing the stored start page first when both change, so each is
judged against the other's new value.
