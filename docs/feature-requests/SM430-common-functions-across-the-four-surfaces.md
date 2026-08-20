---
title: "SM430: common functions across the four surfaces"
subtitle: "Fourteen independent packages that replace per-surface copies with one shared answer. The structural finding is that there are two write stacks, not four - and WebDAV's fork is justified by a policy the architecture docs no longer contain."
brand: plain
standard-margins: true
status: candidate
status-note: "PROVENANCE, RECORDED EXPLICITLY BECAUSE I NEARLY GOT IT WRONG: this survey is UNATTRIBUTED. The brief carries no author line. It names SM422's parity map as its evidence base, so it DESCENDS from that map - but the map's author has confirmed the survey, its packaging, CF-2 and the two-write-stacks framing are not theirs, and checked their own filing to establish it (their map describes three surfaces and six flags and contains none of the survey's code analysis). I credited them for it in correspondence and was wrong. Recorded as unattributed rather than defaulted to the nearest known author, because defaulting is how the record gets corrupted in the direction nobody checks. FILED 2026-08-20 from a four-track code survey (WebDAV internals, MCP wrapping, API dispatch, repo-wide side-effect inventory) read against SM422's parity map. The brief is archived at inbox/archive/2026-08-20-common-functions-across-the-four-surfaces.md and remains the detail; packages are referenced CF-1 to CF-14 within this SM. THE STRUCTURAL FINDING: there are two write stacks, not four. The manager UI, control API and MCP already share lib/Lazysite/Manager/*; WebDAV re-implements the chain inline under a header comment claiming a 'no-shared-modules policy' that docs/architecture/code-quality.md no longer contains - current policy (SM079) is the opposite. So the fork is maintained by a comment rather than by a decision, which is why every parity defect this week has had a WebDAV side. ONE PACKAGE HAS A CONFIDENTIALITY CONSEQUENCE AND SHOULD NOT WAIT FOR THE STRUCTURAL WORK - see CF-2 below; I verified its mechanism rather than taking it on report. The rest is scheduling. Each package is self-contained, states its own tests, and leaves the tree releasable."
---

# CF-2 is the one to look at first

Verified here, not taken on report: `resolve_under_docroot` resolves a
request into the **private store** when the path is gated, and `do_copy_move`
contains **no ACL code at all**. So a MOVE of protected content to an ungated
destination physically relocates the file out of the private tree into the
public docroot, and no rule follows it.

::: widebox
The consequence is accidental publication through an ordinary operation:
someone who could already read the file makes it public by moving it, with no
error and no indication. Not a privilege escalation - the mover already had
access - but it is the exact inverse of SM286's rule that protecting content
MOVES it, and the reverse has to hold too.
:::

The same package records the mirror defect: the manager's `action_delete`
contains no ACL cleanup, while DAV's DELETE does - so the comment at
`lazysite-dav.pl:625` saying "the manager's delete has always done this" is
factually wrong, and the stale-rule defect SM212 fixed for DAV still exists
on manager, MCP and the API.

# The register

CF-1 to CF-14 as filed, with the brief's own effort and dependency
assessment. The four the brief marks as small and field-visible - CF-1
(registry and nav-cache invalidation), CF-2 (ACL lifecycle), CF-3 (SM286
alias keys), CF-14 (MCP annotation and audit-list) - are landable
independently. CF-4 (the shared write-commit pipeline) is the structural
centre, subsumes CF-1/2/3 if they have not already gone, and wants the start
of a release cycle rather than the end of one.

CF-8 waits on SM422's F3/F5 verification, which is recorded there.

# Why this filing exists at all

Every cross-surface defect found this week - the upload confinement, the
history summary, the nav read, the submission store, the form-delivery
divergence - was one surface answering a question differently from its
siblings. This maps where the answers live twice.
