---
id: SM857
title: "SM857: a signed-in visitor cannot be shown, or confined to, their own rows - there is no server-written filter anywhere"
subtitle: "The release manager's question: most systems scope a user to their own records with a select - `where email = my email`. The difference here is WHO WRITES THE SELECT. A page binding cannot name the viewer (deliberately), and the data endpoint takes the row key FROM the caller, so no filter in this engine is written by the server. One primitive - the engine substituting the caller's identity, never the request - covers reads and writes at once."
brand: plain
standard-margins: true
status: partial
status-note: "THE WRITE HALF SHIPPED 2026-09-28, exactly as ruled. `row_policy: true` gives each row an explicit disposition - personal, shared, or absent meaning shared - set by whatever creates the row at the moment of writing, and a personal row is amended and deleted by the account in created_by or by an operator. Measured before: two accounts holding write_data on one table, and Bob rewrote Ann's row and then deleted it; delete_row's signature had nowhere to say who was asking, and it has one now. THE ANTI-CAPTURE ASYMMETRY IS ENFORCED: naming the policy on a row you did not create is refused whatever that row's current policy is, so a shared row cannot be taken private by a writer; that needs manage_data, as recommended, and no new capability was minted. An empty created_by is NOT MINE rather than unknown, which is the deliberate reading this filing asked for. update_row and delete_row now REQUIRE `as` and die without it, as read_rows has since SM476 - there is one caller, so a default would have been a third state in a write gate. t/lint/153 refuses a surface that asks which table a caller may write without also asking whose row, which is SM682 round 2's defect on the same two surfaces. OF THE FIVE OPEN QUESTIONS: 2 is answered (row_policy needs timestamps, refused by name at descriptor load, because an ownership test with no owner admits everybody); 5 is answered (lazysite-check reports per table how many rows carry no policy, with DBI as a soft dependency so "could not count" is a different answer from "none"); 1 and 3 belong to the READ half and are untouched - reads are still per table, a page renders the same rows for everybody, and `(mine)` needs the per-viewer cache treatment. 4 SHIPPED 2026-09-29: a table handler takes row_policy: personal and each row it writes belongs to the account that submitted it, so the expo case works end to end - measured before and after, and before it was row_policy=NULL on every row with bob able to amend ann's application on a table declaring row_policy: true. Refused at SAVE when the table declares no policy column, and the VALUE is checked against Data::Owned's vocabulary rather than a second copy of it. THE CASE WORTH NAMING: personal with no signed-in submitter is a public form, so created_by is empty and the row belongs to NOBODY - safe (more locked down, not less) and almost certainly not what was asked for, so the row is still stored and the delivery note says so. Refusing it would lose a submission over a configuration the visitor cannot see. t/unit/forms/26, three sabotages - one of which escaped first time because Data::Value normalises an empty policy to NULL, so the test had to reach a table with NO policy column to see the difference. RULED 2026-09-29: THE HANDLER POLICY IS NEXT, ahead of the read half. The reasoning is the filing's own - open question 4 is "the piece the expo actually depends on", because a handler writing applications creates SHARED rows unless it says otherwise, so the safe case is the one that takes extra work. It is also the small one: a conf key on the table handler declaring the policy its rows carry, using the column that already exists, with no cache decision attached. `(mine)` waits, and its cost is unchanged - per-viewer rows cannot be cached for everyone, which is why rendering has been viewer-independent until now. ORIGINAL RULING, 2026-09-12: , and deliberately NOT in 0.13.14. A row carries an explicit policy column - `personal` or `shared` - set by whatever creates the row, at write time; absent means shared, so existing data needs no migration and nothing is inferred from an empty `created_by`. Amending your own row's policy rides on `write_data`; amending anyone's needs `manage_data` (recommended over a new capability), which is the rule that stops a writer capturing a shared row. Handover is filed as reassignment, a third state, rather than pressed out of `shared`. UNBLOCKED 2026-09-28: the blocker was [[SM860]] - ownership tested against a field that is NULL wherever an app's own users wrote - and SM860 WENT OUT with the 0.14 line (98b659cf), so the data endpoint now stamps the verified session's account and an anonymous write still records nobody. One consequence survives the unblocking and belongs to whoever builds this: rows written BEFORE SM860 carry an empty `created_by`, and an empty `created_by` already means 'written anonymously by a public form', so an ownership test must read empty as NOT MINE rather than as unknown. That agrees with the ruling above - absent policy means shared - and it means no migration is needed, but it has to be the deliberate reading rather than a discovered one."
raised: 2026-09-12
raised-by: release manager (from the expo use case)
area: data
---

# The question, as it was asked

> "is the difference between now and then, that the security weakness is a
> select? because most systems don't have the owner owning the row, the select
> limits to their record - `select where email = 'my email'`. i guess we have
> this today. but having access only to the row i wrote is welcome stronger
> position."

The reading of how other systems work is right. The last sentence is the
conclusion this filing agrees with, and "we have this today" is the part that is
not so - in either direction, read or write.

# What exists today, read from the source and the shipped docs

**Reads.** A page binding filters, orders, counts or takes one field, on any
declared field, by LITERAL values, AND-combined (`db:applications(status=open,
limit=20)`). Read access is gated PER TABLE by the same lists files use - a
username or `@group` in the ACL store at `lazysite/db/tables/<name>`, with the
longest-matching-prefix rule, composing with `public: true`.

And then the sentence that settles it, from `/docs/data-tables`:

> A **page** is never treated as an operator - it renders the same rows for
> whoever is looking at it, so what you see while signed in is what your
> visitors see.

**Writes.** A write needs a signed-in session, `manage_data` or `write_data`, and
membership of a group in the table's `writable_by` if it names any. `write_data`
is documented as "the grant for an app's own users - a learner writing their own
submissions, a member updating their own record".

**But the grant is per TABLE, not per row**, and the row is named by the caller:
`lazysite-data.pl` passes `$req->{key}` through to the row save. So ten
applicants holding `write_data` on one applications table may each edit the
other nine's rows, including anything commercially sensitive in them.

**What is trustworthy.** With `timestamps: true` the extension stamps
`created_by` and `updated_by` from the session and REFUSES them from any writer.
That is the one field in a row a caller cannot forge, and it is what makes this
filing cheap.

# Why "scope it with a select" is not available, and should not be

In a conventional application the select is written by server code the user
cannot reach: `where email = session.email`. The user supplies no part of it.

In this engine there is no such place:

- **A page binding cannot name the viewer.** `db:` values pass through
  `strip_tt_directives()` and are never passed through `interpolate_env`, so
  `db:applications(email=[% auth_user %])` resolves to a literal that matches
  nothing. That refusal is deliberate and is the same one that keeps a visitor
  from steering a query through the URL ([[SM856]] states it).
- **The data endpoint's filter comes from the caller.** A caller-supplied filter
  is not a control: whatever narrowing it expresses, the caller can express
  something else.

So adding "scope by select" would mean introducing a caller-controlled filter
and then trying to constrain it - which is the weaker design, and the one that
fails by omission the first time an author forgets the constraint.

# The primitive that is missing

**The engine substitutes the caller's identity into the filter. The request never
supplies it.** One concept, two verbs:

Reads
: `db:applications(mine)` - the engine adds `created_by = <the session's
  account>`. No new grammar beyond the word, nothing for an author to get wrong,
  and no value a visitor can influence.

Writes
: insert, update and delete confined to rows whose `created_by` is the caller.
  The caller still names the key; the engine refuses a key it does not own.

Both rest on the same unforgeable stamp, which is why this is a small feature
rather than an access-control redesign.

# The design, as ruled 2026-09-12

The release manager's amendment, which replaces the descriptor-level
`rows: own` this filing first proposed. It is a better design and the reason is
worth stating: **a row's disposition is set by whatever creates the row, at the
moment of writing, and is a field of its own.**

> "i dont propose null means shared, shared would be explicitely shared, and
> rows with no field get created as shared. the time to set policy is at write,
> so whatever is creating the row gets to say the policy. amend could be db cap
> - update my row policy, update any row policy."

## A row carries a policy, and the policy is explicit

Its own column, never inferred:

| Policy | Who may write the row |
| --- | --- |
| `personal` | the account in `created_by`, and an operator |
| `shared` | anyone the table already admits (`write_data` + `writable_by`) |

**Absent means shared**, in both directions: a row written before this exists
carries no policy field and reads as shared, and a writer that names no policy
creates a shared row. So existing data keeps working unchanged and no migration
has to guess.

**What must NOT happen is inferring the policy from `created_by`.** An empty
`created_by` already means "written anonymously by a public form" - and, until
[[SM860]] lands, it also means "written by a signed-in account whose identity the
data endpoint dropped". Reading shared out of that absence would give one
representation three meanings and let a bug decide an access outcome. The policy
column is separate and set on purpose; that is the whole point of it.

## Amending a policy is a capability, not a special case

Two rights, which answers "who may take a shared row private" without ad-hoc
logic:

- **my own row's policy** - carried by `write_data`, alongside writing the row
- **any row's policy** - a stronger grant

**Recommendation: the stronger right is `manage_data`, not a new capability.**
`manage_data` already means "configure this table" and is already the operator
grant on every data surface. A new capability has to be added to the capability
map, the permissions grid, `describe-capabilities`, both channel gates and the
docs - real cost, for a distinction `manage_data` already draws. If a middle
tier is wanted later it can be minted then, against evidence.

The asymmetry is deliberate and is the anti-capture rule: **a writer may give
their own row away, never take someone else's.** Narrowing a shared row to
personal is an amendment to a row you do not own, so it needs the stronger
right.

## Handover is reassignment, and it is not "shared"

A row moving between people - intake to assessor - is not the same as a row open
to everybody. Using `shared` for handover would leave every row that ever passed
through two hands permanently writable by all, which is looser than the position
this filing exists to reach. The precise verb changes the OWNER, and the accounts
side already has both the shape and the name (`account-reassign`). Filed here as
the third state rather than built, so `shared` is not pressed into doing it.

# Still open

**1. What does `(mine)` do for an anonymous viewer?** No rows, and the page
should be gated anyway. It must not fall back to "all rows" - that is the
failure mode this whole filing is about.

**2. What if the table has no `created_by`?** `timestamps: true` is what
supplies it. A `personal` row is untestable without it, so a table declaring
policies needs timestamps, and `(mine)` on a table without them is an author
error refused by name at render and logged as such - never silently empty.

**3. The page cache.** Per-viewer rows cannot be cached for everyone. The
mechanism already exists - a gated page bypasses the cache - so `(mine)`
must imply the same treatment. This is the reason the feature is not free, and
the reason page rendering has been viewer-independent until now.

**4. The consequence of a permissive default, which needs naming somewhere the
author reads.** "Absent means shared" is right for compatibility and wrong for
the expo case: a form handler writing applications creates SHARED rows unless it
says otherwise, so every applicant could amend every other application - the
exact outcome this filing was raised to prevent. **A handler that writes rows
needs to be able to declare the policy it writes them with**, or the safe case
is the one that takes extra work. That is a second piece of work, and it is the
piece the expo actually depends on.

**5. Existing rows are shared, so confinement protects nothing that already
exists** - only rows written after it ships. Correct, and invisible: someone will
assume otherwise. `lazysite check` should report, per table, how many rows carry
no policy.

# What this unblocks

The expo case directly: an applicant signs in and sees, and maintains, their own
application and nobody else's. It generalises exactly as the site agent's filing
said - a client updating a support case, a supplier keeping compliance details
current, a member amending a booking.

# What to do in the meantime

A per-applicant page with the code written into the binding as a LITERAL
(`db:applications(code=ODX-0001)`) shows one applicant their own row today, with
no engine change, because their unguessable URL is the scoping. That is the
workaround the expo can ship with; it does not generalise past a handful of
pages, which is why this filing exists.

# Related

[[SM856]] (the refusal this must not undo: a visitor may not steer a query),
[[SM682]] (`write_data`, the grant this confines), [[SM673]] (the account that
does the signing in), SM647 (`allowed_groups`, the same question for reads at
table level), [[SM852]] (where a gated write lands - the other half of "whose
row is this").
