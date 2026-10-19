---
id: SM1183
title: "SM1183: a secret file is never wider than its final mode, not for an instant"
subtitle: "The OAuth token store was written under the umask and chmod'ed afterwards, and its header said 0600 where the contract (SM760) is 0660. Latent while the auth directory is 02770; closed for the whole class."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-19
raised-by: SM1181's review, "Found in passing, not C2's"; release manager, 2026-10-19
area: auth
status-note: "SHIPPED on claude/n670-the-oauth-store-is-owner-only: Lazysite::Util::write_private_atomic; t/unit/oauth/05."
---

# The exposure, first

LATENT, NOT LIVE, for every store in `lazysite/auth/` and `lazysite/forms/`:
both are 02770 (`lazysite-check` `%want_dir`, `lazysite-users.pl` line 238), so
no other user can traverse them and a world-readable temp file inside is not
reachable. It is a defect in depth, not an exposure, and it becomes one the
day a directory mode drifts (SM270's docroot repair is the precedent).

The only store that wrote CONTENT before narrowing the mode was OAuth's
`oauth.json` (access and refresh tokens): `open '>'`, print, close, then
`chmod 0660`. The others (the auth and CSRF secret mints, `revoked.json`,
`sessions.jsonl` prune, the Odoo unknown-groups file, staged account imports)
chmod'ed right after the open and before the write, so the gap held an empty
file; plugin configs with a password field were written under the umask and
chmod'ed after the password was in them. `lazysite/manager/` is not 02770 (the
install makes it 0775), and holds `.csrf-secret`: its mint chmod'ed before
writing, so no secret was in a wider file there either. Every one of them was
still created at the umask's mode (0664 in the CGI) first.

# What was reported

SM1181's review: "`Lazysite::Auth::OAuth::save_store` sets the token store to
0660; the module's header says 0600." The release manager asked for it to be
verified and fixed.

# What was true

The header was wrong, the mode was right. The CGI writes the store as the web
user and the operator tool (`lazysite-users.pl` `revoke_partner`,
`partner_grants`) reads and rewrites it as the panel user, who shares only the
setgid auth directory's group (SM760); `lazysite check` fails an auth secret
the CGI cannot read and fixes it to 0660. 0600 would lock one side out.

# What shipped

- `Lazysite::Util::write_private_atomic( $path, $content, $mode )`: the temp is
  created with `sysopen` `O_EXCL` and the final mode under a umask that clears
  every other bit, written, closed and renamed. An existing store takes the
  mode on its next save. One helper, not seven copies.
- Routed through it: OAuth `save_store`; `Manager::Users` (auth secret
  rotation); `Manager::Preview` (auth secret mint); `Auth::Session` (CSRF
  secret mint); `Manager::Sessions` (`revoked.json`, the registry prune);
  `Odoo::SiteSignin` (unknown groups); `Manager::AccountImport` (staging);
  `Manager::Plugins` (a config with a password field).
- OAuth.pm's header now says 0660 and why.
- Not changed: `Manager::Common::write_file_checked` (generic, carries the
  target's mode), the Themes/Files writers (0640, no secrets), and the
  `secure_write_perms` callers (Settings, Acl, AddressLists, Connectors, Odoo)
  which chmod the temp after writing: the same shape on stores of settings,
  ACLs and address lists (no tokens or keys); left for a follow-up.

Tests: `t/unit/oauth/05` (the chmod hook sees no content in a file chmod'ed
afterwards, at three umasks; temp mode at rename; a 0664 store becomes 0660;
the helper at 0600 and 0660 with umask 0; the writers use the helper; the
header; `lazysite check` passes a 0660 OAuth store and names a 0664 one).
