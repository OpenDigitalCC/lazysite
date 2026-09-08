---
id: SM800
title: "SM800: an empty roster is a statement about the site, so it is not printed for a store nobody could read"
subtitle: "Offered after SM770 and ruled by the release manager 2026-09-08: say 'the account store could not be read'. Building it found the cause rather than the symptom - the tool that OWNS the auth store was not in Lazysite::Stores, so lint 121 had never been pointed at the two readers that still carried the -f guard SM770 removed everywhere else."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-08 on claude/sm800-a-page-says-the-store-could-not-be-read. read_users and read_groups lost their -f guards and route through cannot_read; $STORE_READABLE rides every --api answer, set once where the answer is encoded rather than in each of thirty branches; `users list` and the manager's Users page say the store could not be read instead of showing an empty roster. AND THE CATALOGUE GAINED tools/lazysite-users.pl, which is the durable half: the file that writes the store and holds its two primary readers was not listed, so the lint written to catch exactly this defect had never looked at it."
---

# What was asked

After SM770 removed the stat guards from the auth modules, one gap was left
open and offered rather than built: the readers answer `undef` or an empty hash
for a store they could not read, which is correct for a GATE - empty means deny,
which fails closed - and wrong for a DISPLAY, where an empty table reads as a
fact about the site. `users list` printed "No users." for an unreadable store.

Ruled 2026-09-08: say "the account store could not be read".

# What building it found

The symptom was the printed line. The cause was that **`tools/lazysite-users.pl`
was not in the auth store's entry in `Lazysite::Stores`** - and that file writes
the store and holds its two primary readers. So t/lint/121, written under SM770
precisely to catch a stat guard in front of a store read, had never been pointed
at it. Both readers still carried the guard:

    return %users unless -f $USERS_FILE;
    return %groups unless -f $GROUPS_FILE;

An auth directory without its search bit answers false to both stats, so the
account store read as "no accounts" and the group store as "no groups" - in
silence, to `users list`, and to everything downstream of `read_groups`.

The lesson for the catalogue is written into the entry: **"the modules that read
a store" is not the same list as "the modules under lib/". A tool is a reader.**

# What was built

- **The guards are gone**, and both readers route through `cannot_read`, which
  names the file, the error and the unix user, and stays silent on ENOENT
  because a site with no groups file is ordinary.
- **`$STORE_READABLE`** records what the read could establish, beside the read,
  because the hash has nowhere to carry it (SM784).
- **It rides every `--api` answer**, set once where the result is encoded rather
  than in each of the thirty branches - a flag a branch has to remember is a
  flag some branch will not.
- **`users list`** says the store could not be read, and names the file and the
  directory above it.
- **The Users page** draws the warning instead of "No users". Its flag starts
  `null`, not `true`: "nobody has told us" is not "the store is fine", so the
  roster is drawn on a positive answer or on no answer at all, and withheld only
  on a negative one.
- **The catalogue names the tool**, so the lint covers it from now on. That is
  what stops the next reader in that file being written with a guard.

# What was NOT changed, and why

**The gates still fail closed on an unreadable store, and must.** `caps_for`
answering empty means "holds nothing", which is the safe direction for a
capability decision and the whole reason SM770 did not touch it. This filing is
the DISPLAY half only: the same absence, told apart at the surface where a
person reads it.

The permissions grid draws from the same `users-page` answer and now has
`store_readable` available to it; using it there is a small follow-on and is not
done here.

# Provenance

Offered by the engine after SM770 and held for a ruling. Related:
[[SM770]], [[SM784]], [[SM785]], [[feedback_absence_is_a_finding]].
