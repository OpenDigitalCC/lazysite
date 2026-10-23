---
id: SM1256
title: "SM1256: the Hestia integrator takes the certified channel"
subtitle: "lazysite-hestia-domain add refused --channel certified, which ADR 0010 added and the provision it passes the value to accepts. A code defect, not a doc one."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-22
raised-by: the lazysite.io site agent, inbox 2026-10-22-shipped-docs-out-of-step-with-0-15-16.md (D-6)
area: hestia
status-note: "SHIPPED (0.16.1) on n728: the --channel check and the usage/POD in tools/lazysite-hestia-domain.pl take certified; t/tools/212."
---

# What happened

ADR 0010 (accepted) made the ladder edge < beta < stable < certified;
install.pl, `lazysite provision` and `lazysite channel` accept all four.
`lazysite-hestia-domain add` passes `--channel` straight to `lazysite
provision`, but checked it first against `^(?:edge|beta|stable)$` and failed
with "--channel must be 'edge', 'beta' or 'stable'". So the refusal was the
integrator's own, and wrong by the ADR: a code defect. The usage, the header
and the POD listed three rungs too.

# What shipped

The check takes the four rungs and names them in its refusal; the usage, the
header comment and the POD list `certified`. Nothing else changes: the value
goes on to provision as before, which records it as the site's
`update_channel`.

# Found beside it, not changed

`tools/build-manifest.pl` also checks its `--channel` against the three-rung
list, and `tools/release.sh --certified` passes `certified` to it. A certified
cut would stop at the manifest build. That is release tooling outside this
report; it is raised for a ruling rather than changed here.

# Tests

t/tools/212 runs `add` without root: edge, beta, stable and certified each get
past the option checks to the root refusal (which runs after them), an unknown
channel is refused naming the four, and `--help` lists certified. With the old
tool, the certified cases, the refusal text and the usage fail.
