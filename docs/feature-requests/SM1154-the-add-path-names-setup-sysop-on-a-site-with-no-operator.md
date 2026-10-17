---
id: SM1154
title: "SM1154: the add path names setup-sysop on a site with no operator"
subtitle: "add (first account) and group-add (a non-operator group) print a note naming setup-sysop and the manager's Users page when the site has no operator; the help and the manager guide say it too."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-17
raised-by: lazysite-sites agent (oom-lab, L-8), accepted by the release manager 2026-10-17
area: users tool
status-note: "SHIPPED on n642: tools/lazysite-users.pl, starter/docs/manager.md; t/unit/users/55."
---

# What happened

From the oom-lab findings (L-8, "owner account"):

> Making the first account with `lazysite-users.pl add` + `group-add manager`
> gives an account with no manager access; `setup-sysop` is the way, and nothing
> on the `add` path says so.

`group-add alice manager` creates a group that is merely called manager: no
capabilities, no operator flag. The tool answered "added" to both commands, so
the lab was left with an account that could sign in and do nothing.

# What shipped

- `add`, when it creates the first account on a site with no operator, prints a
  note: the site has no operator, so the account has no manager access; the
  first operator is made with `setup-sysop --user NAME`; once an operator
  exists the manager's Users page adds accounts and puts them in the operator
  group.
- `group-add`, when it puts someone in a group that is not an operator group
  on a site with no operator, prints the same note.
- "No operator" means no member in any group carrying the operator flag
  (SM991). With an operator, both commands are as quiet as before, and joining
  the operator group is not noted. The API mode prints nothing extra.
- `--help` says it beside `add` and `group-add`; the POD (Bootstrap) and
  starter/docs/manager.md describe the first-account path.

t/unit/users/55 covers each case, with an operator and without.
