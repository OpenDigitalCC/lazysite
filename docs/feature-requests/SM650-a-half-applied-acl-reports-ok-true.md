---
title: "SM650: an ACL that was saved but could not move its content reports `ok: true`, and `ok` is the field every caller reads"
subtitle: "Site agent, 2026-08-25: the gate works, the warning text is a model of what an error should say, and the status makes both invisible to a script"
brand: plain
standard-margins: true
status: candidate
status-note: "FILED FROM AN INBOX BRIEF (archived at inbox/archive/), reported by the site agent 2026-08-25 on build 0.10.32 while setting up a gated data-entry application on a freshly provisioned instance. Every acl-set on a content path returned ok:true with content_move_failed:1 and a warning saying the rule is in force but the files never moved out of the document root. THE UNDERLYING CONDITION IS A HOST FAULT and the warning says so plainly - it names the fault as server configuration rather than a permission decision, names the diagnostic (`lazysite check`) and names the repair (`lazysite check --fix` for a docroot that came back from a control-panel rebuild without group write). THE REPORTING IS THE DEFECT, not the condition and not the wording. A caller reads `ok`. `ok` said true. So a half-applied ACL - engine honouring the rule, files still sitting in the document root where any front end serving them without asking the engine would not be covered - is indistinguishable from a clean one to everything that automates against this API. WHAT IS NOT ASKED FOR: the warning text needs no work; the agent called it a model of what an error should say. It needs a STATUS that makes a script look at it. Related: SM270 (a control-panel rebuild takes a site's writability away), which is the usual cause of the host condition."
---

# What the call returns

    acl-set&path=/reconciliation
    -> {"ok":true, "content_moved":0, "content_move_failed":1,
        "warnings":["the permission was saved, but the content could not be
         moved out of the document root ... The rule is in force - the engine
         honours it - but the files are still where they were, so a front end
         that serves them without asking the engine would not be covered."]}

Two facts in one response: the rule is in force, and the content is not where
the rule assumes it is. The first is reported in `ok`. The second is reported
in a field nothing reads.

# Why it is easy to miss, which is the point

The gate genuinely works. Everything under the rule answers `302` to an
anonymous visitor, including the `.html` spellings, and no static copies appear
inside the section. An operator proving the gate with an unauthenticated fetch
gets the right answer and stops looking.

So the failure is invisible from both ends: the API says success, and the
manual check confirms it. What is left undone only matters when something
serves those files without asking the engine - which is exactly the condition
nobody tests for, because by then the gate has been proved.

# The fix, and the part that needs no work

**Stop reporting a half-applied ACL as `ok: true`.** Either a distinct status,
or `ok: false` with the response saying plainly that the rule is nonetheless in
force - because it is, and a caller that retries or backs out on a false would
otherwise do the wrong thing.

The warning text stays as it is. It names the fault as a server configuration
problem rather than a permission decision about the request, names the
diagnostic and names the repair. That is what an error should say; it simply
needs a status that makes a script look at it.

`content_move_failed` is already in the response as a machine-readable count,
so a caller *could* check it. Nothing documents that they should, and `ok` is
the field everything reads. A second field that callers must learn about is not
a substitute for the first field being right.

# Why this matters beyond one instance

An ACL is a security control. The distinction between "applied" and "applied to
the rule but not the files" is precisely the distinction an operator is relying
on the API to make, and it is the one case where a reassuring answer costs more
than no answer at all.
