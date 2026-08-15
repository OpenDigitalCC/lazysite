---
title: "SM313 - repairing the docroot does not reach the private store, and the sweep called it success"
subtitle: "The store is a sibling of the document root, so SM270's repair fixed a directory that was never the obstacle - and `acl reapply` counted a move that never happened as a re-apply"
brand: plain
status: shipped
status-note: "SHIPPED on claude/sm305-principal-picker-and-polish. THREE fixes: check --fix now CREATES the store (owned by the site user, mode 2770) rather than widening its parent - the parent is the domain folder and also holds cgi-bin, so making it group-writable would grant create/delete/rename there and close one exposure by opening a larger one; action_acl_set returns a structural content_moved flag; and `acl reapply --apply` counts a call that moved nothing as `moved nothing` rather than `re-applied`, names the cause once, and exits non-zero. FILED 2026-08-15 from a site-agent measurement taken AFTER the operator repaired the docroot on edge. SM296 predicted this cause in its own open section and it is now confirmed to survive the documented recovery."
---

# SM313 - the repair that fixed the wrong directory

## What was found

The docroot permission fault on edge was repaired, completely and verifiably:

```datatable
columns: Operation at the site root | Before | After
widths: 7.4cm | 3cm | X
bold: 1
tone: medium
---
MKCOL | 507 | 201
PUT (new file) | 507 | 201
PUT (overwrite) | 507 | 204
DELETE (folder) | 507 | 204
---
```

**Protecting content still left it served.** On a fresh folder with an active
read list, `list_files` reported 11 of 11 entries `"store":"public"`, and eight
of ten probed extensions returned 200 to an anonymous request, byte-identical to
source.

The private store is `<docroot>-lazysite-private` - a **sibling** of the
document root. Creating it needs write access on the docroot's *parent*, which
on the Hestia layout is the domain folder. SM270's repair covers `public_html`.
That is a different directory, and it was never the obstacle.

SM296 predicted exactly this in its own open section - *"it wants to create a
directory in the domain folder beside `public_html`, which may not be writable by
the CGI identity"* - and it is now confirmed to survive the documented recovery.

## Three things were wrong

### 1. The check reported it and repaired nothing

`lazysite check` has named this fault correctly since SM296. `--fix` never
touched it, so an operator following the documented repair got a clean docroot,
a still-broken store, and every signal saying the repair had succeeded.

### 2. The obvious repair would have been worse

Making the parent group-writable is "the same operation one directory up", and
it is the fix the report suggested. It should not be done.

That parent is the domain folder, which also holds `cgi-bin`. Write permission
on a directory is permission to create, delete and **rename** its entries, so
granting it to the CGI group would allow replacing `cgi-bin` outright. The
project's own installer config records the intent: `{DOCROOT}/..` is declared
mode `0755` with the note that on Hestia it is `0551`. It is deliberately not
group-writable.

**Repairing an exposure by opening a larger one is not a repair.** `--fix` now
creates the store instead - owned by the site user, mode 2770 so content moved in
keeps the group. That is strictly narrower and it removes the need for the
permission entirely: the engine no longer has to create the directory, only write
into one it already owns, so `_mkpath` becomes a no-op on the next protect.

### 3. The sweep called a move that never happened a success

`acl reapply --apply` counted every `ok:1` as re-applied. A call that stores the
rule and moves nothing returns `ok:1` with a warning - so a sweep that left every
byte exactly where it was printed **"N re-applied, 0 failed"** and exited 0.

The entire purpose of that command is to move content out of the document root.
A call that did not move content has done none of it. This is the project's
recurring defect - a control reporting success without doing the work - wearing
the uniform of the tool built to repair exactly that.

Now: `re-applied`, `moved nothing` and `failed` are counted separately, the cause
is named **once** rather than per folder (a per-folder warning on a fleet sweep
reads as advisory noise and scrolls past), and the command exits non-zero.

## Why the signal is structural

`action_acl_set` returns `content_moved`. A caller that had to string-match a
warning to learn whether content moved would silently stop matching when the
wording improved - and SM307 improved that exact wording in this same release,
which makes the point without needing a hypothetical. The sweep runs unattended
across a fleet; it cannot depend on prose.

## Verification

`t/unit/manager/76`, shown to fail before the fix:

- the store's parent is asserted to be the docroot's parent, not the docroot -
  the geometry is the whole finding, and every wrong repair proposed for this
  follows from getting it wrong;
- an unwritable parent yields `ok:1` with `content_moved: 0`;
- a healthy layout yields `content_moved: 1`, **and the bytes are really in the
  store** - the flag must mean the move happened, not that it was attempted;
- the sweep consults the flag, does not string-match the warning, counts
  `moved nothing` separately, and exits non-zero;
- `--fix` creates the store and does **not** chmod the parent.

`t/tools/04` was updated: it asserted the old message text, and now also asserts
the report says the store is a sibling and names `--fix`, which is what an
operator who has just repaired the docroot needs to be told.

## Related

SM296 (predicted this cause and left it open), SM270 (the docroot repair that
does not reach it), SM283 (the exposure this leaves live), SM285
(`check --check-acl`, the outside-in probe that catches it), SM307 (the message
this makes actionable), and
`inbox/archive/2026-08-15-docroot-repair-does-not-reach-the-private-store.md`.
