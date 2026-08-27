---
title: "SM619: `lazysite never writes into a site tree as root` is enforced in one probe and unenforced in the tool that creates the auth store"
subtitle: "Operator diagnosis, 2026-08-26: 31 sites came up with 16 identical failures each, every one traceable to a tree owned root:root. The operator's reading - that this can only come from running a lazysite command under sudo, and that they should all be sudo-safe - is confirmed by the source"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED in 0.11.1 (2026-08-26), drop-privileges approach, on the operator's ruling. Lazysite::Util::drop_to_tree_owner() BECOMES the docroot's owner before any write; the identity is read from the tree PER CALL, so one host serving many sites owned by different users resolves each correctly rather than assuming a constant. The group comes from the TREE, never from the user record - a site user's private group is not the group the CGI shares, and taking it from the user record would write files the web server cannot read, which is this defect pointed the other way; a sabotage caught the test being blind to that distinction because the two groups happened to be equal on the test host, so the fixture now forces them apart. Wired into lazysite-users.pl ABOVE the make_path that creates lazysite/auth: the DIRECTORY is the artefact whose group propagates through setgid, so a guard placed after it would leave exactly the thing that poisons every later write - asserted by ORDERING, not by presence. Also wired into lazysite-bundle-apply.pl, dropped on dry-run as well as --apply so a preview cannot promise work the apply then cannot do. A ROOT-OWNED TREE CANNOT SAY WHOSE IT IS, so the tool refuses and names the repair rather than guessing - guessing is how this spread; --as-user names the owner for that case. NOT IN SCOPE, checked and excluded rather than missed: import-field-practice.pl writes into the repo (starter/docs/), not a site tree; lazysite-server.pl is a dev server run from a checkout, where dropping would break local development. WHAT IS NOT MEASURED, stated here as well as in the test: the branch that performs a SUCCESSFUL drop. Exercising it needs a root context with a second uid mapped, and `unshare -r` without newuidmap maps only one, so a mutation making that branch a silent no-op that still reports success passes the suite. The REFUSAL path is measured for real - t/unit/tools/70 runs the tool under `unshare -r`, where the euid is genuinely 0, and asserts exit 2. Five of six sabotages fail; the sixth is this gap. ORIGINAL FINDING BELOW. FOUND BY THE OPERATOR, not by a gate, from a fleet sweep after the 0.11.0 upgrade. THE RULE IS ALREADY WRITTEN, in tools/lazysite-check.pl:2291-2294: `SM139: lazysite never writes into a site tree as root, because root-owned files there are exactly what stops the manager working afterwards (the Class-B drift SM215 repairs). So as root this probe declines to establish the state rather than establishing it badly.` It is enforced in exactly ONE place - `_probe_may_protect` - and nowhere else. tools/lazysite-users.pl performs 16 site-tree writes, has NO root check and NO chown, and it is the tool that creates lazysite/auth/, auth/users, auth/groups and appends to logs/audit.log. Those are precisely the four paths the field report shows as root:root. SETGID TURNS ONE MISTAKE INTO A TREE-WIDE ONE: lazysite/auth is created 2770, so once its group is root every file and directory created beneath it afterwards INHERITS group root, including material written later by tools that are themselves well behaved. That is why a single sudo run explains cache/, forms/, layouts/, manager/locks and lazysite-assets all reading group root, and why the damage keeps widening without anyone running anything new. THE REMEDY PROPAGATES THE DISEASE: lazysite-check's own remediation hint for an undecided capability is `perl tools/lazysite-users.pl --docroot ... group-set ...`, printed without a `run as the site user` caution, to an operator who is already looking at a root-owned tree and will reach for sudo. AUDIT OF THE 15 SITE-WRITING TOOLS: lazysite-check.pl (4 root checks, 29 chowns) and lazysite-cli.pl, lazysite-pool.pl, lazysite-hestia-domain.pl are handled. lazysite-users.pl (16 writes), lazysite-bundle-apply.pl (3), lazysite-server.pl (8) and import-field-practice.pl (1) are not. NOT THE SAME AS SM270, and both are live: SM270 is Hestia's v-rebuild-web-domain re-applying 2751 on every panel-driven rebuild, which strips group WRITE and is repaired only when a lazysite deploy runs. This one changes OWNERSHIP and is caused by lazysite's own tools. A site can have both, and these 31 do."
---

# The rule, and where it is kept

`tools/lazysite-check.pl:2291`

> SM139: lazysite never writes into a site tree as root, because root-owned
> files there are exactly what stops the manager working afterwards.

| Tool | site-tree writes | root-aware | chowns |
|---|---|---|---|
| `lazysite-check.pl` | 14 | 4 | 29 |
| `lazysite-cli.pl` | 4 | 4 | 2 |
| `lazysite-pool.pl` | 3 | 3 | 2 |
| **`lazysite-users.pl`** | **16** | **0** | **0** |
| `lazysite-server.pl` | 8 | 0 | 0 |
| `lazysite-bundle-apply.pl` | 3 | 0 | 0 |

# Why one mistake spreads

`lazysite/auth` is created `2770` - setgid. Once its group is root, everything
created beneath it inherits group root, including writes by tools that are
themselves correct. One sudo run explains a whole tree, and explains why the
damage widens with no further mistakes.

# The three candidate fixes

1. **Refuse**, as `_probe_may_protect` does. Honest, and breaks `sudo setup-manager`,
   which is a reasonable thing for an operator to want to do.
2. **Drop privileges** to the docroot's owner and re-exec. Keeps the workflow.
3. **Chown what was written** to `<docroot owner>:www-data` on the way out.

2 or 3. 1 alone would turn a silent corruption into a blocked operator, which
is better but not good.

Whichever is taken, `lazysite-check`'s remediation hints that name a writing
tool should carry the identity to run it as - the hint is read by someone
already staring at a root-owned tree.
