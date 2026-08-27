---
title: "SM455: setting up an AI takes two pages, a manual refresh, and a choice nobody explained"
subtitle: "Add the account to a group on one page, refresh because nothing tells you to, go to another page for the connector, then pick which AI script applies. Every step is necessary and none of them is announced."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED (PENDING). THE PICKER IS SHOWN FIRST, before the account has a channel, and picking a client grants the group that provides one - because the client determines the channel (web/desktop speak MCP, a script speaks the API), which is what makes the operator's own suggestion work. SM100's connector card is unchanged and unreplaced; it is shown earlier and handed a grant step. THE SCOPE NOTE IS HONOURED AND TESTED: the confirmation names the account and the group, says what the group grants, says it is the same change as ticking the group on the Groups page, and goes through the SAME group-add action - so the audit entry is identical whichever page the operator used. A role group that does not exist on the site is REPORTED rather than substituted, because silently granting some other group that happens to carry the capability would be choosing a permission on the operator's behalf. The page updates its own view after the grant, which removes the stale-cache half of the complaint. ORIGINAL FILING FOLLOWS. REPORTED 2026-08-21 by the release manager, from doing it: 'to set an ai up, needs to be member of the group, then it doesnt refresh, so refresh needed, then selection of which AI script. this could all be more packaged - so user selects an AI, it sets group, shows just the right script, in one go.' WHAT IS ALREADY GOOD, and worth saying because the remedy is assembly rather than invention: SM076's connector card is a genuinely careful piece of work - two steps, client-neutral, a one-time connect code with regenerate, and it POLLS until the assistant authenticates so the operator is told when it worked rather than left guessing. Nothing here proposes replacing it. WHAT THE OPERATOR MEETS INSTEAD: the capability comes from GROUP MEMBERSHIP, set on the Groups page; the connector card lives on the Users page. Those are two pages with a stale cache between them - the Groups page updates its own view in place (refreshGroupMembers) and has no reason to know another page is open, so the Users page keeps whatever it loaded before the change. The operator therefore does something correct, sees no effect, and has to guess that a refresh is the answer. A page that silently disagrees with what you just did is indistinguishable from a page where what you did failed - the same shape as SM445, where a click did nothing and read as a broken feature. THEN THE THIRD STEP: which AI script. The card offers the generic instructions and the operator picks; it does not ask which assistant they are setting up and then show only that one. ASKED FOR: pick the assistant first, and let that one choice set the group, mint the code, and show only the relevant script - one flow, one page. SCOPE NOTE, and it is the reason this is not simply 'add a wizard': the group grant is a PERMISSION decision and must stay visible and auditable. Packaging must not turn 'give this agent write access to the site' into an implied side effect of a drop-down. The flow should SAY which group it is about to grant and why, and the audit entry should read the same as if it had been done on the Groups page. NOT PROPOSED: changing what the capabilities are, or who may grant them."
---

# The four steps, and which of them announce themselves

```datatable
columns: Step | Where | Announced?
widths: 6cm | 4cm | X
bold: 1
tone: medium
---
Add the account to the right group | Groups page | yes - it confirms
**Refresh the other page** | nowhere | **no**
Open the connector card | Users page | yes
Choose which AI's script applies | Users page | partly - all of them are shown
```

::: widebox
The second row is the one that costs the time. The operator does something
correct, sees no effect, and has to guess that a refresh is the remedy - and a
page that silently disagrees with what you just did is indistinguishable from
one where what you did failed. That is SM445's shape again: silence reads as
breakage.
:::

# What already works

SM076's connector card is careful: two steps, client-neutral, a single-use
connect code with a regenerate control, and it POLLS until the assistant
authenticates so the operator is told when it worked. The remedy here is
assembly, not invention - nothing proposes replacing it.

# What is asked for

Pick the assistant first. That one choice then:

1. grants the group membership the capability needs,
2. mints the connect code,
3. shows **only** that assistant's instructions.

One flow, on one page.

# The constraint that shapes it

The group grant is a **permission decision** and has to stay visible and
auditable. Packaging must not turn *give this agent write access to the site*
into an implied side effect of choosing "Claude" from a drop-down.

So the flow should name the group it is about to grant and why, before it does
it, and the audit entry should read the same as if it had been done on the
Groups page. A wizard that hides which permission it handed out would be worse
than the four steps it replaced, however much smoother it felt.

# Not proposed

Changing what the capabilities are, or who may grant them. This is about
presenting an existing decision once, in the place it is being made.
