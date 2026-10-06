---
id: SM936
title: "SM936: a deleted page's ACL outlives it and applies to the next page at that path"
subtitle: "Draft a page, delete the page, write a different page at the same path: it is born draft and 404s, and nothing on any surface says why. The rule is still in the store, keyed on a path whose content is gone. It failed safe here; the same mechanism grants a read just as quietly."
brand: plain
standard-margins: true
status: shipped
raised: 2026-09-30
raised-by: sites agent, measured on dhcf.eu (0.14.4) across four steps in one session
area: access control
status-note: "SHIPPED in 0.15.2 (afe87085, tag v0.15.2 on d0ddee56). NOT YET RULED. The reporter measured it end to end: PUT a page, `acl-set` with `{\"draft\":true}`, DELETE the page (204, no mention of the rule), later PUT a DIFFERENT page at the same path (201 Created), GET it anonymously - 404. No `acl-set` was made for the new page and nothing in the create or the 404 named a rule; `acl-get` was the only surface that knew, and `acl-remove` cleared it. THE ARGUMENT THAT MAKES THIS WORTH BUILDING RATHER THAN KNOWING is the reporter's own: it failed safe on this occasion and THE DIRECTION OF THE ACCIDENT IS NOT A PROPERTY OF THE MECHANISM - a rule carrying `read: [\"@some-group\"]`, deleted and later reused for unrelated content, gives that group a read nobody granted, and gives it silently, because the new author never saw the rule either. Two fixes are proposed and the first is small: a content delete takes the path's rule with it or SAYS it has not; and a create at a path carrying a rule reports the rule in its reply (`acl_in_force`), which turns a hunt into a sentence. ALSO TO CHECK, named by the reporter and not yet measured: whether the same is true of `data-table-acl-set` on a table that is dropped and recreated, and of `rename_page` / `move_file`, which change a page's path and therefore which rule applies to it."
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

# MEASURED AND BUILT 2026-10-02 (afe87085): three answers, not one

The four steps were run against this tree before anything was built, because the
filing was measured at 0.14.4 and never claimed to reproduce here. It gave three
different answers, so a single "SM936 is fixed" would have been wrong three ways.

| Ref | Measured here | Done |
| --- | --- | --- |
| AO1 | **Does NOT reproduce.** `action_delete` takes the rule with the content (CF-2, whose comment tells this story) and a new page at the path answers `open` | Pinned by test, not re-fixed |
| AO4 | **Already correct.** A move re-keys the rule - old key empty, new key carrying the same read list | Pinned by test |
| AO3 | **REPRODUCES, in the grant direction.** `drop_table` never touched the ACL store. Set `read: ["@volunteers"]`, drop, recreate as somebody else: the new table answers `read=@volunteers`, owner `sjm-claude-code` | **BUILT** |
| AO2 | **Still silent, and the case is real** - but it is DESIGN, not a leak: an ancestor rule governs a page created under it. A page written into a folder carrying a read rule answers `gated`, and the save reply carried four fields and no explanation | **BUILT** |

## AO3, which is the part that mattered

The fix is in `Lazysite::Data::Tables::drop_table`, not in the manager action,
for the reason CF-2 states about pages: a fix in one caller is a fix one surface
wide, and that function is what every surface routes through. It calls
`Data::Access::acl_key` by name rather than spelling the key shape a second time,
and failure to forget is logged rather than fatal - the rows and the descriptor
are already gone, so refusing would report a failed drop that had happened. The
reply carries `acl_forgotten`, because silently doing the right thing leaves an
operator unable to tell this version from the one that did not.

## AO2, narrowed by what AO1 turned out to be

With the delete leak closed, the only way a page is born gated is a rule set
deliberately on an ancestor. So the notice is not a leak report; it is the
sentence that turns a hunt into a fact. It names the KEY, because the page has no
rule of its own and "there is a rule somewhere above you" is the unhelpful half.
On a create only - a save over an existing page is not the moment of surprise,
and a field on every write is one an agent learns to skip.

Getting the key needed the resolver to answer which key won, not just which rule.
The scope precedence (exact, stem, longest ancestor, site-wide last) is not
trivial, so the walk was split to return both rather than walked twice -
`t/lint/36` then caught the rename, having been anchored on the old name with its
ordering assertions matching a four-line wrapper.

## Two rig faults worth recording, because both looked like findings

**"The defect reproduces" was my rig.** `Manager::Files` takes `validate_path`
from `Manager::Common`, which keeps its OWN `$DOCROOT`. Setting the two a nearby
test sets left `validate_path` resolving against undef, the delete refused a path
it had never looked at, and the rule was of course still there afterwards. I had
written that down as the defect reproducing before noticing the refusal.

**`gating_for` called with one argument answers `unknown` for everything.** Its
signature is `($docroot, $rel)`; passing just the path makes `$rel` undef and the
answer a flat `unknown`, which looks exactly like "the engine cannot tell". The
new `governing_key` takes the same shape deliberately, so the two halves of one
question cannot be called two different ways.

## Sabotage, seven cases

| Sabotage | Subtest that fails |
| --- | --- |
| a dropped table keeps its rule | `AO3: a dropped table takes its rule with it` |
| the drop stops saying it removed one | same |
| a deleted page keeps its rule (CF-2 undone) | `AO1: a deleted page takes its rule with it` |
| a move drops the rule instead of re-keying | `AO4: a move takes the rule WITH the content` |
| the create notice fires on every write | `AO2: a page born gated ... says so` |
| the create notice fires whether or not anything gates | same |
| `governing_key` answers the page key, not the ancestor | same |

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
