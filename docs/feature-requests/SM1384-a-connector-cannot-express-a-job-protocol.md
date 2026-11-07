---
id: SM1384
title: "SM1384: a connector cannot express a multi-step job protocol"
subtitle: "Submit, poll until terminal, read the result: a scheduled connector sends the same fixed request every time, so each poll submits a new job and nothing ever asks about the last one."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-07
raised-by: "developer agent (SM1382 spike, ruling 132)"
area: integrations
status-note: "CANDIDATE, filing only. Evidence from the SM1382 spike (t/integration/360, subtest SM1384): two scheduled polls of a submit endpoint sent identical requests and started two jobs; neither job id was asked about. Nothing built."
---

# What happens

Many remote services answer a long request as a job: **submit** it and get a
job id, **poll** the job until it reaches a terminal state, then **read** the
result. A scheduled connector cannot do this.

The SM1382 spike (`t/integration/360`, subtest "SM1384") pointed a scheduled
connector at a fixture `/submit` endpoint that answers
`{"job":"job-N","status":"queued"}`. Two ticks 300 seconds apart sent exactly
the same request, `/submit?task=report`, and the table gained two rows holding
two different job ids. Nothing asked about either.

# Why

- **Fixed fields.** A schedule entry's payload is fixed in configuration
  (`Lazysite::Handlers::action_schedule_save`: "a scheduled call carries fixed
  values only"), so a poll cannot carry a value from an earlier answer.
- **One call per delivery.** `Lazysite::Manager::Connectors::call` makes one
  request and keeps one answer. Nothing reads an answer to decide a next call,
  and a connector has one URL, so submit and status cannot be two steps of one
  thing.
- **The answer is a row, not state.** It lands in an `answer_table` row as text;
  no part of the engine reads it back.

# What it would take

A declared protocol on the connector or handler: the submit call, the field in
its answer that names the job, a status call that carries it, the field and
values that mean terminal, a bound on how long to poll, and which answer to
keep. The poll would also want a cadence finer than the scheduler's 300-second
floor, which is SM1382's limit, not this one's.

Until then, a source with a job protocol needs a process outside lazysite that
runs the protocol and publishes the result where a single call can read it
(ruling 132: such a process stays its own engine).
