---
title: "SM586: YAML's own `false` is false"
subtitle: "SM519 set out to stop `no` being read as true. It ended up refusing `public: false` - the one value that makes a table private - while telling the author that `false` was acceptable."
brand: plain
standard-margins: true
status: shipped
status-note: "FOUND BY THE SITE AGENT 2026-08-25, ten minutes into the 0.10.32 retest, on a live site with the upgrade as the only change; they verified it against 0.10.31 where the same declarations had worked. CAUSE, reproduced directly: YAML::PP returns a bare `false` as a DEFINED, ZERO-LENGTH STRING; SM519's _bool checked definedness, then ref, then membership of %TRUE/%FALSE, and '' is in neither - so it fell through to the refusal, while `'false'`, `0`, `no` and `off` (all non-empty) passed. The message named `false` as acceptable while rejecting it, which leaves an author no reason to suspect the value they wrote. SHIPPED 0.10.33: the empty string is false. WHY NOTHING CAUGHT IT: SM519's own tests and every fixture in the suite declare `public: true` or omit the key - a test that only exercises the permissive value passes straight through a bug in the restrictive one, and the restrictive one is the default posture for a table holding real data. t/unit/data/01 now drives the YAML TEXT for six spellings, so the parser's representation is what is pinned rather than a hash the test built itself."
---

# The lesson worth keeping

A validator was hardened, its tests exercised the value that was already
working, and the value the hardening broke was the one that mattered
most. The general form: **when a check gains strictness, the test that
proves it must use the input the strictness is about** - and, where a
parser sits in front, the parser's own output rather than a hand-built
equivalent.

# Proving test

`t/unit/data/01`: `public:` written as `false`, `true`, `'false'`, `0`,
`no` and `off` in YAML TEXT, each loading and yielding the right flag.
