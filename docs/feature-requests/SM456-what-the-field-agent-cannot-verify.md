---
title: "SM456: the field agent's own tooling blocks verifications the grant permits"
subtitle: "Not a lazysite defect. A record of which findings can never be field-confirmed by that agent, so nobody plans a verification that cannot happen or reads its absence as a clean result."
brand: plain
standard-margins: true
status: candidate
status-note: "PARTLY ADDRESSED (PENDING) by SM466: the specific verification that kept recurring - what does a visitor to this Host actually receive - is now answerable from inside the grant via preview_public_page. The general complaint stands as filed: other checks the grant permits may still have no tool, and each should be reported as it is met rather than assumed covered by this one. FILED 2026-08-21 at the release manager's request, recording two denials the site agent hit while verifying this week's work. NOT LAZYSITE DEFECTS, and the filing exists so that nobody mistakes them for one or plans around evidence that cannot be gathered. BOTH ARE CLAUDE CODE AUTO-MODE CLASSIFIER DENIALS - the agent's own harness, upstream of any lazysite capability: 'Permission for this action was denied by the Claude Code auto mode classifier. Reason: Blocked by classifier.' The first blocked accessing files. The second blocked probing the control API for submissions-related actions - and the agent noted that manage_forms IS ON for that token, which is one of the two capabilities in the documented carve-out for reading submissions. THE INTERESTING PART IS THE SECOND, and it is a shape this programme has now met three times at three different layers. SM435: the DESCRIPTOR claimed a capability that ENFORCEMENT refused. SM443: a SURFACE accepted a parameter the WRITE PATH ignored. Here: a GRANT permits an action the agent's HARNESS blocks. Each time, two things that should agree about what is allowed do not, and each time the honest reading is available only from whichever side has not been asked. What is different here, and worth stating plainly: the harness is RIGHT to be the strict side. A classifier that declines an action a grant would have permitted is failing safe, and it is not lazysite's business to widen. THE CONSEQUENCE IS EPISTEMIC RATHER THAN FUNCTIONAL: some findings can never be confirmed by that agent, so their absence from a field pass means NOTHING WAS TRIED, not that nothing was wrong. That distinction is the reason to write this down. It has already mattered once - SM443's destructive-default half went unverified on edge for exactly this reason, and the agent declined to route around the denial, which was the correct call. WHAT IS ASKED OF NOBODY: no change to lazysite, no change to the classifier, and no attempt by any agent to work around a denial. If a blocked verification is needed, it is run by someone whose permissions allow it, deliberately."
---

# The two denials

```datatable
columns: Attempted | Blocked by | Grant said
widths: 6cm | 5cm | X
bold: 1
tone: medium
---
Accessing files | Claude Code auto-mode classifier | (not reached)
Probing the control API for submissions actions | Claude Code auto-mode classifier | **`manage_forms` is on** - one of the two capabilities in the documented carve-out
```

::: widebox
The harness is the strict side, and that is correct. A classifier declining
something a grant would have allowed is failing safe. Nothing here asks for it
to be widened.
:::

# The shape, now met three times

```datatable
columns: Filing | These two disagreed about what is allowed
widths: 4cm | X
bold: 1
tone: medium
---
SM435 | the DESCRIPTOR claimed what ENFORCEMENT refused
SM443 | a SURFACE accepted a parameter the WRITE PATH ignored
SM456 | a GRANT permits what the agent's HARNESS blocks
```

Each time the honest answer was available only from the side nobody had asked.
The difference here is that the disagreement is between systems with different
owners, so there is nothing to reconcile - only something to record.

# Why it is worth writing down

**The absence of a confirmation is not a confirmation.** When a field pass does
not mention a finding, that can mean it was checked and held, or that it could
never have been checked at all. Those read identically in a report and mean
opposite things.

It has already mattered: SM443's destructive-default half - the one that
replaced a neighbouring site's navigation - went unverified on edge because the
classifier blocked the call. The agent did not route around it, and said so.
That was the right call and it is the reason this filing is a record rather
than a complaint.

# What is asked

Nothing of lazysite, and nothing of the classifier. Only that a verification
known to be blocked is either run by someone whose permissions allow it, or
recorded as unrun - never quietly omitted.
