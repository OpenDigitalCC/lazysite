# Dimension 1 - Correctness and groundedness - lazysite eight-dimension review

- Audited tree: `main` at `v0.10.8` (`ec6fe0a`), worktree `/srv/projects/lazysite-audit`
- Date: 2026-08-14
- Regime: Commercial
- Prior verdict: PASS (2026-07-18, 0.8.0 gate)

## Verdict

**REFUSE** at the audited tree, for one reproducible defect that is live in the
released 0.10.8 edge build (F1.1). The remedy exists and is written, on a branch
awaiting review; it is not in the audited tree, so the audited tree refuses.

Everything else assessed on this dimension passes. The full suite is green
(357 files, 7336 tests), no symbol or API groundedness problem was found in the
0.9.x/0.10.x work, and the programme that dominates this period - SM285 to
SM293 - is unusually well grounded, because much of it consists of the engine
being made to *check* claims it previously asserted.

## Method

- Ran the full suite on the audited tree (`prove -lr t/`).
- Verified each 2026-07-18 finding as fixed or open rather than assuming it.
- Read the SM285-SM296 filings against the code they claim to have changed,
  concentrating on the recurring defect class this project has named for itself:
  a control that reports success without doing the work.
- Checked the two module-free copies ADR 0001 requires against the modules they
  mirror, via the lints that pin them (`t/lint/35`, `t/lint/37`).

## Findings

### F1.1 - `File::Path::make_path` croaks, so the guard after it is unreachable, and a protect call dies with the content still served (REFUSE)

`lib/Lazysite/Private.pm:223` and `:261`:

```perl
make_path($parent) unless -d $parent;
return ( 0, 'cannot create the private store' ) unless -d $parent;
```

That reads as though failure arrives as a false return. It does not:
`make_path` **croaks**. The guard on the second line is therefore unreachable,
and the die goes straight out through `action_acl_set`, past the warning and
past the audit write.

The state it leaves is the reason this refuses rather than warns. The ACL is
saved *before* the move, so after a crashed call the stored rule is complete and
`acl-get` returns it; pages answer 302 to an anonymous request; **static files
answer 200, byte-identical to the source**; and the call is absent from the
audit trail, because the process died before the audit write - so the trail and
the stored ACL disagree about whether anyone protected that content.

A protected folder gating its pages and serving its images is SM283 exactly,
reached through the mechanism built to make that structurally impossible.

Reported from a 0.10.8 site over both partner surfaces (MCP `set_permissions`
returned `-32603`, control API `acl-set` returned HTTP 500), and reproducible
in-tree. `Lazysite::Private`'s own invariant held throughout - the content was
in exactly one tree, and the failure direction was "not moved" rather than "in
both" - so nothing was lost or duplicated.

Remedy: filed as SM296 and implemented on `claude/sm296-acl-set-crash`
(`_mkpath` captures the error and returns; `make_path` is no longer imported
into that module, because an unqualified call is how this happened). Not in the
audited tree.

### F1.2 - The recurring defect class is now being caught by the project itself (PASS, noted)

Worth recording because it is the trend that matters more than any single
finding. Five instances of "a control reported success without doing the work"
were found and closed in this period - SM278, SM283, SM285's own probe, SM291
and SM296 - and in three of those the finder was the project's own test or check
rather than a user.

The clearest case is SM285: `lazysite check --check-acl` shipped with its
extension list in a file-scoped `my` **below** the main body, which exits before
reaching it. The list was empty, so the probe made zero fetches, compared
`0 == 0`, and reported "the front end respects the ACL" against a port with
nothing listening. A security check that passes by testing nothing is precisely
the defect the programme exists to remove. It has a regression test, and
`t/lint/39` now refuses state below the dispatch generally.

### F1.3 - ADR 0001's module-free copies are pinned by behaviour, not by text (PASS)

The 2026-07-18 review left a WARN on ADR 0001 saying "one recorded copy" while
two existed. At the audited tree there are more copies, not fewer - but each is
now pinned by a lint that **drives both implementations and compares answers**
rather than diffing source: `t/lint/35` (group resolution), `t/lint/37`
(engine-dir resolution). That is the stronger form, since two implementations
that read alike can still disagree.

The ADR text has not been updated to describe the current arrangement, which is
a documentation item rather than a correctness one - carried to D7 as F7.3.

### F1.4 - Prior findings verified

| Prior finding | State at this tree |
|---|---|
| F6.10 stored XSS via front-matter `lang:` | Fixed, regression test present |
| F6.11 `domain-add` CRLF | Fixed |
| Six `:utf8` fail-open readers | `:raw`, with the regression test still passing |
| ADR 0001 "one recorded copy" | Still inaccurate as text; see F1.3 / F7.3 |

## Evidence

- `prove -lr t/` on `ec6fe0a`: 357 files, 7336 tests, `Result: PASS`.
- `lib/Lazysite/Private.pm:223`, `:261` - the croaking call.
- `docs/feature-requests/SM296-protecting-content-crashed-and-left-it-served.md`.
- `t/lint/35`, `t/lint/37`, `t/lint/39` - the pinning and the trap check.
