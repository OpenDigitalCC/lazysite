---
id: SM778
title: "SM778: the display name wherever a login is handed back, and a name lookup for a page"
subtitle: "From familyhq.explore: a site rendering bylines had no route from a login to a display name except for its own viewer, so it mirrored account-holders' names into its own table and the mirror drifted until every byline read as a bare login. The engine holds the names; it hands back logins without them."
brand: plain
standard-margins: true
status: candidate
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

# Size

A morning: one resolver (`Auth::Settings::display_name_for`, which exists)
called from each listing that carries a login, and one read action
(`display-names`, body `{logins: [...]}`) on the control API with an MCP
twin. Not urgent; held for a convenient release.
