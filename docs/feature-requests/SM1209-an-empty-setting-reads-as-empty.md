---
id: SM1209
title: "SM1209: an empty setting in the conf reads as empty"
subtitle: "The manager's save check read a key whose line was present but empty as the whole next line, so on a conf with every app_* line stored empty no app_scope or app_offline_pages could be saved. Every conf reader now keeps a value on its own line."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-20
raised-by: "the 0.15.13 edge walk, finding H-1 (inbox 2026-10-20-test-plan-01513-results.md): X1 FAIL, X2-X5 blocked"
area: manager
status-note: "SHIPPED (PENDING) on n697: Lazysite::Util::conf_text_value keeps a value on its line (last non-empty wins, as the engine reads it); config-set's checks, the content_root list and the form conf readers use a same-line separator. Tests 369, 370."
---

# What happened

On edge every `app_*` line was present and empty (`app_scope:`, which is how
config-set leaves a cleared key). `_app_setting_fault` in
`lib/Lazysite/Manager/Config.pm` read the other stored keys with
`/^\Q$k\E\s*:\s*(.*?)\s*$/m`. The `\s*` after the colon also matches the newline,
so an empty line read as the next line: `app_scope` read as `app_start_url:` and
`app_start_url` read as `app_icon_192: ...`. Every `app_offline_pages` value was
refused as outside the scope, and no `app_scope` could be saved. The engine's
reader (`resolve_site_vars`, `^(\w+)\h*:\h*(.+)$` over the whole text) was not
affected.

# What shipped

- `Lazysite::Util::conf_text_value($text, $key)` is the one reader of a value out
  of conf text. The value is confined to its line (`[ \t]*:[ \t]*`), a line with
  nothing after the colon is no occurrence, spaces only read as `''`, a missing key
  is undef, and a repeated key reads as the engine reads it: the last non-empty
  occurrence. `_app_setting_fault` (and so `_app_offline_page_fault`, which takes
  `manager_path`, `auth_redirect`, `content_root` and `auth_default` through it) and
  the address-list check in config-set (`manager_addresses`/`_deny`,
  `signin_addresses`/`_deny`) use it.
- The same `\s*`-over-the-newline shape was in four more readers of conf text, fixed
  with `\h*` (they cannot load lib, ADR 0001, or share the form-handler's copy):
  the `content_root` list in lazysite-processor.pl, the form conf keys in
  `Lazysite::Handlers` and `plugins/form-handler.pl` (quarantine, spam_keywords,
  spam_url_threshold, spam_own_domain, account_email, upload_*, rate_limit,
  timestamp_window), the smtp conf in `plugins/form-smtp.pl`, and
  `tools/bench-surfaces.pl`'s server_timing check.

# Audit of the other readers

Fixed: the readers listed above. Safe, so unchanged:

- Line-at-a-time readers, where a value cannot reach the next line:
  `Notify::_conf_value`, `Daemon::Supervisor::conf_value`, `Auth::Identity::_read_conf_file`,
  `Odoo::read_conf`, `plugins/stats.pl` read_conf, `site_conf_value` (lazysite-cli),
  `read_conf_value` (lazysite-users).
- Whole-text readers that already use `\h` (the engine's `resolve_site_vars`,
  `Lang::_parse_conf`, `Lang::sole_group`).
- `Manager/Themes.pm` theme and layout rewrites: the `\s*` sits before the colon.
- Not conf text, so out of this fix (front matter of our own docs, the data
  definitions, release tooling): `lazysite-compliance.pl` meta_field, `gen-doc-index.pl`,
  `backlog.pl`, `release-material.pl`, `lazysite-check.pl` `domain:` and `row_policy:`.
- Page front matter has the same shape (`lazysite-processor/front-matter.pm` line 382,
  `Manager/Common.pm` lines 1129 and 2289: `^(\w+)\s*:\s*([^\n]+)$` /mg). It is not
  conf and it is the page parser, so it is not changed here and is raised for the
  release manager.

Evidence: test 369 builds the edge conf (every app_* line present and empty) and
saves app_scope `/zz/` and app_offline_pages `/zz/a` through config-set; a gated
page and `/manager/` are still refused, naming the page and the reason. Test 370
runs the reader over empty, spaces-only, missing, repeated and CRLF lines and
the form conf reader over an empty key. Sabotage: the old reader in
`_app_setting_fault` fails 369 (ten checks).

# Not done

- Page front matter (above) is not changed.
