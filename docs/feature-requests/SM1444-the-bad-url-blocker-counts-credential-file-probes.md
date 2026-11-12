---
id: SM1444
title: "SM1444: the bad-URL blocker counts probes for credential files"
subtitle: "Scanners fish for the dot-directories of developer and cloud tools and for app config files. No lazysite site serves them, so a request for one now counts as a bad URL, as /.env always did."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-12
raised-by: "a site owner's request (R3), ruling 245"
area: security
status-note: "SHIPPED (PENDING) on n823. Built-in patterns for /.docker/, /.claude/, /.cursor/, /.kube/, /.azure/, /.vscode/, /.idea/, /.terraform/, /.gnupg/, appsettings*.json, aws-exports.js and /wp-json/batch, in the blocker and in the stats noise set. /app.js and /app.config.js stay out. t/tools/640."
---

# What was asked

A scanner session fished a site for credential files: the dot-directories that developer and
cloud tools write into a home directory or a project (`/.docker/config.json`,
`/.claude/settings.json`, `/.cursor/mcp.json`) and the config files of other web stacks
(`appsettings.json`, `aws-exports.js`). The blocker counted `/.env`, `/.git` and `/.aws` but
none of these, so a session of such probes stayed under the threshold.

Ruling 245 (12 Nov 2026) took this one request (R3) into 0.17.0 as a field-pass hardening, dotfile
secrets only, under the feature freeze (ruling 228): no new setting, tool or UI. The rest of the
owner's requests are SM1445.

# What was done

`Lazysite::BadUrl` holds the built-in patterns, and its source says they mirror the stats
extension's noise set. The two are separate lists in separate files (the engine library and an
extension that runs on its own), so they stay two lists, and the new block is the same text in
both. `t/tools/640` fails if the two blocks differ.

Added, each a path no lazysite site serves:

- `.docker/` holds registry sign-in tokens; `.claude/` and `.cursor/` hold AI tool settings and
  API keys; `.kube/` holds cluster credentials; `.azure/` holds cloud CLI sign-ins; `.vscode/` and
  `.idea/` hold editor files that carry sftp and database passwords; `.terraform/` holds state and
  provider credentials; `.gnupg/` holds private keys. (`.aws` and `.ssh` were already there.) The
  trailing slash keeps a page such as `/docker-notes` out.
- `appsettings.json` and `appsettings.ENV.json`, the config files of .NET apps, and
  `aws-exports.js`, an AWS Amplify config.
- `wp-json/batch`. WordPress probes were already counted (`wp-login.php`, `wp-admin`,
  `wp-includes`, `wp-content`, `xmlrpc.php`); the batch endpoint, the modern replacement, was
  caught by nothing in the blocker, and the stats extension caught it only by behaviour (SM332's
  sweep). A lazysite site has no `/wp-json/`.

Left out on purpose: `/app.js` and `/app.config.js`. A real site can serve them (a theme keeps its
scripts there), and counting a site's own assets blocked every visitor behind the front proxy once
(SM1321).

A site's `bad_url_extra` still adds to the list. `site_has_file` still spares a real file, so a
site that does serve one of these paths is not counted for it.

The Extension Config page's description, the FEATURES.md entry and the stats noise-paths note
name the new classes.

# Test

`t/tools/640`: each new path counts as a bad URL; `/app.js`, `/app.config.js`, an ordinary page and
look-alike names do not; `bad_url_extra` adds beside the built-ins; four of the paths block an
address through the guard at threshold 1 and `/app.js` blocks nobody; the stats block equals the
blocker's. 23 of its 39 assertions fail on 299a10408.
