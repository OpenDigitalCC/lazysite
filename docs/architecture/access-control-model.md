---
title: "Access control: the two models, and how they relate"
subtitle: "SM224 analysis. Who may read or write what, on which channel, decided by which mechanism - and what should change."
brand: plain
---

# Access control: the two models

## Why this document exists

lazysite answers "who may read or write this?" with two mechanisms that do not
know about each other. An experienced reviewer, reasoning from the tool surface,
could not determine which one governed the public read path - and drew a
conclusion with privacy consequences. This is the analysis SM224 asked for:
what is actually true, whether the two should merge, and what to do next.

## The two mechanisms

Per-file ACL
: `lazysite/auth/acls.json`, set by `set_permissions` / `acl-set`, enforced by
`Lazysite::Auth::Acl::_acl_allows`. Owner plus per-mode allow-lists of users and
`@groups`.

Page auth level
: `auth:` and `groups:` in a page's front matter, with `auth_default` in
`lazysite.conf` as the fallback, enforced by `check_auth` in
`lazysite-processor.pl`.

They share no code, no vocabulary and no storage.

## Truth table

Rows are the object; columns are the channel. **ACL** = the per-file ACL decides;
**auth:** = the page auth level decides; **-** = neither consults anything.

**CORRECTED 2026-08-12.** The table below described the state before SM223. That
filing is recorded as shipped at the foot of this document, but the correction
was appended there and never made here - so the single cell this section calls
out as most important said the opposite of the behaviour for three releases,
in the one table a reader consults to answer the question. The rows are now
current; the superseded reading is kept underneath, because this document's
purpose is to show what was weighed.

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

Since SM223 the processor carries a **module-free copy** of the read decision
(`_acl_allows_read`; ADR 0001 forbids it loading `Lazysite::Auth::Acl`), and
`t/lint/31` pins the copy against the shared implementation so the two cannot
drift into meaning different things.

Two properties of that path are load-bearing and easy to lose:

- **The public path never applies the operator bypass.** `_is_operator` treats
  every cookie client as an operator on a site where no group grants manager
  access, so consulting it anonymously would make the whole feature inert on
  exactly the least-secured sites. `t/lint/31` asserts the processor does not
  call `_acl_denied`.
- **No ACL store means no change.** A site that has never protected anything
  serves statics exactly as before, which is what made SM223 safe to ship to
  every existing site.

What has NOT changed, and still surprises people: `auth_default: required`
governs **pages** and does not reach static files. A site can declare itself
private and still publish its PDFs - deliberately, because making it
retrospective would have started refusing assets on every site that upgraded.

Since [[SM287]] there is a way to say it: an ACL entry on `/` governs every path,
pages and assets alike. That is the mechanism for a wholly-private site, and it
is opt-in, so nothing changes for a site that does not write one.

> **Superseded reading, kept deliberately (pre-SM223):** *"The single most
> important cell is the one an operator would never guess: a per-file ACL has no
> effect on what an anonymous visitor can read. The processor never loads
> `Lazysite::Auth::Acl`."* True when written, and the finding that prompted
> SM223.

### Subject-level behaviour

### The scope grammar

An ACL key names what it governs. Resolution order is **most specific first**,
and only entries carrying a non-empty list for the mode in question take part -
an owner-only entry is no rule, not a tighter one.

| Scope | Key | Beats |
|---|---|---|
| One file | `content/report.pdf` | everything |
| A section's landing page | `private` also governs `private.md` | the folder rules above it |
| A folder, at any depth | `private` covers `private/...` | shorter prefixes, and the site |
| **The whole site** | `/` | nothing - it is the **weakest**, so a carve-out under it still wins |

The site-wide rule is what makes "everything private except the front door"
expressible. `''`, `'.'` and `'./'` are read as `/` too, since a hand-edited
store is a real interface here; the writer only ever stores `/`. **Wildcards are
refused** - the store has no matching language, so accepting `*` would imply
one.

Before SM287 the root was the one scope that could not be expressed at all: an
entry there was inert under every spelling, so a wholly-private site had to
enumerate its top-level folders - a workaround that **fails open as content
grows**, because a file added at the root next month is public.

| Subject | ACL treatment |
|---|---|
| No entry, or no list for that mode | **allowed** - protection is opt-in, and an owner-only entry is not a read restriction |
| Owner of the file | always allowed |
| User named in the mode's list | allowed (exact username) |
| Member of an `@group` in the list | allowed **only if the channel carries groups**. Matching is case-insensitive and expands **nested** groups (`group_closure`), so membership can be indirect |
| Operator (cookie, `manage_users`) | bypasses the ACL entirely - **on the authoring surfaces only, never on the anonymous read path** |
| `local` user | always operator |
| Any user, on an unsecured site | operator (no group grants manager access) - which is why the public path must not consult it |
| **Any partner (token / MCP / WebDAV)** | **never an operator.** Whether its groups apply depends on the CHANNEL - see below |

### Whose groups apply, by channel - one answer since SM288

A group is a property of the **account**, not of the door it arrived through.
Every channel resolves the same way.

| Channel | Where `@user_groups` comes from | Does `@group` match a partner? |
|---|---|---|
| **WebDAV** | `Acl::groups_for_user` | **yes** |
| **MCP** | `Acl::groups_for_user` | **yes** |
| **Control API (token)** | `Acl::groups_for_user` | **yes** |
| Manager (cookie) | `HTTP_X_REMOTE_GROUPS`, set by the auth wrapper from the validated session | yes |

`Acl::groups_for_user` delegates to `Settings::effective_groups` - the same
resolver the capability and domain-access checks already use, so *"which groups
is this account in"* has **one** implementation for every question lazysite
asks, and membership expands over nested groups everywhere. `t/lint/35` pins
each channel to it; `t/integration/44` drives the same question on WebDAV and
MCP and asserts they agree.

The cookie path keeps the header deliberately: for a browser session the auth
wrapper sets it from the validated session, and that is the trusted path the
manager is built on.

> **How it was before SM288, and why it matters.** WebDAV parsed the group file
> itself, MCP hard-set the list to `()` with a comment calling it "the safe
> default", and the control API read a header a token client cannot send. So the
> same account, in the same group, reading the same file under the same ACL, was
> **allowed over WebDAV and refused over MCP** - for about a year, through the
> analysis below, an adversarial security review, and a feature built on top of
> it. Nothing failed and no test noticed, because each channel was only ever
> tested against itself. An operator found it by reading a summary and saying
> "partners do have groups". That is the recurring theme SM268 named - two
> surfaces disagreeing about one question - and the reason `t/lint/35` exists is
> to catch the fourth channel somebody adds.

**Note for token clients:** the control API has no action that reads a file's
content, so a partner can set an ACL there and must use MCP or WebDAV to
exercise it. See [[SM289]].

### The two policies

An entry is not just an allow-list; it carries a policy, and the two differ in
what an anonymous request gets **and in what an empty list means**.

| Policy | Anonymous request | Empty read list means |
|---|---|---|
| **Gated** (default) | 302 to the login page, `Cache-Control: no-store` | no restriction - the entry does not govern |
| **Draft** (`draft: true`) | **404**, and absent from the sitemap, feeds and search | **nobody**: an anonymous request is refused even with no list |

The draft asymmetry is deliberate. A draft section with no read list would
otherwise be public, which is the opposite of what "draft" means to the person
who set it.

## Four findings

### 1. The ACL is invisible on the path people assume it governs

Named `set_permissions`, stored as `acls.json`, and inert for anonymous reads.
The naming is the defect: a reasonable reader concludes that setting read
permissions on a file restricts who can read it over HTTP. It does not.

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

### Finding what this already governs

Extending `read` to the public path means an entry written to keep other
*editors* out of a file now also keeps anonymous visitors out of it. That is
usually what was wanted. Where it is not, these find it.

**Which files carry a read restriction today** - run on the site's docroot:

```bash
jq -r 'to_entries[] | select(.value.read != null and (.value.read | length) > 0)
       | "\(.key)\t\(.value.read | join(","))"' lazysite/auth/acls.json
```

Every path listed is now refused to anyone outside its list, on the public path
as well as in the manager. Anything in that output the site intends to be public
needs its `read` list cleared.

**Which paths have actually been refused** - the access log carries `"ar":1` on a
request turned away by an access decision, which no status code can express (the
anonymous refusal is a 302 to the login page):

```bash
grep -h '"ar":1' lazysite/logs/access-*.jsonl | jq -r .p | sort | uniq -c | sort -rn
```

The same data is available without shell access as `auth_refused` in
`analyse_visitors`, and is documented for agents in the stats briefing.

### ACL keys are docroot-relative, not URL-relative

This is the mistake worth naming, because the wrong version looks exactly like
the right one until somebody tries the URL.

A key is the path from the **docroot**. On a content-rooted domain the URLs are
relative to that domain's `content_root`, so the two differ:

| Domain | URL | ACL key that governs it |
|---|---|---|
| primary (no content root) | `/private/notes.pdf` | `private` |
| `alias.example` with `content_root: sites/foo` | `/private/notes.pdf` | `sites/foo/private` |

Write `private` on the second and nothing is protected. The rule is syntactically
valid, appears in the store, and governs a path that does not exist. Multi-domain
operators think in URLs - SM181's own example rule is the URL segment `upcoming` -
so this is the shape the mistake takes.

Keys written by the manager, MCP and WebDAV are already docroot-relative and
consistent. The exposure is confined to the hand-written folder rules SM181 asks
for.

**Finding it:** `audit_site` returns `acl_keys_matching_nothing` - every key that
matches no file or folder, with the content-root-prefixed key to use instead
where one would match. A rule that governs nothing is the classic symptom, so
check it after writing a folder rule and before believing a section is closed:

```bash
jq -r 'keys[]' lazysite/auth/acls.json | while read -r k; do
    [ -e "$k" ] || echo "governs nothing: $k"
done
```

## Recommendation on naming

`set_permissions` is the wrong name for something that governs four authoring
channels and not the public one. A rename is a compatibility event and the tool
is in wide use; the cheaper and nearly-as-effective fix is a **scope statement in
the response**, in the same style SM226 added to the capability map. If a rename
is ever taken, `set_authoring_access` says what it does.

## What this unblocks

- **SM223** shipped, with static files on the **ACL** side - see the section
  above, which records that this document recommended the other answer.
- The MCP batch proceeds, with finding 2 as a known trap for `set_permissions`
  and a candidate warning in SM243.
- The documentation work is unblocked, because the split is now a decision.
