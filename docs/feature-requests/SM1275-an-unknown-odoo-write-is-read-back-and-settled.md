---
id: SM1275
title: "SM1275: an Odoo run that ended unknown is read back and settled"
subtitle: "An apply that left a change unknown names its run. Resuming it, OOM reads each unknown change back first; one it cannot read back is settled by its maker's word or an operator's. The page endpoint takes {run, resume: true}, under a confirm's token rule, rate caps and record."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-23
raised-by: "the release manager, rulings 10a and 10b (2026-10-23); task #376 part 2 (SM1244)"
area: odoo
status-note: "SHIPPED (PENDING) on n733: Lazysite::Odoo::resume on OOM 0.42's Runner->resume_plan and, for a run oomd made, Calls->resume; the run handle is the plan id; the endpoint's {run, resume: true}; unknown-outcome / settled / dismissed / not-yours. t/unit/odoo/106, 107, 108, 03."
---

# What was asked

SM1244's "Not done: part 2" said what resuming an `unknown` plan would take, and
deferred it for two rulings. They came on 2026-10-23:

- **10a.** OOM reads each change back first. Where it cannot, the run's own actor, or a
  holder of a new override capability, may assume done or not done.
- **10b.** Offered on the page (the visitor sees the unknown changes and can check
  again) and on the manager's Odoo page (SM1278).

The brief added the rules: a run handle that does not expose the journal's host path; a
`resume` action with the same CSRF rule, rate limits and audit line as apply, refused on
a public binding; "check again" for anyone allowed to run the binding, read-back only;
and the resumed plan applied through the existing path, in-process or oomd, its result
mapped by `_add_unknown` and `_add_failed_changes`.

# What OOM 0.42 offers (read from t/vendor/oom)

- **`Odoo::Ops::Runner->resume_plan($ctx, $journal_path, assume_done => [...],
  assume_not_done => [...])`**:
  - refuses a closed run (`Runs->refuse_closed`, code `closed`);
  - refuses another login's apply (`_journal_owner`, `never` for an apply);
  - settles every change the journal left `unknown`: `_made_on_read`, by `unique_by`,
    the written fields, the record's absence, a `verify`, or a custom handler's
    `unknown_outcome`;
  - a change named in an assume list is decided by it. A name that did not end unknown
    is a `usage` error;
  - with any change undecided it throws `refused/unknown-outcome` and appends nothing;
  - otherwise it appends the verdicts to the run's journal (`assumed`, `by`, or `read`)
    and returns a plan of what failed, was not attempted, or was read as not made.
- **`Odoo::Ops::Calls->resume($journal, %o)`**: the same request to oomd, `phase =>
  'resume'`, `options => { assume_done, assume_not_done }`. The daemon's
  `Service->_resume` holds the journal to its `runs_dir` and answers `kind => 'plan'`
  with the new `run_id`.

# What shipped

- **The run handle.** An apply that ends with `unknown` changes now answers
  `run => <plan id>` and `may_assume`. That is an immediate apply, a confirm, or a resume
  that leaves one again. The handle is the 128-bit plan id, so the journal's host path
  stays out of every answer. The plan's `meta.json` records `unknown {at, count}` and the
  account the run used (the key file's id and the login, never a key). A resume then runs
  as the same Odoo login, which OOM requires.
- **`Lazysite::Odoo::resume($run, %ctx, assume_done, assume_not_done)`**, in this order:
  1. The assume lists are lists of up to 100 keys or numbers.
  2. The run must exist, have ended unknown, and not be withdrawn. Otherwise it is
     `not-found`, the same answer for every case.
  3. A binding with `public` in its modes is refused (`mode`), unless the caller holds
     `settle_odoo_writes` (SM1276).
  4. A dismissed or settled run is refused (`dismissed`, `settled`).
  5. An assume list from anyone but the run's maker or a capability holder is refused
     (`not-yours`).
  6. A `credential: session` run is the signed-in person's alone.
  7. The binding's gate, as it stands now. An operator settling a visitor's or the
     schedule's run is gated in that run's mode where the binding does not admit theirs.
  8. `_ready`, the binding's write caps (`_take_cap`), then OOM.
- **The resumed plan applies by a first apply's path.**
  - In-process: `resume_plan`, then a new plan folder, `_approve` and `Runner->apply`.
  - For a run oomd made: `Calls->resume` of the daemon run's journal, then
    `approve`/`apply` of the run it planned. It falls back in-process with
    `odoo_daemon: on`, as a confirm does.
  - The result is `_result_summary`'s, so `_add_failures` and `_add_unknown` map it.
  - The answer adds `resumes` and `settled`: each formerly unknown change, its outcome
    and `how` (`read` or `assumed`), from the lines OOM appended.
  - A resume with nothing left to apply answers a zero result.
  - The run is marked `settled` once OOM has decided every change. A plan the resume
    applied that ends unknown again is a run of its own, named in the answer.
- **`unknown-outcome`** (409) carries `run`, the `changes` still unknown (seq, key,
  action, model, id) and `may_assume`, so a page can ask the right person.
- **The page endpoint**: `POST {run, resume: true, assume_done, assume_not_done}`.
  Like a confirm, it names no binding: `_ctx(undef)`, and the token that fits the caller
  (the visitor-bound token for a person signed in to Odoo). A multipart request is never
  a resume.
- **The record**: `@CALL_FIELDS` gains `run` and `decision` (`check`, or
  `assume-done:N assume-not-done:M`, a count and never a key). The `odoo-call` audit line
  appends `run=` and `decision=`.
- **Refusal kinds**: `unknown-outcome`, `settled` and `dismissed` answer 409. OOM's
  `closed` is said as `dismissed`.
- **Docs**: `starter/docs/odoo.md`, *A write whose answer never came*, and the
  refusals table.

# Tests

- **t/unit/odoo/106**, in-process on OOM's fake Odoo:
  - the run is named and no path is in the answer;
  - found not made: carried and applied, with the rest;
  - found made: journalled done, and the write is not sent again;
  - no read: `unknown-outcome` names the change. Another staff member may check again
    and may not assume. A bad list is refused, and so is a name that did not end
    unknown. The maker's `assume_done` settles it with nothing sent;
  - `assume_not_done`: the change is made;
  - a confirmed plan's run is settled by a holder of the capability;
  - a public binding's run: the visitor gets no handle and is refused, and an operator
    settles it;
  - not-found cases;
  - the record and the audit line carry the run and the counted decision, and no key.
- **t/unit/odoo/107**, through the real oomd:
  - found made by a handler (`LazysiteTest::OdooFail::Settle`);
  - refused, then assumed;
  - assumed not made: sent again, unknown again, and a new run.
- **t/unit/odoo/108**, the page endpoint, with a person signed in to Odoo:
  - the token rule;
  - check again (409, may assume);
  - another person is refused;
  - the maker settles it and the line is made as the person;
  - a visitor and a public binding are refused;
  - multipart is refused.

  `t/lib/OdooSessionHTTP.pm` now answers a transport error as HTTP::Tiny's 599, so the
  session transport sees an unanswered request.
- **t/unit/odoo/03**: the two new record fields.

With Odoo.pm, lazysite-odoo.pl and Manager/Common.pm at n732's tip:
- 106 fails its first subtest (no run named) and dies at the second, which calls
  `resume`;
- 107 fails its first subtest and dies in it;
- 108 fails six of its eight checks. The 207 status and the multipart refusal hold
  either way.

# Not done

- **No expiry.** A run stays resumable until settled or dismissed (10c). SM1279 keeps it
  past the plan store's days.
- **The page script and the manager's list** are SM1277 and SM1278.
