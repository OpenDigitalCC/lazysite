# Dimension 2 - Code quality - lazysite 0.10.9

- Audited artefact: tag `v0.10.9` at `f8bee33`, in a clean worktree
- Date: 2026-08-14
- Regime: Commercial
- Prior verdict: PASS (2026-08-14, at 0.10.8)

## Verdict

**PASS**. Clean across every surface, and the lint suite continued to grow in
the direction that matters.

## Findings

### F2.1 - perlcritic severity 3 clean (PASS)

```
$ perlcritic --profile .perlcriticrc --severity 3 lazysite-*.pl lib tools
critic rc=0
```

Clean over a release that added a forked relay in the request path, a new CLI
sub-command, a control-API action and a compliance tool.

### F2.2 - The lint suite grew 41 to 45, and in kind (PASS)

Four added this cycle, each of the derived-or-behavioural sort rather than the
text-matching sort:

- `t/lint/42` drives both copies of the routing table and compares answers.
- `t/lint/43` derives the pool settings **from the launcher** and asserts each
  is read at file scope, because FCGI replaces the request environment per
  request.
- `t/lint/44` asserts the operator templates substitute in both directions.
- `t/lint/45` asserts every front-matter field ADR 0008 freezes actually exists.

### F2.3 - The render path continues to grow (noted, not charged)

`lazysite-processor.pl` gained roughly 340 lines for the pooled front door and
another 30 for the description fields. The mitigating property from the previous
review holds: each duplicated decision is pinned by a lint that drives both
copies and compares answers, so duplication that cannot silently diverge remains
a different thing from duplication.

The standing item is unchanged - each new module-free copy needs its own parity
lint, and the day one ships without one is the day the trade becomes a defect.

### F2.4 - Comments continue to carry cause (PASS, noted)

The new code states what went wrong when it was another shape: `make_path` is
not imported "because an unqualified call is how this happened"; the pool
settings are captured at startup with the reason FCGI makes the alternative
silently wrong; the release gate's `cd` is annotated with what adding `-l`
alone would have done.

## Evidence

- `perlcritic --profile .perlcriticrc --severity 3` - rc 0.
- `ls t/lint/*.t | wc -l` - 45.
