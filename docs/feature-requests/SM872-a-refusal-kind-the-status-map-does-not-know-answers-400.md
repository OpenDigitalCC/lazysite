---
id: SM872
title: "SM872: four low-risk defects found while clearing 0.14.0 - a refusal kind that cannot reach its status, a dead verb in four operator remedies and one user-facing message, a lint that hand-picked its readers, and a `path` holding a URL"
subtitle: "SM670's %REFUSAL_STATUS is entirely hyphenated and six kinds in the tree are not, so `no_such_table` answered 400 while the data endpoint answered 404 for the same condition. SM659's deleted `setup-manager` was still named in five places including the message a fresh install shows. t/lint/138, written to find every reader, read seven files it was pointed at. And SM863's `path` carried an absolute URL on every site with a site_url."
brand: plain
status: shipped
raised: 2026-09-12
raised-by: dev (pre-0.14.0 sweep), 1315B-02 correction (site agent) for the fourth
area: control-api, installers, tooling
---

# Why these four are one filing

The release manager asked, before the stable cut: *"if there are low risk fixes
needed, then do that befor the release, lets not ship known problems we could
have fixed."* These are what that question turned up. They are unrelated in
subject and identical in shape - **a declaration the code does not keep, in a
place nothing checked** - so they are recorded together.

Three were found by asking "what else reads this?" rather than by a failure.
The fourth was found by the site agent on a live instance, in code I wrote the
day before.

# 1. A refusal kind the status map cannot reach answers 400

SM670 (ruled 2026-09-11) gave every control-API refusal an HTTP status keyed by
its `kind`, defaulting to `400 Bad Request`. Every key in
`Lazysite::Manager::Common::%REFUSAL_STATUS` is hyphenated. Six kinds in the
tree are not:

```
no_such_table        6 sites   want 404   got 400
no_such_row          2 sites   want 404   got 400
no_such_form         1 site    want 404   got 400
db-table-missing     1 site    want 404   got 400
needs_confirmation   2 sites   want 409   got 400   (`confirm` is mapped)
has_submissions      1 site    want 409   got 400   (`in-use` is mapped)
```

A kind the map does not know is **not an error anywhere** - it takes the default
in silence. So a table that does not exist answered *"your request was
malformed"* on the control API, while `lazysite-data.pl:376` answered 404 for
the same condition, deliberately and with a comment explaining why. **Two
surfaces, two answers, and nothing between them.**

## The default was the defect, not the six

A map with a silent fallback cannot tell a deliberate 400 from a forgotten one.
Mapping six names fixes today and leaves the next kind to regress the same way,
which is why the fix is a map entry **and** `t/lint/139`: every `kind => '...'`
the tree emits must either be in the map or be named in that test's
`%DELIBERATE_400` list. Fifty-nine kinds are correctly 400 and are listed there;
adding a name to it is now a decision someone made rather than an omission
nobody sees.

`t/lint/139` was verified by putting the defect back
(`tmp/prove-lint139-can-fail.sh`): it fails on three assertions with
`no_such_table` unmapped, and is green with it mapped.

## Not fixed here: the `store_` family

`lib/Lazysite/Data/Tables.pm:275` builds `'store_' . $why->{reason}` at run
time, so that family can never be mapped by name and the lint can only see the
literal stem. The store-inspection failures it covers are arguably **500**s,
which is a decision about semantics rather than a rename, and the reasons are
not enumerated anywhere. Filed as [[SM873]] and exempted in `t/lint/139` with
the reason recorded at the exemption - **known-unmapped rather than silently
unmapped**, which is the distinction this filing exists to draw.

# 2. `setup-manager` was still named in five places, one of them user-facing

SM659 renamed `setup-manager` to `setup-sysop` and kept **no alias**; the tool
answers the old name with usage and exit 2. SM864 found two readers still naming
it. Three more survived, and the worst is not a comment:

**`lazysite-manager-api.pl:341`** - the message a site with no manager account
shows its operator:

> "This site has no manager account yet. Create one from the command line with:
> `lazysite-users.pl --docroot <docroot> setup-manager`"

**SM865 made this bite.** The installer no longer seeds an account, so this is
now the state of *every fresh install* - and the first instruction a new
operator reads names a command that exits 2.

Also fixed: `tools/lazysite-check.pl` (four operator remedies),
`docs/architecture/security.md` (two places teaching it as current), and a
narrative comment in `tools/lazysite-users.pl`.

Two of `lazysite-check`'s four remedies were **wrong beyond the name**, and were
rewritten rather than renamed:

- *"a manager group exists but `manager: enabled` is not set"* now names the
  one-line conf edit. The group is already there; telling the operator to create
  an account is not the remedy for a missing key.
- *"manager user has no password"* now names `claim-create <username>`. The
  account exists - what is missing is a credential, which is what SM863's claim
  link is for.

# 3. The lint written to find every reader read seven files

`t/lint/138`'s own header says a rename *"lands wherever the author was looking
and survives everywhere else"* and cites
`feedback_a_declaration_the_code_ignores` - **find every reader**. It then
hand-picked a list of seven readers. `tools/lazysite-check.pl` was not on it,
which is why four dead remedies shipped through a check written to catch exactly
that.

The default is now inverted: **every tracked file is a reader** unless it is
somewhere the project records history (`CHANGELOG.md`, `docs/review/`,
`docs/feature-requests/`), where naming a retired verb is correct and removing
it would falsify the record. 49 files are scanned where 7 were.

## And it matched line by line, which hid the worst instance

The user-facing message in item 2 is built by concatenating over three lines,
putting `lazysite-users.pl` on one and `setup-manager` on the next. A per-line
grep saw two innocent lines. The check now flattens newlines, comment markers
and string glue before matching.

**The first attempt at that flattening also stripped `.`** - which is inside
`lazysite-users.pl` - so the rewritten lint passed by matching nothing at all.
It was caught by asking why a check had gone green before the defects were
fixed. A check that passes by finding nothing is worse than the gap it replaced.

# 4. `path` carried an absolute URL wherever a site_url resolved

Found by the site agent running 1315B-02 on edge, after correcting their own
earlier report that the ref was unrunnable.

```text
path : https://edge.explore.lazysite.io/claim?u=...&c=lzc_...
url  : https://edge.explore.lazysite.io/claim?u=...&c=lzc_...
```

SM863 fixed `url` (absolute or absent) and left `path` holding `_claim_url`'s
output - which is absolute whenever a site base resolves. The comment directly
above the line said *"`path` always carries the relative form"*. The line below
it did not. A caller choosing between the two keys got no signal from either.

Fixed with `_claim_path`, which `_claim_url` now builds on, so the two cannot
drift again.

## The test could not have failed

`t/tools/74` asserted `defined $r->{path}`, in the fixture with **no**
`site_url` - the one state where path and url are both relative. Wrong fixture,
and a defined-ness assertion where the claim was about shape. It now runs both
states and asserts the shape; verified against the original defect with
`tmp/prove-t74-can-fail.sh`.

This is the third test in this release cycle that passed against the bug it was
written for (see [[SM856]]'s fixtures and `t/lint/138` above). The common cause
is a fixture chosen to make the feature work rather than to tell right from
wrong - `feedback_verify_the_gate_tests_what_you_think`.

# Cost

`work_users_tool_statements` moves **3263 -> 3267**, all four statements from
`_claim_path`, attributed by measuring the counter with `lazysite-users.pl`
alone reverted (`tmp/attribute-bench-delta.sh`). Baseline moved one key by hand.
The alternative - inlining the path at its one call site - costs no statements
and duplicates the URL shape in two places, which is the drift that produced
this defect.

# Related

[[SM670]] (the status map), [[SM659]] (the rename), [[SM863]] (the claim link),
[[SM864]] (the first two dead readers), [[SM865]] (which made item 2 reachable),
[[feedback_a_declaration_the_code_ignores]],
[[feedback_verify_the_gate_tests_what_you_think]].
