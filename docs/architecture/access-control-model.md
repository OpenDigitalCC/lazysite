---
title: "Access control: who may see what"
subtitle: "The reference. Two mechanisms, which question each answers, and the grammar of both. The analysis that settled the design is the appendix."
brand: plain
standard-margins: true
---

# Access control

## How to use this document

The reference is everything up to the appendix, and it describes what the code
does today. **Every factual table in it is asserted against the source by
`t/lint/36`** - not as ceremony, but because this document has twice told a
reader the opposite of the behaviour and been believed both times (see *How this
document earned its lint*, below).

The appendix is the SM224 analysis of June 2026: why there are two mechanisms,
what was considered, and what was decided. It is history and reasoning, kept
because a later reader should be able to see what was weighed - but nobody
looking for *"how does this work"* should have to read an argument about what it
should have been.

## The two mechanisms

lazysite answers "who may see this?" two ways, and they answer **different
questions**. That is a decision, not an accident (appendix: *Should they
merge?*).

Per-path ACL - `lazysite/auth/acls.json`
: **Who may read or write a PATH** - a file, a folder, or the whole site.
  Written by the manager, `acl-set` and `set_permissions`; enforced by
  `Lazysite::Auth::Acl::_acl_allows` on the authoring channels and by a
  module-free copy in `lazysite-processor.pl` on the public read path (ADR 0001
  keeps the render path free of module loads; `t/lint/31` pins the two copies
  together).

Page auth level - `auth:` / `groups:` front matter, `auth_default` in `lazysite.conf`
: **Who may read a PAGE.** Enforced by `check_auth` in the processor.

They share no storage and no vocabulary. **`auth_default: required` governs
pages and does not reach static files** - so a site can declare itself private
and still publish its PDFs. To close a whole site, including its assets, use a
root ACL entry (below).

## The scope grammar

An ACL key names what it governs. Resolution is **most specific first**, and
only entries carrying a non-empty list for the mode in question take part - an
owner-only entry is *no* rule, not a tighter one.

| Scope | Key | Beaten by |
|---|---|---|
| One file | `content/report.pdf` | nothing |
| A section's landing page | `private` also governs `private.md` | an exact key |
| A folder, at any depth | `private` covers `private/...` | longer prefixes, exact keys |
| **The whole site** | `/` | **everything** - it is the weakest |

The site-wide rule is deliberately the weakest, so "everything private except
the front door" is expressible. `''`, `'.'` and `'./'` are read as `/` too,
since a hand-edited store is a real interface; the writer only ever stores `/`.
**Wildcards are refused** - the store has no matching language, so accepting
`*` would imply one.

### Keys are docroot-relative, not URL-relative

The mistake worth naming, because the wrong version looks exactly like the right
one until somebody tries the URL. A key is the path from the **docroot**; on a
content-rooted domain the URLs are relative to that domain's `content_root`.

| Domain | URL | ACL key that governs it |
|---|---|---|
| primary (no content root) | `/private/notes.pdf` | `private` |
| `alias.example` with `content_root: sites/foo` | `/private/notes.pdf` | `sites/foo/private` |

Write `private` on the second and nothing is protected: the rule is valid,
appears in the store, and governs a path that does not exist. Keys written by
the manager, MCP and WebDAV are already correct; the exposure is confined to
hand-written rules. `audit_site` returns `acl_keys_matching_nothing` for exactly
this.

## The subject grammar

| Subject | Treatment |
|---|---|
| No entry, or no list for that mode | **allowed** - protection is opt-in |
| Owner of the file | always allowed |
| User named in the mode's list | allowed (exact username) |
| Member of an `@group` in the list | allowed. Case-insensitive, and **nested groups expand**, so membership can be indirect |
| Operator (cookie, `manage_users`) | bypasses the ACL - **on the authoring surfaces only, never on the anonymous read path** |
| `local` user | always operator |
| Any user, on a site where no group grants manager access | operator - which is why the public path must not consult it |
| Partner (token / MCP / WebDAV) | never an operator; groups resolve from the account |

## The two policies

An entry carries a policy, and they differ in what an anonymous request gets
**and in what an empty list means**.

| Policy | Anonymous request | Empty read list means |
|---|---|---|
| **Gated** (default) | 302 to the login page, `Cache-Control: no-store` | no restriction - the entry does not govern |
| **Draft** (`draft: true`) | **404**, and absent from the sitemap, feeds and search | **nobody**: refused even with no list |

The draft asymmetry is deliberate: a draft section with no read list would
otherwise be public, which is the opposite of what the word means.

## Setting access, by surface

Four surfaces can write a rule, and they all call **one writer**
(`Lazysite::Manager::Files::action_acl_set`). A rule set from a shell is the same
object as one set from the panel, governed by the same checks and moved into the
private store by the same code. That is what makes a fourth surface a small
change rather than a fourth grammar.

| Surface | Set | Read | Remove |
|---|---|---|---|
| Manager UI | the folder card / the per-file editor | same | same |
| Control API | `acl-set` | `acl-get` | `acl-remove` |
| MCP | `set_permissions` | `get_permissions` | `set_permissions` with empty lists |
| CLI | `lazysite acl set` | `lazysite acl show` / `list` | `lazysite acl remove` |
| WebDAV | - | - | enforces only; a DELETE takes the entry with the file |

**The two API names are not being reconciled by renaming either.** `acl-set` and
`set_permissions` are the same operation, and one vocabulary would be tidier -
but both are in live use by partners on deployed sites, and a rename to settle a
naming preference would break working integrations for no behavioural gain. The
mapping is documented here instead, which is the part a reader actually needs.

**The CLI needs an actor.** There is no session behind a shell, so
`lazysite acl set` requires `--actor USER` and applies exactly the authority that
account has in the manager. Without that rule the CLI would be a way around every
check the other surfaces make. `--actor local` is the documented break-glass
operator identity, and is never a default.

## Whose groups apply, by channel

A group is a property of the **account**, not of the door it arrived through.

| Channel | Where the groups come from |
|---|---|
| **WebDAV** | `Acl::groups_for_user` |
| **MCP** | `Acl::groups_for_user` |
| **Control API (token)** | `Acl::groups_for_user` |
| Manager (cookie) | `HTTP_X_REMOTE_GROUPS`, set by the auth wrapper from the validated session |

`Acl::groups_for_user` delegates to `Settings::effective_groups` - the same
resolver the capability and domain-access checks use - so *"which groups is this
account in"* has one implementation for every question lazysite asks.

**Note for token clients:** the control API has no action that reads a file's
content, so a partner can set an ACL there and must use MCP or WebDAV to
exercise it ([[SM289]]).

## Truth table

Rows are the object, columns the channel. **ACL** = the per-path ACL decides;
**auth:** = the page auth level decides.

| Object | Anonymous HTTP | Manager (cookie) | Control API (token) | MCP | WebDAV |
|---|---|---|---|---|---|
| Page with `auth: none` | public | ACL | ACL | ACL | ACL |
| Page with `auth: required` | **auth:** (redirect) | ACL | ACL | ACL | ACL |
| Page with `groups:` | **auth:** (403) | ACL | ACL | ACL | ACL |
| File with an ACL entry | **ACL** | ACL | ACL | ACL | ACL |
| File with both | **auth:**, then ACL | ACL | ACL | ACL | ACL |
| **Static file** (no `.md`), site has an ACL store | **ACL** | ACL | ACL | ACL | ACL |
| **Static file**, site has NO ACL store | public | ACL | ACL | ACL | ACL |
| Engine-owned path | 404/refused | blocked | blocked | blocked | blocked |

**No ACL store means no change.** A site that has never protected anything
serves statics exactly as before, which is what made SM223 safe to ship to every
existing site.

## Where protected content is kept

Protecting content **moves it out of the document root**, into a private store
held beside it. The engine resolves both trees; nothing else does.

That is the answer to the pattern behind SM248, SM268 H17 and SM283 - all three
were security living in front-end configuration that lazysite ships as a
template, cannot test where it is installed, and on most deployments cannot even
see. If the bytes are not in a directory any front end serves, no front-end rule
is needed and none can be got wrong.

| What | Behaviour |
|---|---|
| A rule with a **read list**, or `draft` | content moves out of the document root |
| A rule naming only a **write list** | content stays public - it restricts editing, not reading |
| Removing the rule | content moves back |
| The **site-wide** `/` rule | moves nothing; enforced by the engine alone |
| A page's `.brief` notes | follow the page, both directions |
| A page's cached `.html` render | deleted on protection; the next render is written privately |

The store is named for the document root it shadows, so two sites under one
parent directory can never share one.

**A move that cannot complete leaves the content where it was and reports
failure.** A path lives in exactly one tree; a copy left in the document root is
the exposure the store removes, so the failure direction is always "not moved",
never "in both".

**A failed move does not refuse the rule.** The ACL is stored and the engine
honours it, so the site is no worse off than before the store existed - but the
response says so, because both outcomes look identical to the operator
otherwise.

### The site root is the exception

`/` cannot be expressed as a move: the document root would have to become its own
sibling store. A site-wide rule is enforced by the engine alone, and the manager
says so when one is set. **This is the one scope where a front end serving files
directly can still bypass the rule** - so a wholly-private site on an untrusted
front end should protect its folders as well.

### What a backup, a package and the history do with it

| Surface | Carries protected content? | Why |
|---|---|---|
| **Backup** | **Yes** | Local recovery. A backup that silently stopped covering protected sections would be discovered at restore time, which is the worst moment. |
| **Site package** | **No**, and reports the count | A package travels between organisations, and the ACL rules live under `lazysite/` and are never packaged - so the content would arrive with nothing governing it. |
| **Content history** | **No**, and says so | A history may be pushed to a remote, and `Git.pm`'s exclude list is a security boundary for exactly that reason. |

In every case the omission was already happening and completely silent, because
the store is outside the tree each of them walks. What each now does is **say
so** - a count in the package manifest, `versioned: false` plus a notice on the
history response.

## Checking it, rather than believing it

The front end decides whether a request reaches the engine at all, and three
incidents turned on that (SM248, SM268 H17, SM283). So the engine being right is
not the same as the visitor being refused:

```bash
lazysite check --docroot <docroot> --check-acl https://example.test
```

That gates a probe folder, fetches it anonymously under six file extensions,
compares each against a public control of the same type, and FAILs if any bytes
come back. Several extensions on purpose - SM283 leaked `.png`, `.pdf` and
`.txt` while gating `.dat`, so a one-extension probe reports a leaking site
healthy.

A plain `lazysite check` also reports whether a site-wide rule is in force,
which `@group` entries exist, and **FAILs if any protected file is also present
in the document root** - a path in both trees is served by the front end without
the engine being asked, which is SM283 for a single file. It reports rather than
repairs: which copy to keep is a content decision, not one a permissions tool
should take.

## How this document earned its lint

Twice this file stated the opposite of the behaviour and was believed:

- it said a per-file ACL had **no effect on an anonymous read**, and called that
  out as *"the single most important cell"*. SM223 had made it false three
  releases earlier; the correction was appended at the foot and the table was
  never touched;
- it said **no partner could match an `@group`**, which was true of MCP and
  false of WebDAV. That came from trusting a comment in `Lazysite::Auth::Acl`
  rather than the three assignments, and it survived the analysis below, an
  adversarial security review, and a feature built on top of it - about a year -
  until an operator said "partners do have groups".

Neither was a coding error. **Prose about code is unverified code**, and the
only difference from a broken function is that nothing fails when it is wrong.
So the factual tables above are asserted against the source. Judgement, history
and reasoning are deliberately *not* pinned - an editor must be able to improve
them without fighting a test.

# Appendix: how this was decided

The SM224 analysis, June 2026, with later corrections marked in place. It
explains **why** there are two mechanisms and what was weighed - the reference
above is what they now do.

## Why the analysis was commissioned

lazysite answered "who may read or write this?" with two mechanisms that did not
know about each other. An experienced reviewer, reasoning from the tool surface,
could not determine which one governed the public read path - and drew a
conclusion with privacy consequences.

## Four findings

### 1. The ACL is invisible on the path people assume it governs - FIXED

**Closed by [[SM223]], August 2026.** The ACL now governs the anonymous read
path; see the truth table in the reference.

> **As originally written:** *"Named `set_permissions`, stored as `acls.json`,
> and inert for anonymous reads. The naming is the defect: a reasonable reader
> concludes that setting read permissions on a file restricts who can read it
> over HTTP. It does not."*

The finding was right and the fix went the other way from its recommendation:
rather than rename the tool to admit the limit, the limit was removed. Which
also retires the rename proposed at the foot of this appendix - `set_permissions`
is a better name today than the criticism of it ([[SM289]]).

### 2. An `@group` ACL entry could not match a token partner - FIXED

**Closed by [[SM288]], 2026-08-12.** An `@group` entry now matches the same
account on every channel; see the resolution table above.

The finding went through two corrections, which is worth keeping because both
were the same mistake:

> **As originally written:** *"`lazysite-mcp.pl` sets `@user_groups = ()` with
> the comment 'token carries no groups - the safe default'. It means an ACL
> granting `@editors` write access grants it to cookie users in that group and
> silently to no token partner at all."*

That over-generalised from MCP to all partners - **WebDAV always resolved real
groups** - and the over-generalisation came from trusting the comment above the
variable rather than the three assignments. It was then repeated into this
document as a headline finding, where it survived long enough to be quoted back
at an operator as fact.

The lesson is not about groups. **A comment next to correct code outlives a
wrong line of code**, because nothing executes it and every reader trusts it.
The comment in `Lazysite::Auth::Acl` is now a table of what each channel sets,
which is a form a lint can check - and `t/lint/35` checks it.

### 3. Both mechanisms default open, by different routes

The ACL defaults to allow (no entry, or an empty list for that mode, means
allowed - "the account's scope governs"). Page auth defaults to
`auth_default`, normally `none`. Both are defensible; together they mean neither
mechanism is the one that "locks down" a site, and an operator has no single
place to ask whether something is protected.

### 4. Operator bypass exists in one model and not the other

An operator bypasses any ACL. An operator visiting a page whose `groups:` they
are not in gets a 403 like anyone else. Consistent with each mechanism's purpose
- authoring versus publication - and surprising if you think of them as one
system.

## Should they merge?

### Merge into one ACL governing every channel

Attractive: one vocabulary, and it matches what readers expect. **Not
recommended.** The anonymous read path is the hot path, and ADR 0001 exists
precisely to keep it free of module loads and JSON parsing. Consulting
`acls.json` per request would either violate that or require a compiled
cache with its own invalidation problem. The cost is real and the benefit is
mostly a naming benefit, which can be bought far more cheaply.

### Keep separate, make the separation legible

**Recommended.** Nothing about the current split is wrong; what is wrong is that
it is undiscoverable. Concretely:

- **`get_permissions` reports the page's public visibility alongside the ACL.**
  One call then answers the whole question. This is the highest-value change in
  this document and it is small.
- **Rename in the surface, not the storage.** `set_permissions` becomes
  explicitly about authoring access in its description; the response states that
  it does not affect anonymous reads and names `auth:` as the mechanism that
  does.
- **Say it once in the docs**, now that the split is settled rather than
  accidental.
- **Warn when an ACL is set with `@group` on a path a token partner is expected
  to reach** - or at minimum say so in the tool description (finding 2).

### Separate with one authority

Deriving one from the other - an ACL that generates the page's `auth:` at write
time. Elegant, and it makes the ACL the single place intent is expressed. It also
means an ACL edit rewrites content front matter, which couples two stores that
are currently independent and would surprise anyone editing a page by hand.
Worth revisiting only if the legibility work proves insufficient.

## Where static files sit

**This analysis recommended one answer and the operator chose the other. The
decision, 2026-08-09, is the ACL.** The recommendation below is kept because the
reasoning still has force and a later reader should be able to see what was
weighed - but it is not what was built.

The recommendation was: static files are a publication concern, so they belong
to the `auth:` side, prefix-scoped in `lazysite.conf`, with no ACL involvement.

What was decided instead: **`acls.json` governs static files, and folder scopes
are entries in that same store.** The operator's reason was that the ACL is
established and one place is clearer to understand than two that must be kept in
step - which is the argument this document itself makes about the two models. So
SM224's fourth question is answered by merging rather than by separating, and
`read` now means "who may read this at all" rather than "who may read this in the
authoring channels".

Two consequences worth stating here, because they are what a reader of this
document will next want to know:

- `auth_default` still does **not** reach a static file. A file with no ACL entry
  is served exactly as before, so protection is an explicit act and nothing
  changes on a site that has expressed nothing.
- the processor carries a module-free copy of the read decision (ADR 0001) and
  must use `_acl_allows` semantics, never `_acl_denied` - the latter routes
  through `_is_operator`, which returns true on a site where no group grants
  manager access, and would treat the anonymous public as an operator.
  `t/lint/31` pins both.

## Recommendation on naming - SUPERSEDED, do not act on it

> **As originally written:** *"`set_permissions` is the wrong name for something
> that governs four authoring channels and not the public one. A rename is a
> compatibility event and the tool is in wide use; the cheaper and
> nearly-as-effective fix is a scope statement in the response. If a rename is
> ever taken, `set_authoring_access` says what it does."*

**Its premise stopped being true.** SM223 put static files on the ACL side, so
the tool governs the public read path too - the name is more accurate today than
this criticism of it, and `set_authoring_access` would now be the wrong name.
Recorded as retired in [[SM289]] rather than left here as a suggestion a later
reader might act on.

## What this unblocks

- **SM223** shipped, with static files on the **ACL** side - see the section
  above, which records that this document recommended the other answer.
- The MCP batch proceeds, with finding 2 as a known trap for `set_permissions`
  and a candidate warning in SM243.
- The documentation work is unblocked, because the split is now a decision.
