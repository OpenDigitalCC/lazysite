---
title: "SM323 - protecting content had become an operator-only operation"
subtitle: "Two code paths created the private store with different ownership, and whichever ran first decided whether the manager UI, MCP and the control API could protect anything"
brand: plain
status: shipped
status-note: "SHIPPED in 0.10.11, and it is a defect in SM313 - my own fix from 0.10.10. Private::_mkpath used a bare make_path, so the store took the identity of whoever created it; the operator sweep runs as the SITE USER and gets there first on any site being repaired. Store directories now carry the DOCROOT's identity at every level created, and check --fix REPAIRS an existing store and its contents rather than only creating a missing one. SM321's runtime_paths declaration is the permanent fix - with the store provisioned at install, neither path has to decide. FILED 2026-08-16 from the 0.10.10 field validation."
---

# What was found

Measured on 0.10.10 with a fresh folder on a site whose docroot was writable and
whose operator sweep had already succeeded:

```json
{"ok":1,"content_moved":0,
 "warnings":["... could not move \"/home/.../public_html/zz-1010\" into place:
  Permission denied ..."]}
```

`list_files` reported 11 of 11 entries still public. An anonymous probe under the
active read rule: **eight of ten extensions served 200**.

The same rule applied by `acl reapply` on the same instance moved its content
successfully. Two paths applying an identical rule, different privilege, only one
working.

# The cause

```datatable
columns: Creator | Runs as | Result
widths: 5.4cm | 3cm | X
bold: 1
tone: medium
---
`Private::_mkpath` | the CGI, or the sweep | a bare `make_path` - umask default, no group write
`check --fix` (SM313) | root | site user : CGI group, 2770
---
```

Whichever runs first decides. On a site being repaired the sweep gets there
first, so the store ends up owned by the site user and the CGI - which must write
into it on every protect - is locked out.

SM313 also taught `--fix` to CREATE a missing store and stopped there, so a store
that existed in the wrong shape was reported on every run and repaired by
nothing.

# Why it matters more than a permissions bug

**The manager UI, MCP and the control API could not protect content. Only the
operator could.** That is backwards on a product whose partner surfaces exist to
do exactly this, and it is silent: the call returns `ok:1` with a warning, and
the content stays served.

# The fix

Store directories carry the **docroot's** identity - not their own parent's.
`Util::secure_write_perms` mirrors a path's parent and is the obvious helper and
the wrong one: the store's parent is the domain folder, root-owned 0551 on the
Hestia layout, and mirroring it would lock out everyone.

Mode 2770 rather than the docroot's 2775: setgid so moved content keeps the
group, and no world bit, because content in this tree must not be readable by
anything that has not asked the engine.

`check --fix` now repairs an existing store **and its contents** - a store
populated by a sweep running as the site user holds files the CGI cannot rewrite
either, and un-protecting has to move them back out.

# Related

SM313 (whose fix this corrects), SM321 (the declaration that removes the race
entirely), SM286 (the flip that introduced the move), SM283 (the exposure a
failed move leaves live).
