---
title: "SM464: an administrator cannot audit a permission they did not set"
subtitle: "acl-get refuses on ownership, and ownership beats capability. So the person responsible for an estate's access control is the one person who cannot read most of it."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.28, answering the question the filing asked, in the shape its own remedy sketch proposed: READING a rule is split from MODIFYING one. may_read_any_rule() - an operator, a cookie-session holder of manage_users (both already true via _is_operator), or a TOKEN whose OWN grant carries manage_users - gates acl-get; acl-set stays owner-only for everyone, so ownership still means what it meant. The token override keys on the grant the operator wrote for THAT partner, never on the account's group memberships, keeping SM127's manager-groups-off-remote-channels intact; the measured refusals were all token-surface refusals, because _is_operator refuses every token by design - a cookie-session admin could already read. STALE HALF: the asymmetry note - SM465 has since added before/after rule content to the acl-set audit entry, so the trail half was already closed. ORIGINAL NOTE: FILED 2026-08-21 at the release manager's direction, as a QUESTION rather than a defect - they elected to leave the behaviour unchanged for this beta and record the reasoning. MEASURED from the field: acl-get on a section owned by another user returns 'Not the owner of this file' even for a member of lazysite-admins. Ownership is checked before capability and there is no capability that overrides it. WHY IT MIGHT BE RIGHT: ownership being absolute is a simple rule, it is the same answer on every surface, and it fails in the safe direction - a capability that could read every rule is a capability worth stealing. Nothing here is enforcing the wrong thing. WHY IT IS WORTH A DECISION ANYWAY: the person accountable for an estate's access control is precisely the person who did not set most of its rules. An administrator asking 'who can read /intranet?' is doing the job the audit trail exists to support, and is refused. The workarounds are worse than the question - take ownership (which CHANGES the rule you were trying to inspect), or read the ACL store off disk (which bypasses the check entirely and leaves no trace). A refusal that is routinely worked around by going under it is not really enforcing anything. NOTE THE ASYMMETRY WITH THE AUDIT TRAIL: acl-set is recorded without the rule's CONTENT - who, when, from where, and that it succeeded, but not what the rule became. So neither the live check nor the trail can answer 'what does this rule say', and the two gaps compound: an administrator cannot read the rule now, and cannot reconstruct it from history either. SHAPE OF A REMEDY, if one is wanted: let manage_users or an operator READ any rule while still refusing to MODIFY one they do not own. That splits the two acts rather than widening one, and read-only is the half an auditor needs. Not proposed for this beta."
---

# What happens

```datatable
columns: Caller | acl-get on a rule they own | on somebody else's
widths: 6cm | 5cm | X
bold: 1
tone: medium
---
The owner | the rule | -
A `lazysite-admins` member | the rule | **"Not the owner of this file"**
An operator | the rule | **"Not the owner of this file"**
```

::: widebox
Ownership is checked before capability, and no capability overrides it. The
person accountable for an estate's access control is the one person who cannot
read most of it.
:::

# Why it might be right

Absolute ownership is a simple rule, it gives the same answer on every surface,
and it fails in the safe direction: a capability that could read every rule on
a site is a capability worth stealing. Nothing here enforces the wrong thing,
which is why this is filed as a question and not a defect.

# Why it still deserves a decision

An administrator asking *who can read /intranet?* is doing the job the audit
trail exists to support, and is refused.

The available workarounds are worse than the question:

- **Take ownership** - which CHANGES the rule you were trying to inspect.
- **Read the ACL store off disk** - which bypasses the check entirely and
  leaves no trace.

A refusal that is routinely worked around by going under it is not really
enforcing anything; it is just making the honest route the slow one.

# The asymmetry that compounds it

`acl-set` is audited **without the rule's content** - who, when, from where,
and that it succeeded, but not what the rule became.

So an administrator can neither read the rule now nor reconstruct it from
history. Either gap alone is arguable; together they mean an access-control
decision can be made and afterwards be unreadable by the person responsible
for it.

# Shape of a remedy, if one is wanted

Let `manage_users` or an operator **READ** any rule, while still refusing to
**MODIFY** one they do not own. That splits the two acts rather than widening
one, and read-only is the half an auditor actually needs.

Not proposed for this beta - the release manager has elected to leave the
behaviour and record the reasoning.
