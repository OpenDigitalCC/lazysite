---
title: "SM576: briefs get their own capability, housekeeping goes lateral, and roles are built from groups"
subtitle: "The operator's answer to SM575: who may delete another agent's brief is a GRANT question, not an ownership question - and the group machinery already tested here is what should answer it."
brand: plain
standard-margins: true
status: candidate
status-note: "SPLIT BY THE OPERATOR 2026-08-25 for the 0.10.33 cut: THIS FILING IS NOW PARTS 1 AND 3 ONLY - manage_briefs (a plugin-declared capability on the manage_data pattern) and ROLES FROM GROUPS (one assignable flag per group, so an unflagged group is a backend group that only aggregates). Part 2, the LATERAL HOUSEKEEPING SPLIT, moves to SM591, because its tiers depend on SM587's undecided rule (does destructive mean the object cannot be recovered, or the effect cannot be undone?) and the rest should not wait on that decision. ORIGINAL DECISION BELOW. DECIDED BY THE OPERATOR 2026-08-25, answering SM575's question (should one partner agent be able to delete another's brief?). The answer is neither 'add ownership' nor 'leave it': make the RIGHT separately grantable. Three parts, each reusing machinery that already exists and is tested. (1) manage_briefs - a capability for creating and editing briefs, declared by plugins/briefs.pl exactly as manage_data is declared by the data plugin (ADR 0009: static in @CAP_KEYS, discovered by t/lint/76), so briefs stop riding manage_content. (2) LATERAL capabilities - deletion and housekeeping cut ACROSS modules, and in practice one person is assigned to manage laterally while others are delegated function access; so the destructive/tidying verbs across stores (brief-delete, data-safety-export-delete, backup-delete, artifact-backups-delete, cache and registry sweeps, retention) answer a lateral grant rather than each module's own capability. (3) ROLES FROM GROUPS - group-of-group nesting already exists and is ALREADY ENFORCED through the closure (effective_groups, the same resolver the permissions grid and capability_holders use); add one flag per group marking it ASSIGNABLE to users, so an unflagged group is a backend group that exists only to aggregate other groups and capabilities. End-user roles are then composed from backend groups instead of hand-listed capabilities. VERIFIED BEFORE FILING: nesting exists and is enforced; @CAP_KEYS is static with channels and capabilities together; group settings carry a label and capability flags and no assignable flag today; briefs sit under manage_content on both the API and MCP. PLANNED for 0.10.33 or later - this is a design, nothing is built."
---

# What this answers

SM575 measured that briefs enforce no per-principal ownership: one agent
read, appended to and permanently deleted another agent's brief. Two
readings were available - follow content (no ownership) or follow themes
(creator-owned). The operator's answer is a third: **the right to delete
is a grant, not a property of the object**. An agent that should not
delete another's brief is an agent that should not hold the lateral
housekeeping grant.

# The three parts

## 1. `manage_briefs`, declared by the plugin

Briefs are a plugin feature riding `manage_content`. `manage_data` shows
the tested shape for this: declared by the plugin, mirrored statically in
`@CAP_KEYS` because `caps_for` is on every request path, and kept honest
by `t/lint/76`, which discovers plugin declarations and fails when the
two disagree.

Consequence to decide when built: a site that has always granted
`manage_content` must not silently lose brief access, so the migration
is either "grant `manage_briefs` wherever `manage_content` is held" at
upgrade, or `manage_content` continues to imply brief READS with
`manage_briefs` required to write. The second is smaller and reversible.

## 2. Housekeeping is lateral

Deletion and tidying are the same job wherever they happen, and they are
the operations an operator most often reserves to one person: clearing
safety exports, removing backups and artefact backups, deleting briefs,
purging caches and registries, applying retention. Today each answers its
own module capability, so granting someone the ability to *use* a module
grants them the ability to *destroy* inside it.

A lateral capability separates the two: module capabilities carry the
working verbs, the lateral grant carries the destructive ones across all
modules. It also composes - a lateral grant sits in a backend group with
the module capabilities a housekeeper needs.

Open for design: whether one lateral capability or two (a reversible
`housekeeping` and an irreversible `purge`), and whether an object's own
creator keeps the right regardless (themes and ACLs behave that way now).

## 3. Roles are composed from groups

Nesting already works and is already enforced; what is missing is the
distinction between a group meant to be **assigned to a person** and a
group that exists only to **aggregate**. One flag per group settles it:

- **assignable** - offered when giving a user a role (e.g. *Site editor*,
  *Housekeeper*, *Publishing partner*).
- unflagged - a backend group (e.g. *content-write*, *data-read*,
  *lateral-housekeeping*) that appears only when composing other groups.

The manager's Users page then offers roles rather than a capability
grid, and the grid stays where it belongs - on the backend groups. This
directly addresses SM564's finding that `agent-ai`/`mcp-ai` drifted as
capabilities were added around them: a role built from backend groups
inherits new capabilities by composition, or visibly does not.

# Why this shape

Every part reuses something already load-bearing: the plugin-declared
capability (ADR 0009 + lint 76), the nesting closure (already the
enforcement path), and the group settings record (gains one boolean).
Nothing new is invented to be tested from scratch.

# The concentration this creates, and what follows from it

Raised by the site agent, recorded as a design constraint rather than an
objection. Today the ability to destroy is **scattered**: a themes grant
drops a theme, a data grant drops a table, and neither reaches the other.
Afterwards one grant reaches brief-delete, data-safety-export-delete,
backup-delete, artefact backups, cache and registry sweeps and retention,
**across every store at once**. That concentration is the point - it is
what makes destruction reviewable - and it also means a mis-scoped
lateral grant is worth more than any other mistake on the estate. SM573
exists because grants *do* get mis-scoped by accident: a partner brief
stated seven capabilities where the account held seventeen.

Three things follow, none of them expensive:

- **The lateral grant is the first capability row swept**, not one of the
  last. Every other grant tested so far can damage one store; this one
  can damage all of them.
- **It is the strongest case for SM573's generated capability block.** A
  brief that understates by ten capabilities is bad; a brief that
  silently omits *and may delete anything anywhere* is a different order
  of bad.
- **It must be visible in the role that carries it.** Composition through
  backend groups is the feature, but a role whose total includes the
  lateral grant should say so where the role is assigned - the same
  turn-remember-into-ask move as `list_briefs` and the `mutating` flag.

## The two open questions, with proposed answers

Both proposed by the site agent from today's field use; the operator
decides.

**Is the irreversible half a second capability? Proposed: yes, split on
an objective test - does the engine retain a copy?** That replaces a
judgement call per action with a rule:

| Class | Actions | Why |
|---|---|---|
| self-healing | cache-invalidate, registry sweeps | rebuild on the next request |
| recoverable | data-table-drop | mints a safety export of every row |
| irreversible | brief-delete, data-safety-export-delete, backup-delete | no copy survives |

`backup-delete` has not been tested cross-principal and belongs in the
same question - and SM577 makes it the sharpest case in the irreversible
tier: a backup store is INSTANCE-wide (verified from the code), so
deleting a backup is not scoped by the site whose grant authorised it.

**Measured on edge, 2026-08-25, after this filing was written.** A
principal holding `manage_data` AND NOTHING ELSE, acting on a table
created by another principal, ran the whole sequence: listed it, read its
rows and descriptor, wrote a row, deleted a row, retitled the table and
dropped a field, dropped the table (`rows_dropped: 3` - recoverable, the
reply named the safety export), and then deleted that export. One
capability, no ownership check, another principal's table destroyed and
the copy that made it recoverable destroyed four seconds later. The
engine's recoverability was removed by the same grant in the next call.

The case that settles it is `data-safety-export-delete`: a drop is
recoverable **only because** the export exists, so deleting the export is
what makes the earlier drop permanent. An agent that may drop tables and
an agent that may delete their safety exports are doing categorically
different things, and one lateral grant would hand both to the same
principal by definition. The copy test puts them on opposite sides
without anyone arguing the case. It also composes with SM572: the
`mutating` flag already separates reports from writers, and this is one
more level of the same classification - writer / recoverable /
irreversible - derived once rather than restated.

**Is the irreversible half a second capability? DECIDED BY THE OPERATOR
2026-08-25: YES.** The copy test below is how an action is assigned to a
tier.

**Should `lazysite-check` report effective holders? DECIDED BY THE
OPERATOR 2026-08-25: NO.** Their principle: keep CLI concerns in the CLI
and operator concerns in the UI, because once a site is in operation
everything should be manageable through the manager. So the roster of who
can destroy across every store belongs on the Groups/Users pages, beside
where roles are assigned - not in a check-tool report an operator has to
run. The same principle applies to SM564's group-reach work: the command
built for it is the engine, and the operator's view of it is a manager
page. What follows below was the proposal that led to that decision, kept
for its reasoning about reports and warnings.

**The proposal that was put (superseded on placement, not on content):** Some accounts should hold the lateral grant, so
a check that flags them cries wolf by design - and a warning that fires
on a correct configuration is dismissed, then dismissed on the day it
means something. The value is the roster: *these three accounts can
destroy across every store*, as a standing line. The finding is not that
someone holds it; it is that the roster is longer than the operator
expected, which only they can judge - the same shape as the group review.
One refinement that is load-bearing: report **effective** holders
resolved through the group closure, not accounts with the grant directly
attached. SM573's seven-vs-seventeen was invisible precisely because the
capabilities arrived through membership; a report of direct grants would
have shown that account as clean.

# Proving tests

- `manage_briefs`: a token holding `manage_content` alone is refused
  `brief-append`; holding `manage_briefs` it succeeds; `t/lint/76` fails
  if the plugin's declaration and `@CAP_KEYS` disagree.
- Lateral: a grant holding `manage_briefs` but not the lateral capability
  is refused `brief-delete` and permitted `brief-append`; the same grant
  shape across `data-safety-export-delete` and `backup-delete`.
- The split: `data-table-drop` succeeds for a grant holding the
  recoverable tier and `data-safety-export-delete` is refused it - the
  copy test, asserted as behaviour rather than as a list.
- The roster: an account holding the lateral grant only THROUGH a nested
  group appears in `lazysite-check`'s report; an account with no such
  path does not.
- Concentration: a role composed of backend groups, one of which carries
  the lateral grant, reports the lateral grant in the role's own summary -
  the total is readable without resolving the closure by hand.
- Assignable: a backend group cannot be assigned directly to a user; a
  user in an assignable group composed of two backend groups holds the
  union, resolved through the existing closure (assert against
  `effective_groups`, not against direct membership).
