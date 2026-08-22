---
title: "SM476: a table has no read gate, so every declared table is public"
subtitle: "A page bound to a table inherits the page's gate. The endpoint is reached by its own URL and inherits nothing, so a table in a gated section is readable by anyone who knows its name"
brand: plain
standard-margins: true
status: candidate
status-note: "FOUND BY READING MY OWN WRITE HALF, 2026-08-22, not by a field report - which is why it is filed rather than fixed in the same commit: the fix is a new descriptor key with a privacy default, and defaults are the release manager's call. The write half that prompted it DOES ship the missing enforcement of writable_by (declared since DP-1, validated, exported, named in the MCP tool's own documentation, and consumed by nothing until now). WHAT MAKES THIS DIFFERENT FROM AN ORDINARY MISSING FEATURE: two comments in lazysite-data.pl asserted the gate existed - the header said what a caller may see is decided by the same rules that decide what the page may show, and the 404 handler explained itself as preventing disclosure of which tables exist. Both were corrected in the same commit, because a comment claiming a protection is worse than no protection: it stops the next reader looking."
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

# What was done now

Nothing that changes who may read. Two false comments were corrected, the 404
wording was left as-is *because* it is what a read gate would need (so adding
one later changes no caller-visible string), and the limit is stated in the
endpoint header and in `starter/docs/data-tables.md` where an author decides
what to put in a table.

# What this needs from the release manager

Which default, above. It is the only open question; the implementation is one
descriptor key, one check beside the `writable_by` check that now exists, and
a line in the docs.
