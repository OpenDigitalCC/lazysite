---
title: "SM465: an acl-set is audited without saying what the rule became"
subtitle: "The audit trail records that a permission changed, who changed it and on what path - and not what it changed to. So the one question an audit of a permission change exists to answer is the one it cannot."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED (PENDING). An acl-set now records the rule in the audit entry's detail field: both sides when there was a prior rule ('read: alice -> read: alice, bob'), and 'new -> ...' for a first grant so an operator can tell a first grant from a widening. ONE LINE, READABLE BY A PERSON, because the trail is read rather than parsed. AN EMPTY LIST IS RECORDED AS '(unrestricted)' rather than omitted - SM462: an empty write list means NO restriction, so recording it as absent would make the trail disagree with enforcement about the most misread rule in the system. A REFUSED acl-set still records its reason, which is what an attempted escalation looks like. ORIGINAL FILING FOLLOWS. DECIDED 2026-08-22 by the release manager: record BEFORE AND AFTER, with the account and group names IN the entry. The caveat was raised and accepted - account names will land in the audit log, which may carry different retention from the account store, and that is a deliberate trade for a trail that answers 'who could reach what, and when'. The alternatives considered and rejected: after-state only (cannot show what a rule stopped being, which is the interval an audit asks about) and shape-without-names (no personal data, and an auditor still cannot tell whether the right people were named). FILED 2026-08-21 from the field, alongside SM464. THE GAP: an acl-set is logged as an event with actor, path and action, and the rule CONTENT is absent - no before, no after, no principals, no read/write split. An auditor reading the trail can see that somebody changed the permissions on /intranet at 14:02 and cannot see whether that opened it to everyone or closed it to one person. WHY IT MATTERS MORE THAN AN ORDINARY OMISSION: a permission change is the one operation whose EFFECT cannot be recovered from the current state plus the log. For content, the version history holds what changed. For a rule, the store holds only the latest value, so a rule set and re-set leaves no trace of what it was in between - and the interesting case for an audit is precisely the interval. RELATED AND SEPARATE: SM464 is about an administrator being unable to READ a rule they did not set; this is about the trail not recording a rule that WAS set. They meet in the same place - an operator who wants to know who could reach what, and when - but the fixes are different: SM464 is an access question, this is a completeness question. TWO THINGS TO DECIDE, both the release manager's: whether the logged rule is the full entry or a diff, and whether the principals are named in the log at all - naming them is what makes it useful and also what puts account names into a file with different retention from the store. SUGGESTED SHAPE, not a decision: log the after-state, and the before-state when the path already had a rule, both as the stored JSON. It is small, it needs no schema, and it is the form least likely to drift from what enforcement actually reads."
---

# What the trail answers today

```datatable
columns: Question | Answered
widths: 7cm | X
bold: 1
tone: medium
---
Did the permissions on this path change? | yes
Who changed them? | yes
When? | yes
**What did they become?** | **no**
What were they before? | no
```

# Why the current state is not a substitute

For content, a page's history holds every version, so a log entry that names
the page is enough -- the content is recoverable. A rule is not versioned. The
store holds one value, the latest, so the rule that was in force between two
changes exists nowhere once the second change lands.

That is the interval an audit asks about.
