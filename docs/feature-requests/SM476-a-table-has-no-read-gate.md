---
title: "SM476: a table has no read gate, so every declared table is public"
subtitle: "A page bound to a table inherits the page's gate. The endpoint is reached by its own URL and inherits nothing, so a table in a gated section is readable by anyone who knows its name"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-08-22. THE RELEASE MANAGER CHOSE: publication flag in the DESCRIPTOR (a property of the table), user/group lists in ACLS.JSON (a property of this site's people), default CLOSED. TWO CONTROLS THAT COMPOSE RATHER THAN COMPETE - `public:` decides whether an ANONYMOUS visitor sees rows, the acls.json read list decides which accounts and groups do, and the awkward case falls out rather than being special-cased: a published table carrying a read list refuses an anonymous visitor because an anonymous visitor matches no entry in a list and _acl_allows already answers false for that reason. Nothing had to know it was a special case, which is why t/unit/data/16 asserts it - the day somebody 'fixes' the composition, that is what tells them. THE ACL KEY IS THE DESCRIPTOR'S OWN PATH, lazysite/db/tables/<name>, and that is load-bearing rather than cosmetic: lookup is longest-prefix, so a rule on lazysite/db/tables governs every table at once and a site-wide private rule covers tables exactly as it covers pages - both inherited from the existing matcher with no table-shaped concept added to it, and no collision with content because lazysite/ never holds content. THE ENFORCEMENT IS STRUCTURAL, NOT REMEMBERED: read_rows now DIES without an `as` argument, so a caller cannot read rows without saying who is asking. The alternative was a may_read() each surface remembers to call first, and 'remembers to' is precisely how this went wrong - the endpoint was a second door built without the gate the first door had, and nothing in the signature asked. It dies rather than erroring because a missing `as` is a programming fault no visitor input can produce: loud in the suite, unreachable in the field. NO OPERATOR BYPASS ON A VISITOR SURFACE, deliberately - a page renders the same rows for an operator as for a visitor, which is what SM466 guarantees for layouts and themes and the only way a preview means anything. A REFUSED READ IS INDISTINGUISHABLE FROM AN ABSENT TABLE, same status and same wording, asserted by diffing the two responses. THE DEFAULT WAS CHOSEN WHILE IT WAS STILL FREE: the plugin has only ever shipped to edge, is born disabled, and the only tables in existence were three test tables on one site - my own filing wrongly warned about breaking an installed base that does not exist, and that window closes at stable. FOUND ON THE WAY: action_data_table_save reported migrate_required => 1 HARDCODED, so every descriptor save demanded a migration whether or not the stored table already matched. Publishing a table is a descriptor save that changes no field, which is what made it visible. Now derived from plan_migration - the database is the state, per D2. EIGHT SABOTAGES, one of which reported a no-op (the descriptor normalises public to 0/1, so a `// 1` default change nothing) and was re-run where the default actually lives."
---

# What is true today

`lazysite-data.pl` answers `GET ?table=<name>` for **any** declared table, to
**any** caller, signed in or not. The endpoint verifies the session cookie and
puts the verified account in the environment, and then nothing reads it: no
module in `lib/Lazysite/Data/` contains the string `acl`, and the descriptor
has no key that could express a restriction.

A `db:` binding on a page is gated, because the PAGE is gated - the ACL runs
before the processor renders anything. That is what makes the gap easy to miss:
an operator who puts a table behind a gated page has tested the page and seen
it refuse, and the table is still one URL away.

```datatable
columns: Surface | Who may read a table's rows
widths: 7cm | X
bold: 1
tone: medium
---
`db:` page variable | whoever may read the PAGE - the section ACL decides
Manager UI / control API | an account holding `manage_data`
MCP `read_data_rows` | a partner holding `manage_data`
`lazysite-data.pl?table=x` | **anyone at all**
```

# Why it is not simply a bug

Some tables should be public - a price list a page renders through JavaScript
is the case DP-3 exists to serve, and requiring a login for it would defeat the
feature. So the answer is a declared intent, and the question is which way the
default points.

```datatable
columns: Option | What it costs
widths: 6cm | X
bold: 1
tone: medium
---
`readable_by` defaulting to PUBLIC | matches today's behaviour, so nothing breaks on upgrade - and every table an operator has already declared stays exposed, including any declared before this filing was read
`readable_by` defaulting to SIGNED-IN | safe by default, and breaks DP-3's headline use on upgrade for every site already using it
Explicit `public: true` required | safest, breaks the most, and is the only option where an operator cannot expose a table by omission
```

The second and third are upgrade-breaking in a way SM471 has already shown is
hard to see: a site that stops working after an upgrade because a new key
defaults closed reports as "the data plugin broke", not as "a gate was added".

# What was built

```datatable
columns: Control | Where it lives | What it decides
widths: 3.6cm | 4.4cm | X
bold: 1
tone: medium
---
`public:` | the descriptor | may an ANONYMOUS visitor see rows -- default **false**
read list | `acls.json`, key `lazysite/db/tables/<name>` | which accounts and groups may, in a file ACL's shape
```

Permissions stay out of the descriptor for a reason: a package carrying
`read: [@staff]` into another site where `staff` means different people is a
privilege accident. `public` is a property of the table and travels with it;
the names are a property of this site's people and do not.

# The default, and why it was free to choose

The filing originally warned that a closed default breaks sites on upgrade, in
the way SM471 showed is hard to see. **That was wrong, and checking cost one
command.** The data plugin has only ever shipped to edge, it is born disabled,
and the only tables in existence were three test tables on one site. There was
no installed base to break, so the safe default cost nothing -- and that
remains true only until this reaches stable.

# Found on the way

`action_data_table_save` returned `migrate_required => 1` **hardcoded**. Every
descriptor save therefore demanded a migration, whether or not the stored table
already matched. It stayed invisible while every save changed a field;
publishing a table is a descriptor save that changes no field at all, which is
what surfaced it. An operator told to run a destructive-change confirmation in
order to change a privacy setting is an operator who stops reading the
confirmation. Now derived from `plan_migration`, per D2: the database is the
state.
