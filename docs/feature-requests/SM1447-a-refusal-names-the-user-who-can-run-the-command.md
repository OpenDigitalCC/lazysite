---
id: SM1447
title: "SM1447: a refusal names the user who can actually run the command"
subtitle: "On a Hestia host lazysite/auth/ is owned by one user and the store files in it by the web server's, so naming the directory's owner sent the operator to the one user for whom the command failed."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-12
raised-by: "the 0.16.12 edge field pass (Y1 and B3 of the test results), built by the lazysite developer agent on n825"
area: reliability
status-note: "SHIPPED (0.17.0) on n825. The user to run as is the owner of the store files a command reads and writes (acl, handlers, check, users: one Util helper). The profile refusal and the upgrade name the owner. The check prints no ok for a walk that missed part of the tree, and spells every command by cli_spelling."
---

# What happened

On a Hestia host `lazysite/auth/` is `ispadmin:www-data 2770`. The store files in it
(`address-profiles.json`, `acls.json`, `oauth.json`, `themes-created.json`) are written by the
CGI, so www-data owns them and ispadmin cannot read some. `lazysite acl set` as root was refused
and named ispadmin as the owner of `lazysite/auth/`. Run as ispadmin, the command failed: the
address-profile refusal said "could not be read. Nothing was changed." and named neither the
file's owner nor the user to run as. As www-data it worked. The check gave the same "owns
lazysite/auth/" advice. The upgrade's ADDRESS PROFILES line said a call below an unread directory
"is false until it is" renamed, when it could not tell whether there was any such call.

# The change

- `Lazysite::Util::store_run_as` names the owner of the store files a command reads and writes,
  not of the directory. Where none exists it falls back to the directory's owner; where the files
  have different owners it says so and names each. `lazysite acl`, the handlers tool, the check
  and the users tool use it. A refusal through a web door still names no unix user (ruling 243).
- The address-profile refusal of a rule (and of a page) names the user that ran, the file's owner
  and the user to run as, and keeps "Nothing was changed".
- The upgrade's ADDRESS PROFILES line says it could not check the directory for `visitor.in_list`
  or `visitor.in_any` calls, names the directory's owner, and says to rerun the upgrade as root or
  that owner and then `lazysite check`. It no longer says calls are false.
- The check prints no ok line for a walk that could not read part of the tree (the form patterns,
  protected content, the template cache, ownership, content history, content provenance, theme
  assets, the asset mirror); the warning names the user who owns what was not read. A failed
  acls.json load hid every page from the public page set silently; the page walk now names the
  store, so the title check warns instead of saying "0 public page(s)" (`t/tools/652`).
- Every remedy the check prints spells the command through `cli_spelling`, never a bare
  `lazysite` (`t/tools/653`).

# Tests

`t/tools/650` (the helper and the three tools, with different real owners made from a symlink to a
root-owned file, since the test user cannot chown), `t/tools/651` (the profile refusal), and
`t/tools/331` (the upgrade's words).
