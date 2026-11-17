---
id: SM1461
title: "SM1461: the site user a refusal names can read the store files the command it is sent to run reads"
subtitle: "The CLI's `acl` commands read user-settings.json for display names. On a host where the web server writes that file, the site user the refusal names cannot open it."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-17
raised-by: "the 0.17.0 field walk (T2.2)"
area: auth
status-note: "OPEN, ON ONE DECISION: who is meant to be able to read a store the web server's user wrote (options below). Target 0.17.2. Nothing is changed in the code until it is ruled."
---

# What the walk found

`acl set` then `acl remove`, run as the site user the SM1447 refusal names, logged

    [WARN] [store] cannot read user-settings.json - it exists and this process
    cannot open it ... Permission denied

so the user the refusal sends the operator to cannot read every store file the command touches.

# What is behind it

Reproduced with a user-settings.json this process cannot open: `acl list` (and the commands that
return a rule) log the warning and carry on. The read is `Settings::display_names_block`, which
`Manager::Files` adds to every rule it returns so a surface can show a person's name beside the
login. The CLI sets `AUTH_DIR` for it on purpose (SM778): `acl ... --json` has carried
`display_names` since then. So the command does use the file, and an unreadable one is answered as
the fourth state (`display_names_readable` false), not as an empty name list. That part is right.

The file is written by `Settings::_write_json_atomic`: a temp file, `secure_write_perms` to 0660,
the group set to the directory's, then a rename. It is owned by whoever wrote it. On a host where
the web server's user writes it (every manager save of an account), the file is that user's, group
the directory's, mode 0660. The directory is owned by the site user with the web group and is
setgid 2770, so the site user holds the directory but is neither the file's owner nor in its group:
it falls to the "other" bits, which are empty. `acls.json` is the site user's own because the CLI
wrote it, which is why the walk saw one readable and one not.

SM428 chose 0660 "because the CLI and the www-data CGI both write here". That holds where the CLI
user is in the web group, and fails where it only owns the directory.

`lazysite check` run as the site user reports this file only as "not readable by the CGI"; it does
not say the site user, who is told to run the commands, cannot read it.

# The decision

Who may read a store the web server wrote? The options:

A
: Mode 0664 at creation for the stores a CLI command reads (user-settings.json, groups-settings.json,
  acls.json, address-profiles.json). Protection then rests on the directory (2770 admits only the
  owner and the group), and these files hold account names, emails, comments and token lifetimes.
  A site whose `auth/` is more open than 2770 would expose them; the check would have to refuse
  that directory mode first. It needs a SECURITY.md register entry.

B
: Leave the modes at 0660 and make the site user a member of the web group. This is a host
  change (root), not the engine's; `check` would name it (the user, the group, the command).

C
: Have the CLI write what the web server owns through the web server's user, never by the site
  user. Rejected before: the CLI exists for the host where nothing is running.

Recommendation: B for the engine, with the check naming it. A is simpler for the operator but
trades a stored-secret posture for convenience, which is the release manager's to rule.

# The request

R1
: Rule A, B or C.

R2
: Either way, `lazysite check` run as the site user names a store file it cannot open, the owner,
  the mode and the fix, as it does for the walks SM1447 and SM1458 cover.
