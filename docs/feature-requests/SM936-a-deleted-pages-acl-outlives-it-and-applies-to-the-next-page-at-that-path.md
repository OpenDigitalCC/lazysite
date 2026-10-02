---
id: SM936
title: "SM936: a deleted page's ACL outlives it and applies to the next page at that path"
subtitle: "Draft a page, delete the page, write a different page at the same path: it is born draft and 404s, and nothing on any surface says why. The rule is still in the store, keyed on a path whose content is gone. It failed safe here; the same mechanism grants a read just as quietly."
brand: plain
standard-margins: true
status: candidate
raised: 2026-09-30
raised-by: sites agent, measured on dhcf.eu (0.14.4) across four steps in one session
area: access control
status-note: "NOT YET RULED. The reporter measured it end to end: PUT a page, `acl-set` with `{\"draft\":true}`, DELETE the page (204, no mention of the rule), later PUT a DIFFERENT page at the same path (201 Created), GET it anonymously - 404. No `acl-set` was made for the new page and nothing in the create or the 404 named a rule; `acl-get` was the only surface that knew, and `acl-remove` cleared it. THE ARGUMENT THAT MAKES THIS WORTH BUILDING RATHER THAN KNOWING is the reporter's own: it failed safe on this occasion and THE DIRECTION OF THE ACCIDENT IS NOT A PROPERTY OF THE MECHANISM - a rule carrying `read: [\"@some-group\"]`, deleted and later reused for unrelated content, gives that group a read nobody granted, and gives it silently, because the new author never saw the rule either. Two fixes are proposed and the first is small: a content delete takes the path's rule with it or SAYS it has not; and a create at a path carrying a rule reports the rule in its reply (`acl_in_force`), which turns a hunt into a sentence. ALSO TO CHECK, named by the reporter and not yet measured: whether the same is true of `data-table-acl-set` on a table that is dropped and recreated, and of `rename_page` / `move_file`, which change a page's path and therefore which rule applies to it."
---

# Measured, in four steps

On dhcf.eu, 0.14.4, in this order:

1. `PUT /videos/marcello-leucci.md`, then `acl-set` with `{"draft":true}`.
2. `DELETE /videos/marcello-leucci.md` - the page was withdrawn on the owner's
   instruction. **204, with no mention of the rule.**
3. Later, a **different** page was written at the same path, deliberately public so
   its subject could be sent the URL. `PUT` returned **201 Created**.
4. `GET https://dhcf.eu/videos/marcello-leucci` returned **404**.

`acl-get` answered immediately:

    {"path":"videos/marcello-leucci",
     "acl":{"owner":"sjm-claude-code","draft":true}}

`acl-remove` cleared it and the page served 200.

**Grade: measured on a live site (A)**, four steps in one session, with the page
rendering from the same generator as six working siblings.

# Why it is worth fixing rather than knowing

**The rule survived the thing it was about.** An ACL on a content path is a statement
about that content. When the content is deleted the statement has no subject, and it
waits in the store to be inherited by whatever arrives next at the same spelling.

**Nothing spoke.** Not the delete, not the create, not the 404. A new page that 404s
reads as a content or layout fault, and that is where the time goes.

**It failed safe here by luck, not by design.** Over-restriction is the better
direction and on this occasion it withheld a page rather than exposing one. The same
mechanism runs the other way, and that is the part that makes this access control
rather than ergonomics.

# What should change

| Ref | Change |
| --- | --- |
| AO1 | A content delete **takes the path's ACL with it**, or its reply names the rule it has left behind - so the next author of that path has been told once |
| AO2 | A create at a path carrying a rule **reports the rule**: one field, `acl_in_force`, in the `PUT`/create reply |
| AO3 | Measure the same question for `data-table-acl-set` on a dropped-and-recreated table |
| AO4 | Measure the same question for `rename_page` and `move_file`, which move a page between rules |

AO1 is the honest default because the rule described content that no longer exists.
If there is a reason to keep it - a section rule about to be repopulated - then the
delete must say so, which is AO1's second half rather than an alternative to it.

# Related

[[SM306]] (`acl-set` refusing to take the whole site private by omission - the same
function, the same care about a rule applying where nobody meant it), [[SM937]] (the
same surface, reporting a rule's effect wrongly), [[feedback_absence_is_a_finding]].
