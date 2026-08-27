---
title: "SM224 - Analysis: reconcile the two access-control models before documenting either"
subtitle: "lazysite has a per-file ACL for the authoring channels and a per-page auth level for the public read path. They share no vocabulary and no enforcement point. Decide whether they should merge, before writing documentation that cements the split."
brand: plain
status: shipped
status-note: "ANALYSIS DELIVERED 2026-08-08 as docs/architecture/access-control-model.md - truth table, four findings, an argued recommendation (keep separate, make legible), a position on static files that resolves SM223 decision 4, and a naming recommendation. No code changed. ANALYSIS ACTIVITY, not a build. Raised 2026-08-06. Deliberately blocks the documentation work in SM229/SM230's family: documenting the current split would make it permanent, and an experienced reviewer has already drawn a wrong and privacy-relevant conclusion from it. Output is a recommendation plus a truth table, not code."
---

# SM224 - reconciling the two access-control models

## Why this is an analysis and not a feature

lazysite answers "who may read this?" twice, with two mechanisms that do not
know about each other:

| | Per-file ACL | Page auth level |
|---|---|---|
| Set by | `set_permissions` / `action_acl_set` | `auth:` + `groups:` front matter, `auth_default:` |
| Stored in | `lazysite/auth/acls.json` | the page's own front matter, and `lazysite.conf` |
| Enforced by | `Lazysite::Auth::Acl`, loaded by the manager API, MCP, WebDAV, `Manager::Files`, `Manager::Upload` | `check_auth` in `lazysite-processor.pl` |
| Governs | the four authenticated authoring channels | the anonymous public read path |
| Subject vocabulary | owner, users, `@groups` | authentication level, `groups:` |
| Covers static files | no | no (see SM223) |

Both are correct in isolation. Together they produce a platform where "the
permissions on this file" and "who can see this page" are unrelated facts with
similar names, and where neither is authoritative over the other.

The obvious next step is to document the split. That step should not be taken
yet, because documenting a distinction is the act that makes it permanent, and
there is evidence the distinction is itself the problem.

## The evidence that prompted this

In August 2026 an experienced external reviewer, working from
`describe_capabilities` and the MCP tool surface, reasoned as follows about
where to keep private material:

> `set_permissions` gives owner plus per-user and per-group read and write
> lists, which is the right model. But I do not know whether that ACL gates the
> anonymous HTTP read path or only the four authoring channels, and the
> difference decides everything. If content ACLs are an authoring construct,
> then a named CMO's answer would be one URL guess away from being public. That
> is the only outcome in this project that is genuinely unacceptable.

The reviewer identified the right risk, asked the right question, and could not
answer it from anything the platform told them. They are not a novice, and they
had read everything the tool surface offered.

Two observations follow. First, the naming actively misleads: a thing called
"permissions", set by a tool called `set_permissions`, that does not affect who
can read the file over HTTP, is a reasonable thing to misunderstand. Second, the
mechanism that *does* answer their question - `auth:` front matter - was
invisible to them, because it lives in content rather than in the permissions
surface where they were looking.

## What the analysis must produce

### 1. A truth table

For each combination of subject, channel and object, what is the current answer
and which mechanism gives it.

- Subjects: anonymous visitor; authenticated site user; user in a group; token
  partner (WebDAV / MCP / control API); operator.
- Channels: anonymous HTTP; WebDAV; MCP; control API; manager UI.
- Objects: a page with `auth: none`; a page with `auth: required`; a page with
  `groups:`; a file with an ACL; a file with both; a static file; an
  engine-owned path.

The table is the deliverable, not a step towards one. Nobody can currently
produce it from documentation, which is itself the finding.

### 2. An answer to whether the models should merge

Three candidate positions, to be argued rather than assumed:

**Merge.** One ACL governs every channel including anonymous reads, with
"anonymous" as a subject. Conceptually clean and matches what the reviewer
expected. The cost is real: the render cache is keyed by path and host, and a
per-file ACL consulted on every anonymous read is a hot-path cost that ADR 0001
(the render path loads no Lazysite modules) exists specifically to avoid. This
option probably cannot be taken without revisiting ADR 0001, which is a large
decision and should be named as one.

**Keep separate, and make the separation legible.** Rename so the two stop
colliding, cross-reference each in the other's tool description, and have
`get_permissions` report the page's public-visibility state alongside the ACL so
one call answers the whole question. Cheap, and it removes the misunderstanding
without the hot-path cost. It leaves two models in the product forever.

**Separate with one authority.** Keep both mechanisms, but make one derive from
the other - for example, the ACL becomes the single place an operator expresses
intent, and the page auth level is generated from it at write time. Combines the
single vocabulary of merging with the hot-path characteristics of the current
design. Most work of the three, and the migration story for existing sites needs
thought.

### 3. A position on where static files sit

SM223 asks for static files to come under access control and lists options. The
answer here determines which of those options is coherent: if the models merge,
a static file's ACL is the natural answer; if they stay separate, a prefix rule
is. SM223 should not be built before this question is settled, and its fourth
open decision says so.

### 4. A recommendation on naming

Whatever the structural answer, `set_permissions` returning something that does
not govern who can read the file over HTTP is a naming problem with a
demonstrated cost. The analysis should recommend either a rename, or a response
field that states the scope in the response itself.

## What must not happen before this concludes

- No documentation page describing "the two access-control models". Writing it
  is a decision to keep both.
- No new surface that consults one and not the other.
- No build of SM223 beyond the `auth_default` case, which is unambiguous
  regardless of the outcome.

## Effort and shape

A reading and reasoning exercise across `Lazysite::Auth::Acl`, `check_auth` in
the processor, the four channel entry points, and ADR 0001. Estimated at one to
two days, output being a document in `docs/architecture/` plus the truth table,
plus a recommendation that feeds SM223 and unblocks the documentation work.

No code changes are expected from this activity. If it produces a preferred
structural direction, that becomes its own numbered request.
