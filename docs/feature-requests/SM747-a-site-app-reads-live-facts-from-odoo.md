---
id: SM747
title: "SM747: the Odoo extension - a person uses Odoo through a lazysite page as themselves"
subtitle: "One filing for the whole Odoo extension: per-user authentication carried in a cookie, a signed identity context for rendering, a proxy transport in two modes, an MCP surface under the agent's own Odoo account, and the object mapper to be merged when its specification arrives. Consolidated 2026-09-26 from the odoo-bridge draft, the release manager's authentication briefing and its egress follow-up, and the engine's audit. Queued for a future release; nothing here is built."
brand: plain
standard-margins: true
status: candidate
status-note: "CONSOLIDATED 2026-09-26 at the release manager's direction: this filing is the authority for the Odoo extension. It absorbs the 2026-09-03 odoo-bridge draft (named queries, OOM as a package), the 2026-09-26 briefing (authentication, identity context, proxy transport - Parts 1 to 7, required outcomes 1 to 13, scope control), the same-day follow-up correcting the egress assumption, and the engine's egress audit. X4 RULED 2026-09-28, as recommended, all three questions together: the proxy does its own HTTP as mode 2 INSIDE SM579's policy rather than beside it (X4); no plain `http://` to an RFC1918 Odoo, `https://` to a private hostname being enough (X4-a); and general mode does supersede the original 'no raw passthrough, ever' when the credential on the wire is the user's own, the rule standing for a service account (X4-b). The register row is deleted, which is what the register asks for. The ruling has a consequence that is a PREREQUISITE rather than part of this filing: SM579's three invocation modes are connector-private today (`$MODES` and `may_call` in Lazysite::Manager::Connectors), so the policy has to become shared before a proxy can declare itself mode 2 inside it. STILL OPEN before building: the object-mapper specification, which is not in the tree at all, and OOM being installed on a host this engine can reach (OB7; tracked as OP-25). One piece of work came OFF the build on 2026-09-28: OOM's transport is already hardened, so no injected transport is needed."
---

# Provenance, and what this filing now is

Four documents said what the Odoo extension should be, in three places and two
vocabularies. On 2026-09-26 the release manager directed that they be combined
here and that this filing be the authority. They were:

| Ref | Source | Date | Absorbed as |
| --- | --- | --- | --- |
| P1 | `odoo-bridge` plugin draft (the object mapper consumed as OOM; named queries) | 2026-09-03 | the *scoped* proxy mode, OB1 to OB7 |
| P2 | Briefing - Odoo plugin: authentication, identity context and proxy transport | 2026-09-26 | Parts 1 to 7, the settled decisions, required outcomes 1 to 13, scope control |
| P3 | Follow-up to the briefing - egress mechanism corrected | 2026-09-26 | the egress question and its three candidates |
| P4 | Engine audit - which egress policy applies to the proxy transport | 2026-09-26 | the finding, the recommendation, the engine notes |

The object-mapper specification the briefing calls "specified separately ... to
be merged into this spec" is **not in the tree** as of the consolidation. Its
seams are held open below and it is merged here when it is filed.

Where P1 and P2 disagreed, P2 wins and the disagreement is written down (see
*Reconciling the draft with the briefing*). Where the engine found the briefing's
assumptions wrong against the code, the finding is recorded and nothing was
changed silently.

Vocabulary: [[SM817]] ruled that lazysite's bundled plugins are **extensions**.
This filing says *extension* for the thing being built and keeps *plugin* only
where it quotes a source.

# Why this is worth building properly (release manager, P2)

The immediate driver is helper apps, but the destination is larger: a
headless-ERP surface where lazysite is the interface layer and Odoo remains the
system of record.

Once a signed-in user's Odoo identity is available to lazysite at render time,
pages can be tailored by that user's Odoo groups and company, which makes
function-specific interfaces practical - a timesheet screen that shows one
worker exactly what they need, rather than teaching them to navigate Odoo. A
suite of such apps is the intended direction, so this foundation is built for
reuse, not for one app.

The same surface reached over MCP gives an agent the ability to do Odoo work
bounded by real Odoo permissions, with Odoo's own audit trail recording it. That
falls out of this work rather than needing its own project.

# Settled decisions (release manager, P2 - do not revisit)

1. **Lazysite stores NO Odoo credential server-side, ever.** The credential
   lives in an httpOnly cookie on the lazysite domain and is replayed on each
   proxied call.
2. **The browser never talks to Odoo directly.** All traffic goes through the
   lazysite proxy, so no CORS configuration is needed and Odoo may sit on an
   internal network reachable only by lazysite. This is a security property,
   not an implementation detail - preserve it.
3. **Odoo is the authority on authorisation.** Record rules, access rights,
   multi-company scoping and field-level access are enforced by Odoo per user
   and are NOT reimplemented.
4. **Odoo identity is SEPARATE from lazysite identity.** A lazysite account is
   not required to use an Odoo app. An optional mapping between the two may be
   stored later; credentials never are.
5. **Two proxy modes:** general (bounded only by the user's Odoo permissions,
   for the general interface) and scoped (an allowlist of models and methods,
   for a purpose-built app). Mode is per app, declared, not global.
6. **Strategies are pluggable.** Session authentication and API key ship first;
   a custom Odoo token module and OAuth arrive later without changing anything
   downstream.

# Requirements

The draft's OB rows are kept where they survive P2 and rewritten where they do
not; the briefing's parts are given rows of their own so the work can be
scheduled and closed by reference.

## Connection and transport

| Ref | Requirement |
| --- | --- |
| OB1 | Per-site Odoo connection in the extension's config: `odoo_url`, `odoo_db`, `odoo_strategies`, `odoo_timeout`, `odoo_identity_ttl`. No shared service account and no stored credential for the user-facing path. If the MCP surface needs a service account (OM1) it follows the mode-600 credentials-file convention and is never displayed. |
| OB2 | **Scoped mode**: a declared allowlist of models and permitted methods per app. Refused by lazysite before the call leaves. The default for a purpose-built app. (P1's "named queries" live here - a named query is a scoped allowlist with bound parameters.) |
| OB3 | **General mode**: no model or method allowlist; bounded by the user's own Odoo permissions exactly as Odoo's web client is. An allowlist here would mean enumerating Odoo badly and forever. **Applies only to a call made with the user's own credential** - see *Reconciling*. |
| OB4 | Caller gating is lazysite's: the proxy is reached by a lazysite session on an app page (mode 2 of [[SM579]]), and the call carries the Odoo credential from the cookie. No scheduled and no public mode for the per-user proxy. |
| OB5 | A per-call timeout (`odoo_timeout`); a rate cap per identity; Odoo faults mapped to lazysite's `{ ok: 0, error, kind }` shape with **distinct kinds** for session-expired, invalid-credential, odoo-access-refused and transport-failure. The fault's own text is logged, never returned verbatim (three leaks in three passes taught this - [[SM713]], [[SM738]], [[SM739]]; `t/lint/112` checks the source). |
| OB6 | Transport discipline, the connector's reused as behaviour: no redirect following - a 3xx is a named refusal, because the credential would travel with it; a response size cap sized for Odoo reads and configurable; TLS peer verification on; `https://` to any host and `http://` only to loopback. **X4-a settled this 2026-09-28: no plain `http://` to an RFC1918 Odoo** - `https://` to a private hostname, which the connector rule already permits, is what "internal network" means here. |
| OB7 | OOM is delivered as a versioned package (`libodoo-oom-perl`); the extension declares a minimum version in `owns.deps` and never carries a copy of the code. Settled by the release manager 2026-09-03. |
| OB8 | One audit record per proxied call on the lazysite side: actor (lazysite account if any), Odoo login, model, method, mode, outcome state (answered / unanswered / refused / odoo-fault), never the payload and never the credential. Written the way connectors write theirs. |
| OB9 | Recorded in SECURITY.md as a new outbound interface (threat delta, controls, residual risk, verdict), as SM136 was for XMPP; named in FEATURES.md as the third egress kind after the guarded GET and the connector: *a per-user proxy to an operator-configured upstream*. |

## Authentication and the credential cookie (P2 Parts 2 and 3)

| Ref | Requirement |
| --- | --- |
| OA1 | Every strategy implements one contract: take user input, obtain a credential from Odoo, return what the cookie should carry plus the identity context (OA4). Everything downstream is strategy-independent. |
| OA2 | **Strategy: session.** POST db, login and password to Odoo's session-authenticate endpoint; the returned session identifier is what the cookie carries and is replayed as a Cookie header on each proxied call. Stated limits, in the docs rather than discovered: the password transits the extension (never logged, stored or echoed); a user with two-factor authentication cannot complete this flow. Suitable for internal tools on trusted networks. |
| OA3 | **Strategy: apikey.** The user generates a key in their own Odoo preferences and pastes it once. Preferred implementation: use the key ONCE at login to obtain a session, carry the session, discard the key. If the target Odoo version does not support that, carry the key and say so in the docs - a long-lived credential in a cookie is a materially different risk and must not be silently adopted. |
| OA4 | The credential cookie is httpOnly, Secure, SameSite; path-scoped to the app's own path; cleared on logout and when Odoo reports the session invalid. |
| OA5 | **Amplification, designed against:** with an httpOnly cookie and a same-origin proxy, any script injection on a page that can reach the cookie path can drive Odoo as the signed-in user without reading the cookie. Required from the start: a CSRF token on the lazysite leg for every state-changing proxied call (the manager-api pattern), the path scoping above, and a tight content-security-policy on app pages. |
| OA6 | A shared browser-side data module handles fetch, the CSRF token with one retry, and the re-authentication prompt. Every app page uses it; no page writes its own fetch logic. |

## Identity context (P2 Part 4 - the part that unlocks the rest)

| Ref | Requirement |
| --- | --- |
| OI1 | On successful authentication, fetch the user's Odoo identity once - uid, login, display name, group membership (xml ids where obtainable), company id and allowed company ids, lang, tz - and make it available to rendering. |
| OI2 | Carried in a SECOND cookie, distinct from the credential, HMAC-signed with the site secret and verified on every render. An unsigned identity cookie lets a user edit their own group membership and change what the server renders; a tampered one is rejected and the page renders as though unauthenticated. |
| OI3 | Short TTL (`odoo_identity_ttl`); refreshed transparently on the next proxied call after expiry. Groups and companies change in Odoo and the cookie will not know. |
| OI4 | **THE RULE, in the code comments and the docs:** identity context is for PRESENTATION ONLY, never for authorisation. Hiding a button from a non-manager is a convenience; the proxy still forwards the call if it is made, and Odoo is the thing that refuses it. Any code path that uses identity context to permit rather than to present is a defect. |
| OI5 | **The caching landmine, made impossible rather than documented:** lazysite caches rendered HTML. A page whose output varies by Odoo identity MUST NOT be served from a shared cache. Either mark such pages uncacheable or key the entry by identity, and make the unsafe case fail closed - a page that binds identity and forgets the flag must not leak. Engine note: [[SM857]] (d) already ruled that a gated page bypasses the cache and that a `mine` binding implies the same treatment; an identity binding is the third member of that set and should reuse the same mechanism, not add one. |

## MCP surface (P2 Part 6)

| Ref | Requirement |
| --- | --- |
| OM1 | An agent uses ITS OWN Odoo account, configured by the operator - never a human user's credential and never impersonation. Attribution in Odoo's audit trail stays truthful; the agent's Odoo permissions are what bound it. |
| OM2 | Tools follow the connector's naming and error conventions. The exact set is settled when the mapper spec is merged; at minimum: introspect models and fields, read, write, all within the agent's own permissions. |
| OM3 | A distinct `manage_odoo` capability, separate from `manage_content` and `manage_data`; writes audited on the lazysite side as well as Odoo's. Engine note: a new capability costs the map, the grid, `describe-capabilities`, both channel gates and the docs ([[SM857]] (g) priced this); the briefing asks for it deliberately and the cost is accepted here rather than discovered at build. |

## TT surface (P2 Part 7)

| Ref | Requirement |
| --- | --- |
| OT1 | Identity context exposed to templates under a single namespace: name for greeting, groups for showing or hiding sections, company for scoping, lang and tz for formatting. Variable naming obvious and documented on the extension's page. |
| OT2 | Every example in the docs demonstrates presentation use and none demonstrates authorisation use, so the pattern the next author copies is the safe one. |

# Reconciling the draft with the briefing

**P1's load-bearing rule was "Named queries only. No raw model, method or domain
passthrough to the browser, ever."** P2's general mode is passthrough by design,
and its scope control forbids an allowlist there. The two are reconcilable only
by naming the difference: **who holds the credential.**

- P1's client held an operator service account. With a shared credential, a
  caller who can name a model and a domain has an arbitrary-read primitive
  against the business system, reachable from a page - so the rule was right for
  that design and stays right for every service-account path (OM1).
- P2's proxy carries the signed-in user's own credential. Odoo's record rules
  and access rights bound the call exactly as they bound Odoo's own web client,
  and the audit trail names the person. Passthrough is then not a primitive
  lazysite grants; it is Odoo's own surface reached through a proxy.

So: OB3 (general mode) applies only to a call made with the user's own
credential; OB2 (scoped mode) is P1's named-query shape and is the default for a
purpose-built app; OM1 keeps P1's rule for agents. P1's "first useful queries"
(available quantity by product, lot and location; sales-order and picking state;
whether an order was validated since the last export) are the first scoped app.

**P1 said request-time, not the daemon.** Still true. The periodic-refresh idea
it superseded is a scheduler consumer and becomes natural once [[SM666]] phase 1
exists; neither is a reason to wait.

# The egress question (P3), and what the audit found (P4)

The briefing assumed "the 0.13.10 egress capability" would carry the outbound
leg. The release manager's follow-up corrected that: outbound HTTP is the
connector mechanism (0.13.5 to 0.13.9), and a connector holds an operator
credential shared across callers, which is the opposite of what required
outcome 2 needs. Three candidates were put, to be resolved at audit before Part
5 is built:

1. The proxy does its own HTTP as a distinct transport.
2. Connectors gain a per-user credential mode.
3. The proxy is exempted by design and documented as such.

## The finding

**There is no "one egress path" rule in the tree.** The phrase "the only way out
over HTTP" in FEATURES.md sat in the form-handler-types paragraph and meant
*among handlers*; it was reworded 2026-09-26. Four HTTP clients (`Lazysite::Fetch`,
`Manager::Connectors`, `Manager::Layouts`, `Manager::Domains`), SMTP and XMPP each
open their own connection; no lint pins any of them to a module; ADR 0009 (the
plugin contract) says nothing about the network beyond `owns.deps`.

**The rule that exists is about who may cause a call**, ruled by the release
manager 2026-09-03 and written into [[SM579]] ("How an egress call may be
invoked"): every outbound call, "regardless of what is at the other end", is one
of three sanctioned modes - scheduled, invoked by a logged-in user holding the
capability, or backing a public service with bounded input - and the engine
enforces the mode, the caller and the rate while the implementor bounds the
payload. This filing already bound itself to that rule on 2026-09-03 ("An Odoo
query is one of those calls. It takes SM579's modes, SM579's caps and SM579's
declaration").

**The guard is keyed on who chooses the destination.** `Lazysite::Fetch` refuses
loopback, RFC1918, link-local, multicast and CGNAT, is GET-only and carries no
credential, because *content* chooses its URL. Connectors permit private ranges
deliberately ([[SM790]]: "open BY DESIGN ... a service on this host is a
legitimate destination") because the *operator* chose the URL in the reserved
tree; their discipline is redirect refusal, an answer cap, a timeout, the mode
gate, a rate cap and an audit record. The Odoo URL is operator-configured, so
the SSRF guard was never the applicable rule and settled decision 2 ("Odoo on an
internal network") conflicts with nothing enforced.

**Connectors cannot carry the per-user leg as they stand.** They hold one
operator secret per connector in a named header; refuse any payload that is not
a flat hash of text ("never a file or a structure"); cap the answer at 64 KB and
land it in a data-table row; and send form fields or table rows by row map. A
JSON-RPC body is nested, the credential is per request from a cookie, the
response goes to the browser and is stored nowhere, and a `search_read` answer
can exceed 64 KB legitimately. Candidate 2 would not be a mode; it would be a
second transport with a different payload contract, credential model and answer
path, sharing only the name and the `may_call` gate. SM579's own boundary -
"every generalisation of it should be refused by default" - argues against it,
and the follow-up already said it "deserves its own SM".

## The ruling (X4, ruled 2026-09-28)

**RULED AS RECOMMENDED by the release manager, 2026-09-28**, all three questions
together. The recommendation is left standing below as the reasoning the ruling
absorbed rather than being replaced by a sentence saying "approved" - a ruling
that discards its own argument cannot be re-examined when something changes.
What was decided:

| | Ruled |
| --- | --- |
| **X4** | Candidate 1: the proxy does its own HTTP, **stated as mode 2 inside [[SM579]]'s policy, not beside it**. Which means SM579's invocation-mode policy has to become the shared thing it is not yet - today the three modes are connector-private (`$MODES` and `may_call` in `Lazysite::Manager::Connectors`). That generalisation is the first piece of work, and it is a prerequisite of this filing rather than part of it. |
| **X4-a** | **No plain `http://` to an RFC1918 Odoo.** `https://` to a private hostname - which the connector rule already permits - is enough, and is the natural reading of the briefing's "internal network". `http://` stays loopback-only, as OB6 says. |
| **X4-b** | **Yes**: the briefing's general mode supersedes this filing's original "no raw passthrough, ever", reconciled by naming the credential holder. The user's own credential means Odoo's own ACLs bound the call. A service account - Part 6, MCP - keeps the original rule. |

The reasoning, as recommended and now ruled:

**Candidate 1, stated as mode 2 INSIDE SM579's policy, not beside it.** The
proxy does its own HTTP and inherits SM579's enforceable controls by
construction: OB4 (mode 2 only), OB5 (timeout, rate cap, fault kinds), OB6 (the
connector's transport discipline as behaviour), OB8 (the audit record), OB9 (the
register entries). Candidate 3 would document an exemption from a rule the tree
does not have; candidate 1 with those rows is the same work with the true
rationale.

Two sub-questions ride with the decision:

- **X4-a.** May plain `http://` reach an RFC1918 Odoo, or is `https://` to a
  private hostname - which the connector rule already permits - enough? The
  briefing's "internal network" reads naturally as the latter.
- **X4-b.** Does the briefing's general mode supersede this filing's original "no
  raw passthrough, ever"? Recommended yes, reconciled as above by naming the
  credential holder.

The row was on `docs/decision-register.md` and is **deleted**, which is what that
register asks for: it carries what is open, not a history. The ruling is in this
filing's status-note and in the table at the top of this section.

# Engine notes from the audit (P4)

Things found against the code and the neighbouring trees while answering the
egress question, recorded so they are not rediscovered at build.

**OOM's transport IS the hardened one now - this note was true when written and
is not any more.** Re-measured 2026-09-28 against `oom`:
`Odoo::Transport::http_client` builds `HTTP::Tiny->new` with `max_redirect => 0`,
`verify_SSL => 1`, a named agent string and an optional `max_size` from
`max_response_bytes`; `refuse_by_policy` throws kind `refused` on any 3xx or an
oversized answer, by name rather than as a retryable transport failure, and
`JSONRPC` uses both. So most of OB6's discipline already lives inside OOM and
**the extension does not need to inject a transport to get it** - which removes a
piece of work this note had put on the build. What OB6 still has to own is the
part that is about the URL rather than the connection, and that is X4-a's
question. The other half of the original note stands unchanged:
**OA2's session strategy is not what OOM speaks**: OOM authenticates with
`common.authenticate(db, login, key)` and sends the key in every `execute_kw`
body on `/jsonrpc`. OA3's apikey strategy fits OOM; OA2 needs Odoo's
`/web/session/authenticate` and `/web/dataset/call_kw`, for which OOM has no
client. Whether the mapper rides on OOM for both strategies or only for apikey
is a mapper-spec question.

**Target Odoo version.** The Odoo workspace runs series 16 (the read-side
baseline OOM was proven on) and 18; OOM's test plan spans 16 to 20 and flags 19
for a change in RPC password-login policy and a new `/json/2` endpoint. Whether
`/web/session/authenticate` accepts an API key in place of a password (OA3's
preferred implementation) is a live probe, not a fact in either tree; plan for
OA3's fallback on 16 and 18 until probed, and record what was verified against
which series, as the briefing asks.

**Config key naming.** Extensions declare `config_schema` entries as
`{ key, label, type, default, required, show_when, note }` with types `text`,
`number`, `select`, `boolean`, `password`, `path`. The data extension prefixes
its keys (`db_source`, `db_descriptor_dir`) and lists them in `config_keys`;
OB1's `odoo_*` keys follow that style and fit the schema as written.
`odoo_strategies` is multi-valued; no existing extension has a multi-select
convention, so that is settled at build.

**Field descriptors.** The briefing asks whether the mapper's field descriptor
(type, required, readonly, selection values, relation, help) is close enough to
the data extension's table descriptors (`Lazysite::Data::Descriptor`, YAML, read
by YAML::PP) to share a rendering layer. It cannot be checked until the mapper
spec is filed; the comparison target is named here so the check is one step when
it is.

**A neighbouring drift, out of scope.** FEATURES.md and the fetch module's own
header list "remote layouts" among the guarded fetches, but `Manager::Layouts`
opens its own client to fixed GitHub hosts with no call to the guard. Harmless
today (constant host, slug validated); noted, not this filing's to fix.

# Required outcomes (P2 - the work is done when all are true and demonstrated)

1. A user authenticates with their own Odoo credentials through a lazysite page
   and can perform Odoo operations as themselves.
2. Every operation is attributed in Odoo to that user, not to a shared
   integration account.
3. An operation the user is not permitted to perform is refused by Odoo, and
   the refusal is distinguishable in the response from a transport failure.
4. No Odoo credential is stored anywhere on the lazysite server, in any file,
   table, log or cache. Demonstrated by inspection.
5. Odoo is reachable only from lazysite; a browser cannot and need not contact
   it directly.
6. The signed-in user's Odoo groups and company are available to TT at render
   time, and a page can vary its output by them.
7. A tampered identity cookie is rejected, and the page renders as though
   unauthenticated rather than with the claimed groups.
8. A page that varies by identity is never served from cache to a different
   user. Demonstrated with two concurrent sessions.
9. A state-changing call without a valid CSRF token is refused.
10. Session expiry produces a re-authentication prompt, not a silent failure or
    a generic error.
11. Both session and apikey strategies work against the target Odoo version,
    with the apikey strategy's credential-at-rest behaviour documented as
    implemented.
12. An agent over MCP performs Odoo work under its own Odoo identity, bounded by
    that account's permissions.
13. A scoped app cannot call outside its declared allowlist; the general
    interface is bounded only by Odoo permissions.

# Scope control (P2 - do NOT)

- Store credentials server-side under any circumstance, including "temporarily"
  or "for performance".
- Use identity context for authorisation decisions.
- Reimplement Odoo's access model, or filter results lazysite believes the user
  should not see - Odoo already did that.
- Apply an allowlist in general mode.
- Let an agent act as a human user.
- Build the generalised upstream-proxy abstraction. Structure the code so the
  proxy, cookie handling, CSRF and fault mapping sit apart from the
  Odoo-specific request shaping - the same mechanism (forward a call to an
  upstream carrying a per-user credential, store nothing) is not Odoo-specific
  and a second upstream should be an extraction, not a rewrite - but leave the
  seam visible and take the extraction when a second upstream exists.
- Implement OAuth here - it is its own extension when the driver is SSO across
  systems.
- Change lazysite core, except where the outbound HTTP leg genuinely requires it
  - report before doing so. (The audit's answer: the leg needs no core change
  now that X4 is ruled as recommended; OB9's register entries and OI5's cache
  rule touch core surfaces that already exist for this purpose. The one change
  outside this extension is SM579's policy becoming shared, which the ruling
  requires and which belongs to SM579.)

# Verification pointers (P2)

- Two concurrent browser sessions as different Odoo users against an
  identity-varying page: each sees only their own rendering, cold and warm
  cache.
- Identity cookie with an edited group list: rejected, renders unauthenticated.
- A method the test user lacks rights for: Odoo refuses, kind distinguishes it
  from a network error.
- grep the filesystem, tables and logs after a full session for any credential
  material: nothing found.
- Odoo blocked at the firewall from the browser's network, everything still
  works.
- Expired session mid-transaction: re-auth prompt, then the action completes
  without data loss.
- A scoped app calling a model outside its allowlist: refused by lazysite
  before the call leaves.
- Engine additions: a 3xx from the upstream is recorded as a refusal and the
  credential is not re-sent; an answer over the cap is refused by name; the
  audit record for a call carries no payload field and no credential.

# Merging the mapper spec (P2 - seams held open)

The object-mapper specification is folded into this filing when it arrives. The
seams left for it:

- the proxy's request-shaping layer (OB2, OB3) is where the mapper sits;
- field introspection output is a field descriptor in the same sense as the data
  extension's table descriptors - check whether the two shapes can share a
  rendering layer (widget per type, generated forms) before either hardens, and
  report the finding;
- the MCP tool set (OM2) is settled by the mapper's surface;
- onchange and x2many command handling are mapper decisions and are not
  pre-empted here - but a write path that never invokes onchange produces
  records Odoo's own UI would not have created, and whatever the spec decides
  the docs must be explicit about it;
- which strategies ride on OOM (see *Engine notes*).

# Sequencing

Scheduled 2026-09-28 at the release manager's direction, after the egress policy
it sits inside. Three gates stood in front of it and one is now down:

| Gate | State |
| --- | --- |
| X4 and its sub-questions ruled | **DONE 2026-09-28**, as recommended |
| SM579's invocation-mode policy becomes shared, so the proxy can be mode 2 *inside* it | the consequence of the ruling, and the piece being built first |
| The mapper specification filed and merged here | **NOT IN THE TREE.** The largest remaining unknown, and design work rather than typing |
| OOM installed on a host this engine can reach (OB7) | built as a package, installed nowhere reachable; OP-25 |

The first scoped app is the stock-corrections portal's live facts (P1).
