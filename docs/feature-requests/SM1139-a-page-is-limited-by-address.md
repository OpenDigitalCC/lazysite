---
id: SM1139
title: "SM1139: a page, a file or a folder is limited by the address it is asked from"
subtitle: "Slice B of SM1134: pages name address lists in their front matter, access rules name them for a file or a folder, and the processor, WebDAV and the manager's file reads refuse an address the rule does not admit."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-17
raised-by: release manager, 2026-10-17 (SM1134)
area: auth
status-note: "SHIPPED on n635 (slice B of SM1134; builds on SM1138, the lists and the module that answers): lazysite-processor/acl.pm, lib/Lazysite/Auth/Acl.pm, lib/Lazysite/Auth/AddressAudit.pm, lib/Lazysite/Manager/Files.pm, starter/manager/files.md; t/integration/280, t/integration/281, t/unit/processor/140, t/unit/manager/360, t/lint/220."
---

# What happened

SM1134, ruled in full on 2026-10-17 ("1. yes, 2. yes. 3. yes. 4. yes. 5. yes.
6. yes."): "Feature request, to limit access by source IP. This would be list,
with accept block and deny block, and then pages or groups can have blocks
applied." SM1138 (slice A) built the lists and the one module that answers
`decide($address, allow => [...], deny => [...])`. Nothing used it. This slice
applies a list to a page, a file and a folder.

# What shipped

## Where a rule names lists

- **A page's front matter**: `addresses: [office]` (allow) and
  `addresses_deny: [blocked]`, in the flow or the `- name` block form, read by
  the one access-key reader (`_access_keys_read`, with its marked copy in
  `Lazysite::Validate`, pinned by t/lint/220). A list name is the store's
  (`[a-z0-9_-]`, up to 64); a value that cannot be read as that is an access key
  the gate cannot read, and the page is refused to everyone, as `auth_groups`
  is (SM980).
- **A per-file access rule** (`acls.json`, a file or a folder): the same two
  fields, `addresses` and `addresses_deny`.

## How the layers combine (the rule chosen, and why)

Every layer that names a list for a path is decided on its own by `decide`: the
address must be in one of THAT layer's allow lists and in none of its deny
lists. The layers are the page's front matter, the path's own rule, its page
stem's rule (a folder's rule covers the section's landing page), every
enclosing folder's rule, and the site-wide rule. **Every layer must admit**:
AND across layers, OR within one, and any deny wins.

So a page allowing `office` inside a folder allowing `office` and `vpn` is
served to the office only; and a folder inside a folder narrows what its parent
allows. This is not the longest-match rule the read lists use: a read rule says
who may read and an inner rule may re-state it, but an address rule is a
limit, and letting an inner rule replace an outer one would let a folder be
opened to the world by a rule written inside it.

## Where it is enforced

- **The processor**, for every page and static it serves: pages, source-less
  statics (`_serve_content_static`), legacy static HTML, and `.url` pages. All
  go through `_acl_refused`, which now asks the address first.
- **WebDAV** (`lazysite-dav.pl`, `authorise`): GET, PUT, DELETE, COPY, MOVE and
  the rest, for a file under a rule in `acls.json`.
- **The manager API, MCP and the file functions they share**
  (`Lazysite::Auth::Acl::_acl_denied`): reads and writes.

The visitor's address is `client_address()` (via `trusted_proxies`, never the
`X-Forwarded-For` header read directly). An operator is not exempt from a rule
on a file; a caller with no web request (the users tool, a script) has no
visitor address and is not limited.

**Front matter lists bind where the page is served.** A page's own
`addresses:` is enforced by the processor, which reads the front matter. The
manager's and WebDAV's file reads decide from `acls.json` alone, as they do for
`auth:` and `auth_groups:`; a page limited only by its front matter can still
be fetched as a file by an account that holds the file and reaches the manager
or WebDAV. Put the rule in `acls.json` (`acl-set`) to cover every door.

## Order against the existing checks

The address is asked **first**, before the who-may-read rule, and both must
allow: an address rule only narrows, so passing it hands the request to the
existing checks. It comes first because it needs no identity (an address
outside the rule is refused rather than sent to a sign-in that could not
admit it), and because nothing a page declares about itself (`auth: none`) may
lift it, as a section gate is not overridable by the page (SM181). The way in
(`/login`, logout, the engine's assets) is never gated by it (SM651).

## The refusal

HTTP 403 with the ruled sentence, "This page is not available from your
address.", on the site's own refusal page (the SM201 system-page fallback
chain: `403.md` in the content root, then the shipped one). The shipped
`403.md` has a branch for it; a site's own copy that lacks the branch gets the
sentence inserted after its first heading, so a stale copy never tells a
refused visitor to sign in. The list is not named. A refusal inside a draft
section is a 404, as every other refusal there is (SM181). On the manager API
and WebDAV the same sentence is the error.

## Caching

A page or file under an address rule is **governed**: never read from or
written to the shared render cache (the processor's `_acl_governed` is true for
it), sent `Cache-Control: no-store, private` (SM1068/SM1069's rule, reused), and
left out of the registries (`sitemap`, search, feeds) and of every `scan:`
list, for everyone: a scan is rendered into a page that may be cached, and what
it lists would otherwise depend on the first visitor's address. A partial under
an address rule included by a page not under the same rule is refused, as for
a read rule (SM898).

## Audit

One `address-refused <target>` row per target per address per hour (the SM1115
pattern of `plugins/form-handler.pl`), detail = the `decide` reason code and the
list names, written by `Lazysite::Auth::AddressAudit` for every door. The markers
live in `lazysite/auth/.address-refused.db` and the first refusal of each clock
hour clears the old ones, so a scan holds at most an hour of keys. A marker
store that cannot be opened writes no row (and logs a WARN) rather than a row
per request.

## Faults and unknown names

A store that will not read denies whenever a rule names a list (SM1138's
fail-closed rule), allow list or deny list alike. An unknown name in an allow
list admits nobody and in a deny list blocks nobody.

## Setting a rule

`acl-set` (the manager API, `set_permissions` on MCP, `lazysite acl set
--addresses LIST --addresses-deny LIST`) takes `addresses` and `addresses_deny`:
an array or comma-separated names. Absent leaves the rule's lists as they are
(the record is rebuilt on each write, so this matters), an empty list clears.
Each name must be a valid list name or the call is refused and nothing is
changed. **A name the store does not hold yet is accepted with a warning**, since
a list may be created later; the warning says that, and that until the list
exists an allow list naming it admits no address and a deny list blocks none. A
deny list named under `addresses` (or the reverse) is accepted and warned about as
the wrong kind. `acl-get` returns the fields, and with `address_lists` (name and
kind only, never entries) so the Files page can offer them; the listing carries
`addresses` and `addresses_deny` per entry. The audit row for `acl-set` names
the lists.

## The Files page

The permissions card gains **Limited by address**: "Only these addresses" (the
store's allow lists) and "Never these" (its deny lists), multi-select, with a
name the rule carries that the store does not hold kept selected and marked "(no
such list yet)". Saving sends both fields; a card whose only content is an
address list is an `acl-set`, not a removal. The controls declare their impact
(lint 109).

# What it does not do

- **A front end that serves a file from the document root before the engine
  sees the request is not limited.** The rule is enforced by the engine, the
  manager and WebDAV; it does not move a file into the private store as a read
  list does (SM286), because that placement serves a different purpose and a
  rule that only narrows by network should not take a public page offline
  elsewhere. A site that needs the bytes unreachable from the front end uses a
  read rule as well.
- The site-wide manager rule, group address lists, the template test and the
  check for a missing `trusted_proxies` are slices C and D (SM1140, SM1141).

# Tests

- t/integration/280: through the real processor behind a trusted proxy: an
  allowed address served; an unlisted one refused with the sentence; deny wins;
  a folder rule on a page, a static and a `.url` page; two folders and a page
  ANDed; no render written and a second visitor from a refused address gets none
  of the first's; one audit row per target per address per hour; a faulted
  store denies; an unruled page unaffected; X-Forwarded-For from an unlisted
  peer is not believed.
- t/integration/281: `acl-set` writes, validates and warns; unrelated changes
  keep the lists and an empty list clears; `acl-get` and the listing return
  them; the manager API refuses a read and a write from outside; WebDAV
  refuses GET, PUT and DELETE, serves the office, and audits once.
- t/unit/processor/140: the processor's chain and the library's name the same
  layers for the same paths, and refuse in the same words.
- t/unit/manager/360: the Files card's pickers, in node.
- t/lint/220: the page's `addresses` keys read the same in the gate and the
  validator.
