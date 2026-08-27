---
title: "SM616: the backend-group warning spoke about the future, over a list of people already there"
subtitle: "Marking a group backend takes nothing away - the flag is enforced at group-add only. The page said \"people are not added to it directly\" directly above the people who are in it."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED in 0.11.0 (stable, 2026-08-26). ASKED BY THE OPERATOR 2026-08-26, and the question is the finding: if a group is marked backend after people are assigned to it, do they keep it, are they invisible, and does removing one mean re-enabling the flag, removing, then disabling again? ANSWERED FROM THE CODE, all three paths checked. They KEEP it - group_is_assignable is consulted at group-add and nowhere else, deliberately, and the comment there says why: the resolver answers what an account holds and must keep working for memberships that already exist, so a rule that retroactively revoked access would be a different filing and a far more dangerous one. They are NOT invisible - the CLI lists every group with its members and marks the backend ones, and the Groups page renders member pills for a backend group with their remove buttons. And removal is NOT gated: cmd_group_remove has no assignable check, on either surface. So no dance is needed. WHY THE OPERATOR CONCLUDED OTHERWISE, which is the part worth fixing: the page's warning read 'This is a backend group, so people are not added to it directly', displayed immediately above whoever is in it. The sentence is true about the future and silent about what the reader is looking at, so it reads as 'these should not be here' or 'these are not really members'. It now says how many people are already there, that they keep the group and everything it grants, that marking a group backend never takes access away, and that removing one needs no change to the setting. Counting PEOPLE, not the nested groups that belong in a backend group by design. THE BEHAVIOUR HAD NO TEST - it was stated in a comment and asserted nowhere, so nothing stopped a later change making the flag retroactive and stripping live grants on an upgrade. t/unit/users/34 now pins retention, refusal of new assignment, and removal with the flag still off. MY FIRST TEST OF THE PAGE WAS TOO WEAK and a sabotage proved it: it asserted the sentences existed in the SOURCE, and removing the branch that emits them still passed, because the strings survive as concatenation fragments whether or not anything renders them. The block is extracted and executed now - the difference between 'these words are in the file' and 'a reader sees them'."
---

# The three questions, answered from the three paths

| Question | Answer | Where |
|---|---|---|
| Do existing members keep it? | **yes** | `group_is_assignable` is consulted at `group-add` only |
| Are they invisible? | **no** | CLI lists them `[backend]`; the page renders pills |
| Must the flag be toggled to remove one? | **no** | `cmd_group_remove` has no check at all |

# What the page now says

Marking a group backend is a statement about what happens **next**. The
warning used to say only that, above a list of people it was silent about.
