---
id: SM778
title: "SM778: the display name wherever a login is handed back, and a name lookup for a page"
subtitle: "From familyhq.explore: a site rendering bylines had no route from a login to a display name except for its own viewer, so it mirrored account-holders' names into its own table and the mirror drifted until every byline read as a bare login. The engine holds the names; it hands back logins without them."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-08 on claude/sm778-the-display-name-wherever-a-login-is-handed-back (stacked on SM773). ITEM 1: a `display_names` map beside every response that hands back a login - principals, the audit trail and its actor facet, acl-get, protected-sections, the account roster and the group listings, and the users tool's own list - added WITHOUT disturbing any existing key, so nothing that reads these responses has to change. ITEM 2: `display-names`, a read action on the control API with an MCP twin (`display_names`), reachable by any authenticated caller because it answers only for the logins it is given: it resolves, it does not list, and it is capped at 200 to keep it that way. Every response carries `display_names_readable` - SM784's fourth state - so an absent entry can be told apart from a name the engine could not read. Building it found SM785, a data-loss defect on the shipped line."
---

# The ruling (release manager, 2026-09-08)

**A person who never signs in is app data. The engine's register holds
accounts.** A family member with no account belongs in the app's own table,
as does an aggregate row ("All of us"); the platform does not carry rows
that cannot authenticate and cannot be granted anything so that one app can
join to them. The sites agent's filing relayed a wider position - one
register of people including those who never sign in - which the release
manager has not taken: that part is app internals.

What is platform is the account-holders' names, which the engine already
holds and hands back as logins.

# What is asked

1. **The display name wherever a login is handed back** - audit rows, form
   submission attribution, ACL and group membership listings, `principals`,
   the users tool's listings. (`holds` is done: SM779.)
2. **A read-only name lookup a page can call with an ordinary session**, for
   logins the viewer can already see: login and display name, nothing more.
   Behind no capability beyond being signed in; never a listing of accounts,
   only a resolution of logins the caller supplies.

With both, a site keeps a `person` table for its non-account people and its
app data, and renders account-holders by asking the engine - no mirror of
the names, nothing to drift.

# What was built

**One shape, spelled once.** `Auth::Settings::display_names_block(@logins)`
returns two keys, and every surface adds them:

    "display_names": { "sjm": "Steve Morris" },
    "display_names_readable": true

An entry appears **only** for a login that has a name. A caller that finds no
entry renders the login exactly as it does today, which is why this could be
added to eight responses without changing what any existing consumer sees. A
map that carried `login => login` would instead have made "no name set"
indistinguishable from "the name happens to equal the login".

Item 1, the places a login is handed back: `principals` (the permissions
pickers - the surface the report was about), the `audit` trail and its actor
facet (resolved against the REAL accounts only, so SM641's invented names get
no name they cannot support), `acl-get` and `protected-sections` (owner, read
and write lists, with `@group` entries dropped rather than resolved to
nothing), the account roster and the group listings, and `tools/lazysite-users.pl
list`, which now prints `sjm (Steve Morris)` so an operator can tell three
similar logins apart.

**Form submissions are not on that list, and that is a finding rather than an
omission.** The filing named them, but a public submission records no verified
actor by design - `_auth_user` was removed precisely because it could not be
trusted - so there is no login there to name.

Item 2: **`display-names`**, body `{"logins": [...]}` or a comma-separated
`?logins=` for a plain GET, with an MCP twin (`display_names`). Any
authenticated caller, on either channel, because it answers only for logins the
caller supplied: it **resolves, it does not list**, and a 200-login cap keeps
one call from being turned into a walk of the account store. Both manager
screens that carry names - `principals` and the roster - are cookie-only, which
is the other half of why the report was made: the site that needed the names is
a token client and could not have called either.

**The fourth state travels with the answer** (SM784): `display_names_readable`
is false when the account store could not be read, so a page can say "the names
are unavailable" rather than drawing a roster of people who appear to have no
names. The users tool prints that sentence.

# What building it found

**SM785**, a data-loss defect on the shipped line. The unreadable-store test
came back with an empty map and `readable: 1` - because the failing read had
been followed by `touch_credential` rewriting the store from `{}`. Every
writer of the settings store is a read-modify-write, so one ordinary API call
against a site whose settings file had lost its read permission replaced every
account's display name, comment, email, expiry, TTL and start page with the
single entry being stamped. Filed and fixed on the same branch.
