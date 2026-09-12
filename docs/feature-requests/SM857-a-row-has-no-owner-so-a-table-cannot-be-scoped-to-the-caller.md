---
id: SM857
title: "SM857: a signed-in visitor cannot be shown, or confined to, their own rows - there is no server-written filter anywhere"
subtitle: "The release manager's question: most systems scope a user to their own records with a select - `where email = my email`. The difference here is WHO WRITES THE SELECT. A page binding cannot name the viewer (deliberately), and the data endpoint takes the row key FROM the caller, so no filter in this engine is written by the server. One primitive - the engine substituting the caller's identity, never the request - covers reads and writes at once."
brand: plain
standard-margins: true
status: candidate
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

# What has to be decided before it is built

**1. Is the write confinement implicit in `write_data`, or a declared key?**

| | For | Against |
| --- | --- | --- |
| Implicit (`write_data` always means own rows) | least privilege by default; nothing to forget | silently narrows a grant on any live site using `write_data` as a table-wide grant for staff |
| Declared (`rows: own` in the descriptor) | existing apps unaffected; the intent is visible in the file | an author can forget it, and the default stays the weaker one |

**Recommended: declared, plus `lazysite check` naming every table that grants
`write_data` without it.** Pre-stable the project prefers breaking compatibility
over keeping legacy paths, but a silent narrowing here would break a live app's
staff screen with no error to read - the check warning gets the visibility
without the breakage.

**2. What does `(mine)` do for an anonymous viewer?** No rows, and the page
should be gated anyway. It must not fall back to "all rows" - that is the
failure mode this whole filing is about.

**3. What if the table has no `created_by`?** `timestamps: true` is what
supplies it. Without it, `(mine)` is an author error and should be refused by
name at render, logged as such, not silently empty.

**4. The page cache.** Per-viewer rows cannot be cached for everyone. The
mechanism already exists - a gated page bypasses the cache - so `(mine)`
must imply the same treatment. This is the reason the feature is not free, and
the reason page rendering has been viewer-independent until now.

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
