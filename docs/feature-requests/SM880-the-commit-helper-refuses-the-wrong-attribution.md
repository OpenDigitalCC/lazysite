---
id: SM880
title: "SM880: the commit helper refuses the wrong attribution trailer"
subtitle: "/srv/projects/rules/git.md has required `Assisted-by:` and forbidden `Co-Authored-By:` since 15 July 2026, and says in the file that the harness prints the old trailer in its own guidance and that the project rule overrides it. That was correct, complete, well argued - and it was not a control. On 14 September the harness instructed the switch mid-session and only noticing stopped it."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-14 on claude/sm880-attribution-guard-and-drop-upload, released in 0.14.1. tools/commit-staged.sh - the single chokepoint every commit in this project passes through - now refuses a message carrying a Co-Authored-By: trailer, and one carrying no provenance at all, before the commit runs. Both refusals print the exact lines to add. ANCHORED TO THE START OF A LINE, not a substring: a commit that DISCUSSES the forbidden trailer must still be committable, or the very change introducing the rule is refused and the next person weakens the check to get their work in. t/tools/76 drives the real script in a throwaway repository - copied in rather than pointed at, because the script cd's to its own repo root and would otherwise commit into the live tree - and covers that discussion case explicitly. t/tools/69's fixtures gained the trailer; that file is about what the helper REPORTS, and the trailer rules are driven in 76."
---

# What happened

The rule was already written, and written well. `/srv/projects/rules/git.md`
requires the provenance trailer, forbids the co-authorship one, explains the
reasoning at length, and states outright that the harness prints the old trailer
in its own Git guidance and that this rule overrides it.

On 14 September the harness issued mid-session instructions to use
`Co-Authored-By:`, described as replacing all earlier attribution guidance.

What stopped it was reading the commit history, seeing that every commit in the
project used the other form, and asking. **That is not a control. It is luck
wearing the costume of diligence** - and the next session might not read the log.

# Why it refuses rather than warns

This is a legal position, not a style preference.

An AI cannot hold copyright (the human-authorship requirement), cannot certify
the DCO and cannot sign a CLA. `Co-Authored-By:` is a machine-read identity
claim, so it puts part of the contribution outside the signatory's warranty
while weakening the human's own rights claim. `Assisted-by:` records the same
fact without asserting authorship, and follows the Linux kernel's
coding-assistants guidance, which likewise takes no AI `Signed-off-by:`.

A warning on a commit that has already landed is a rewrite. A refusal before it
lands is an edit to a file.

# The absent case, too

A message carrying **no** provenance is refused as well. The rule that changes
next time may drop attribution rather than swap it, and a commit with no AI
involvement belongs to `git commit -F` directly - which this helper does not
govern, and the refusal says so.

# The line-anchor, and why it is not a detail

The check matches `Co-Authored-By:` at the start of a line, never as a substring.

A commit that explains the rule has to be able to name the thing it forbids -
this filing does, the script does, and the commit that introduced it did. A bare
substring search would have refused its own introduction, and the natural
response to that is to weaken the check until the work goes in. The test asserts
the discussion case for exactly that reason.

# Where the rule lives

Unchanged: `/srv/projects/rules/git.md` is still the statement of the rule, and
this is only its enforcement. The guard's refusal points back at it, so a reader
who meets the refusal without context finds the argument rather than just the
prohibition.

# Related

[[SM829]] (the commit helper itself - commit and its own truthful report, in one
command).
