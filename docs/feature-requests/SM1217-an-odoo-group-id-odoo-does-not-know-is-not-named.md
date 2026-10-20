---
id: SM1217
title: "SM1217: an Odoo group id Odoo does not know is not named, and the report says so"
subtitle: "From OOM 0.37, core.has_groups answers an unknown group 0, like one the person does not hold. The site sign-in's unknown-groups report could not be fed any more, so it is gone. The status and lazysite check say such ids are not named, so the missing list does not read as \"all known\"."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-20
raised-by: "release manager, 2026-10-20 (the OOM 0.38 adoption, item 2); t/unit/odoo/63 on the 0.38 snapshot"
area: odoo
status-note: "SHIPPED (PENDING) on n703: site_groups no longer reads or writes odoo/unknown-groups.json. The status's site_signin carries unknown_named 0 and a sentence saying why, and so does lazysite check's line. An older file is not read. t/unit/odoo/90, 63. Sabotage: the old SiteSignin fails 90."
---

# What happened

[[SM1160]] made the Odoo sign-in the site sign-in, with `odoo_group_map` mapping
Odoo group xml ids to site groups. `core.has_groups` answered which of those ids the
person holds, and listed under `unknown` any id Odoo has no group for.
`Lazysite::Odoo::site_groups` wrote that list to `lazysite/odoo/unknown-groups.json`.
The Odoo status (`site_signin.unknown`) and `lazysite check` (a WARN per id) named it,
so the operator could correct a mistyped id.

OOM 0.37 (fixes-37 R-1, its `debian/changelog`): "`core.has_groups` answers `{ groups
=> { XMLID => 1|0 } }` only: a group Odoo does not know answers `0`, like a group the
person does not hold, and the `unknown` list is gone". On the 0.38 snapshot
t/unit/odoo/63 failed twice: "the id Odoo does not know is kept to be named" and the
status's `unknown` list. Both were empty.

That empty list was the risk. Each sign-in rewrote the file with no ids, so status and
check showed no unknown id. That reads as "every mapped id is known".

# The decision, and why

lazysite cannot find unknown ids another way. OOM drops the `ir.model.data`
`check_object_reference` call on purpose ("the operation makes one call for each
group and no more"). The OOM operations that read xml ids do so through
`ir.model.data` search_read:
- `core.rights`;
- `core.whoami` (`xmlid` "present on a group only when the user may read
  `ir.model.data`");
- `core.user`.

A person signing in seldom has that right, and the sign-in asks only as the person,
with no administrator right (SM1160). So the report is gone, and every place that
showed it now says that such ids are not named:

- `Lazysite::Odoo::site_groups` returns `{ ok, groups }` only, and writes no file.
- `Lazysite::Odoo::SiteSignin::report` (the status's `site_signin`) has no `unknown`
  list. It carries `unknown_named: 0` and `unknown_note`: "an xml id Odoo does not
  know is answered as not held, so it grants nothing and is not named here: check
  each id against Odoo".
- `lazysite check`'s line for the feature carries the same sentence, and the per-id
  WARN is gone.
- A `lazysite/odoo/unknown-groups.json` that an older lazysite wrote is not read.
  Nothing would ever correct its names, so they would be stale. The file can be
  deleted.
- The site documentation (`starter/docs/odoo.md`) says the same.

An id Odoo does not know still grants nothing. The fake in t/unit/odoo/63 no longer
answers `check_object_reference`, because 0.37 does not call it.

# Tests

- t/unit/odoo/90 (new): on a site that opted in, with a stale file from an older
  lazysite, it checks the following:
  - the report has no `unknown` list, says `unknown_named: 0` and why, and does not
    read the file;
  - `lazysite check`'s line says an unknown id is not named, and names none from the
    file;
  - a site that has not opted in gets only `{ enabled => 0 }` and no check line.

  It fails on the code before this change (6 assertions) and passes after.
- t/unit/odoo/63: Jane's sign-in writes no unknown-groups file. The status has no
  `unknown` list and carries `unknown_named` and the note.
- Sabotage: restoring the old `SiteSignin.pm` alone fails 90's first two subtests,
  and restoring the fix passes it.

# Not done

- A host on OOM 0.33 to 0.36 still gets `unknown` from `core.has_groups`, and
  lazysite no longer uses it. Keeping the report for older OOMs would mean a second
  path the gate does not test (it runs on 0.38). Bringing it back for them is the
  release manager's decision.
