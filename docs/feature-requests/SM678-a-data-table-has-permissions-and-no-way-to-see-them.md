---
title: "SM678: a data table's permissions are settable over the API and invisible in the manager"
subtitle: "Release manager, 2026-08-28: 'data tables don't seem to have any ui in manager for permissions and owners, although the api seems to be able to set them'"
brand: plain
standard-margins: true
status: partial
status-note: "PARTIAL (PENDING). THE AUDIT HALF SHIPS: the Data page shows who may read a table, on the same ACL key the data layer enforces on (`lazysite/db/tables/<table>`, from Data::Access::acl_key - the test pins the two together, because a page reading a different key would show a rule that is not the one being enforced, which is worse than showing nothing). "No rule" and "a rule naming nobody" are distinguished, per SM635's argument for a protected file row. Read through mgJson, per SM461. NOT DONE: EDITING from this page. The rights editor - buildRights, addPrincipal, savePerms - lives inside files.md and is generic over an ACL path, so the correct fix is to extract it into the layout's shared helpers where mgConfirm and mgDirtyGuard already live, and have both pages use it. That is a refactor of a working page and was deliberately not attempted inside a batch of seven with a release pending; duplicating the chip rendering onto this page instead would have been the copy this project removes on sight."
---

# The observation is exactly right

A data table's read access is an ACL entry like any other. `Data::Access`:

    sub acl_key { return "lazysite/db/tables/$_[0]" }

so `acl-set` and `acl-get` reach a table's access with the same verbs that reach
a page's, and `may_read` consults it through the shared `_acl_allows`. The
mechanism is complete and the API can drive it.

The manager cannot. Its only ACL editor - the rights grid, the add-principal
picker, the owner row - is rendered inside a FILE's expander on the Files page.
A table is not a file, never appears in that listing, and so never gets the
editor. The Data page has no permissions UI at all.

# Why this matters more than a missing panel

A table is where a site's personal data lives. The one object whose access an
operator would most want to see is the one the manager cannot show them, so:

- an operator cannot AUDIT who may read a table without reading `acls.json` or
  calling the API
- an ACL set by an agent or a script is invisible to the person accountable for
  it
- an operator who assumes "no UI means no setting" concludes tables are
  unprotected, or that content scope confines them - which the site agent
  already reported as a false assumption on 0.11.3 (a scope over content paths
  does not confine a domain-less table)

That last one is the shape of the problem: silence reads as "there is nothing
here", and there is something here.

# What it needs

The rights editor already exists and is generic over an ACL key - it is the
`buildRights` / `addPrincipal` / `savePerms` set in `files.md`, which acts on a
path. A table's key is a path-shaped string. So the work is to make that editor
reusable outside the Files row and render it on the Data page for
`lazysite/db/tables/<table>`, rather than to build a permissions UI.

Worth doing at the same time: say on the table listing whether a table HAS an
ACL, the way the Files listing marks a protected row (SM635). "No rule" and "a
rule nobody has looked at" should not look the same.

# Related

[[SM635]] (a protected row says so where the operator is looking - the same
argument for files), SM611 (a data table should belong to a site - the other
half of "who can reach this table"), [[SM679]] (the row count on the same
listing), the site agent's 0.11.3 finding that content scope is not data
isolation.

# Done in 0.11.5

The editor was EXTRACTED, not copied. It now lives in the manager layout as
`window.mgRights` - `chip`, `build`, `toggle`, `remove`, `collect` - beside
`mgConfirm` and `mgDirtyGuard`, which is where the page-shared helpers already
are. The DOM it emits is byte-for-byte what `files.md` produced, so that page's
markup, CSS and tests were untouched; `chipHtml`, `buildRights`, `toggleRight`
and `removeChip` survive there as one-line delegations, which keeps the call
sites the rest of the page speaks in.

`data.md` uses it on `lazysite/db/tables/<table>`, read with `acl-get` and
written with `acl-set`. The panel replaces a `window.alert` that displayed the
rule and then named the command-line verb for changing it - a remedy that is
not in front of the reader and, on a hosted instance, not theirs to run.

Two things the request did not ask for, found while building it:

- **The control was offered to people every call behind it would refuse.** The
  Data page is gated on `manage_data`; `acl-get`, `acl-set` and `acl-remove`
  are gated on `manage_content`. Those do not have to travel together. The
  button now renders only when `whoami` reports `manage_content`, which is the
  same shape SM676 settled for the Briefs control on the Files page: ask what
  the reader holds, and do not offer what the server will refuse.
- **Clearing a rule and storing an empty one are different acts.** No owner and
  nobody named sends `acl-remove` rather than an `acl-set` of empty lists,
  because an empty list already means "no restriction" on the read path - so
  storing one would leave a rule that reads as open on one surface and as named
  on another.

`t/unit/manager/100-one-rights-editor-serves-both-pages.t` counts the emitters
of the chip markup and requires exactly one. That is the assertion that holds:
appearance can be matched by a fork, a count cannot.

**Still open:** the listing does not yet say whether a table HAS a rule - the
second half of the request, and the SM635 argument. The panel answers it once
opened, which leaves the operator opening tables to find out.
