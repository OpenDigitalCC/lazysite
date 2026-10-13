---
id: SM747
title: "SM747: the Odoo extension - a person uses Odoo through a lazysite page as themselves"
subtitle: "One filing for the whole Odoo extension: per-user authentication carried in a cookie, a signed identity context for rendering, a proxy transport in two modes, an MCP surface under the agent's own Odoo account, and the object mapper to be merged when its specification arrives. Consolidated 2026-09-26 from the odoo-bridge draft, the release manager's authentication briefing and its egress follow-up, and the engine's audit. Queued for a future release; nothing here is built."
brand: plain
standard-margins: true
status: candidate
status-note: "RULED 2026-10-12: a connection user (a site Odoo account, its credential stored like a connector secret) runs named operations for pages, MCP and backend work; a site user's own sign-in waits on OOM's session transport; Odoo descriptors share data-table rendering; every operation is an MCP tool. Re-planned: A, CU, R, E unblocked. Filed to OOM 10-12: the session transport, the Ops layer in the deb. Q1-Q3 RULED 10-12: a public binding may apply unattended under the engine's controls; MCP uses the default or a per-grant account; the type mapping is OOM's (options filed). RE-FILED 2026-10-13 against OOM 0.09: OOM built the session transport in 0.03 (live on Odoo 16 and 19), the Ops layer and the portable type in 0.02, and in 0.09 the run registry with its approval gate, revert and resume, core.user, core.attach and core.fetch, a JSON-2 transport for 19 and a doctor, all as debs in /srv/projects/packages; B, C and D are no longer waiting on OOM, and whether to build them is the release manager's (B-Q1)."
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

# Ruled 2026-10-12

The release manager, in their words:

> "the extension can hold odoo specific data such as a connection user, as well as a
> site user specifying their own. the connection user is set on odoo with permissions
> as required by the user, which allows some backend activities, without the user
> logging in. the oom deb will be updated so assume that carries what you need, and if
> not, file to the oom inbox. wait for OOM to gain the session transport, and ensure
> this request also filed. Odoo field descriptors can share lazysite's data-table
> rendering. All operations should also be mcp tools."

## What it decides

| Ref | Decided |
| --- | --- |
| R1 | **A connection user.** The extension holds a site-level Odoo account: a login and its API key. Its rights are set **in Odoo** by whoever administers Odoo, as the site's work needs; lazysite grants it nothing and narrows nothing Odoo allows. It lets the extension do backend work - a scheduled job, a public form, a page a lazysite user opens - with nobody signed in to Odoo. |
| R2 | **A site user may specify their own credential** - the per-user path of Parts 2 to 4. It **waited for OOM's session transport, which shipped 2026-10-13 (0.03); building it is B-Q1**; OA3's fallback (the key itself carried in the cookie) is not taken. The request is filed (see *Where the 2026-10-12 requests were filed*). |
| R3 | **OOM is delivered as the `libodoo-oom-perl` deb**, which will be updated to carry what the extension needs; a gap is filed to OOM's inbox. This answers stage 0's delivery-shape question (OP-25) and OB7. |
| R4 | **Odoo field descriptors share lazysite's data-table rendering.** The seam this filing held open since 2026-09-26 is closed. |
| R5 | **Every operation is also an MCP tool.** The open selection under OM2 is closed: all of them. |

## What it changes against this filing's text

Until this ruling, outcome 2, outcome 4, OB1, settled decision 1 and the first
scope-control rule together forbade a shared Odoo account and any stored Odoo
credential on the user-facing path, and the 2026-10-02 plan read them, correctly, as
"there is no cheap read-first slice". **R1 permits exactly that account and its stored
credential.** The rows below are amended as stated; each carries a pointer back here.
Nothing else in the requirements changes.

| Row | Said | Now, under R1 to R5 |
| --- | --- | --- |
| Settled decision 1 | Lazysite stores NO Odoo credential server-side, ever | No **user's** Odoo credential is stored server-side, ever - unchanged for the per-user path. The **connection user's** credential is the one stored credential, on the terms in OB1 |
| OB1 | No shared service account and no stored credential for the user-facing path; a service account only for MCP, mode 600 | The extension's config may hold a connection user: `odoo_login` and an API key. **Stored as connector secrets are** (`Manager::Connectors`): the key in a separate 0600 file, written on its own, never listed, never returned by any action or tool, never logged; `has_secret` answers 1, 0, or null for "cannot tell". An API key, not a password: OOM refuses a password in its config (`Odoo/Ops/Config.pm:68`) and its `file` strategy enforces mode 600 on the key file (`Odoo/Ops/Credential.pm:48-57`) |
| OB3, X4-b | General mode applies only with the user's own credential | **Unchanged, and now load-bearing.** The connection user is a shared credential, so it runs **scoped mode only** - named operations behind `Odoo::Ops::Guard`, from every surface. P1's "no raw passthrough, ever" holds for it in full |
| OB4 | Mode 2 only; no scheduled and no public mode for the per-user proxy | Unchanged for the per-user proxy. The connection-user path takes [[SM579]]'s three modes, **declared per binding**: mode 2 (a lazysite user holding the capability), mode 1 (scheduled) and mode 3 (public, bounded input) - R1's "backend activities, without the user logging in" |
| OB8 | Actor (lazysite account if any), Odoo login, model, method, mode, outcome | For a connection-user call the actor is **the lazysite account that triggered it** (or the mode and binding, for a scheduled or public call) and the Odoo login is the connection user's. OOM's own audit carries the same actor: `Odoo::Ops::Context` takes `actor` (`Context.pm:65`) and the Guard writes it on every record (`Guard.pm:128`) |
| Outcome 2 | Every operation attributed in Odoo to that user, not to a shared integration account | Per-user path: unchanged. Connection-user path: **attributed in Odoo to the connection user**, and in lazysite's audit to the lazysite account (or mode) that triggered it. The two records together are the truthful trail |
| Outcome 4 | No Odoo credential stored anywhere on the lazysite server | No **user's** Odoo credential stored anywhere - unchanged, demonstrated by inspection. The connection user's key exists in exactly one place, the extension's 0600 secret file, and the inspection extends to proving it is in no table, log, cache, page, response or audit record |
| OM1 | An agent uses its own Odoo account, configured by the operator | **Met by the connection user**: an operator-configured, non-human account; never a person's credential, never impersonation. Whether MCP gets an account of its own is Q2 below - **ruled 2026-10-12: the default or a per-grant account** |
| OM2 | The tool set is settled when the mapper spec is merged; at minimum introspect, read, write | **All operations** (R5): every operation OOM's `Odoo::Ops::Registry` lists becomes a tool, generated from its `op_name`, `summary` and `params`, with no per-operation engine code. 16 today - 12 CRM, 2 Comms and 2 Core (`core.check`, `core.rights`). A write operation's tool returns its plan; one apply tool applies a plan by fingerprint |
| Scope control, first rule | Store credentials server-side under any circumstance | Applies to **user** credentials. The connection user is the ruled exception, on OB1's terms and no others |
| Field descriptors (*Engine notes*, spec section 8) | Whether they can share the data extension's rendering is unanswered | **Closed by R4**: they render through the data extension's table rendering (`Lazysite::Data::Descriptor`'s types - text, integer, decimal, boolean, date, datetime, enum; `lib/Lazysite/Data/Descriptor.pm`). Where the Odoo-type-to-lazysite-type mapping lives is Q3 |

Outcome 12 and OM3 stand as written; the connection user satisfies the first.

## Questions the ruling leaves (none blocks slice A or CU's read half)

> **All three RULED 2026-10-12** - see *Ruled 2026-10-12 (Q1-Q3)* below. The
> questions and their recommendations are kept as the record the rulings answered.

- **Q1. May a scheduled or public binding apply a write plan with nobody to confirm
  it?** Mode 2 previews the plan's buckets and applies on confirm. Modes 1 and 3 have
  no one at the page. Recommended: only where the binding declares it per operation,
  the plan still saved and journalled; plan-only otherwise.
- **Q2. Does MCP use the pages' connection user, or one of its own?** One account is
  enough for R1 and OM1; a second makes Odoo's own trail tell agent work from page
  work. Recommended: one now, a second as a configuration addition when somebody
  needs the separation.
- **Q3. Where the type mapping lives.** Mapping Odoo's field types (`many2one`,
  `monetary`, `selection` ...) onto the data extension's seven is Odoo knowledge,
  which *The rule that keeps it general-purpose* puts in OOM. Recommended: OOM hands
  the descriptor with a portable type beside the Odoo one (asked, not blocking, in the
  deb request); failing that, one mapping table in the extension, named by the
  boundary lint.

## The status-note before this ruling

It recorded the consolidation of 2026-09-26, X4's ruling of 2026-09-28, the
prerequisite that landed in 0.15.1 (`Lazysite::Egress`), the mapper specification
filed on 2026-10-01 with its hash and `t/lint/207`, the two seams that filing left
open (descriptors, the MCP selection), the session transport OOM does not have, and
the 0.01 deb's 8 modules of 41. All of it is in the body below; R3 to R5 close the
three that were open.

# Ruled 2026-10-12 (Q1-Q3)

The release manager, in their words:

> **Q1** (may a scheduled or public binding apply a write plan with nobody to
> confirm): "use case includes ecommerce, where a visitor adds to basket and this
> creates sales quotation as basket. there may be other functions that an anonymous
> visitor uses, and determined by the internal odoo user to control what this may
> do."
>
> **Q2** (MCP account): "MCP will use the default or specified account. the default
> user is likely to be more restrictive, so having an own user may open up more
> functionality."
>
> **Q3** (where the Odoo-field-type to lazysite-type mapping lives): "open to
> recommendations, maybe put options to oom inbox, and it can be worked through
> there."

## What they decide

| Ref | Decided |
| --- | --- |
| Q1 | **A public (or scheduled) binding may APPLY a named write operation through the connection user with nobody confirming.** What it may do is bounded by two things and only two: (1) the connection user's rights, set in Odoo by whoever administers Odoo; (2) which named operations the page binds - OOM's Guard refuses any call outside the bound operation's declared scope before it leaves. Lazysite narrows nothing Odoo allows and grants nothing Odoo refuses. |
| Q2 | **MCP uses the connection user by default, or an Odoo account configured for that MCP grant**, its key stored as the connection user's is (0600, written alone, never returned, `has_secret` three-state), one per grant. Slice E. |
| Q3 | **The mapping is OOM's to settle, worked through in its inbox.** Filed as an options paper: `/srv/projects/odoo/oom/inbox/2026-10-12-field-type-mapping-options-for-lazysite.md`. Slice R is built against an interface that takes the PORTABLE type from OOM's descriptor when present and otherwise REFUSES to render the field, naming it - so lazysite holds no mapping whichever option OOM takes, and t/lint/240 keeps it that way. |

## The design Q1 requires of the engine

An anonymous write path into an ERP is the sharpest thing this extension adds, so the
controls are the engine's on every public apply, whatever the operation:

| Control | What the engine does |
| --- | --- |
| Opt-in, per binding | A binding permits `public` only when it says so (SM579's opt-in); a write binding declares `apply: immediate` to apply in the same request, otherwise its plan waits for a confirm. The gate is `Lazysite::Egress`, as for a connector. |
| Rate caps | Two, counted from the call record and decided by `Egress::within_caps`, most specific first: **per visitor per hour** and **per binding per hour**. A cap whose count cannot be taken refuses (an unreadable record is not zero). This is what stands between a script and a flood of quotations. |
| CSRF on the page's POST | A public POST carries a token bound to the visitor's key (HMAC under the extension's own secret); a signed-in POST carries the manager-api session token. The visitor cookie is `HttpOnly; Secure; SameSite=Strict`, so a cross-site POST arrives without it and cannot name a basket. |
| Input validation by the operation's declared parameters | Only the parameters the binding MAPS from input can come from input; each is checked against the operation's own declaration (type, required) before OOM is called, and an unknown or unmapped name is refused by name. Fixed parameters (`fixed:`) and the visitor parameter cannot be overridden by anything the request carries. |
| The visitor's own basket, and nobody else's | A visitor key is 256 random bits minted SERVER-SIDE and signed, so a key the server did not mint is refused. It reaches the operation only through the binding's declared `visitor_param`; a plan is stored against the key that made it and only that key may apply it; plan ids are unguessable. A visitor can therefore neither name, read nor alter another visitor's basket or quotation. |
| Audit naming the visitor | OB8's record names the actor as `visitor`, a hash of the visitor key (never the key, which is a bearer secret), the IP, the binding, the operation, the mode and the outcome; OOM's own audit carries the same actor on every RPC record. |

What the operation pack does with the visitor key - which Odoo record holds a basket,
how a basket becomes a quotation - is the pack's, per *The rule that keeps it
general-purpose*.

## What they change against this filing's text

| Row | Now |
| --- | --- |
| OB4 (amended 2026-10-12 R1) | **Q1:** a binding's `public` and `scheduled` modes may apply a write operation unattended when the binding declares `apply: immediate`, under the controls above. |
| OB5 | The per-identity rate cap is **per visitor key** on the public path and per lazysite account on the authenticated path. |
| OB8 (amended R1) | **Q1:** for a public call the actor is `visitor` with the visitor-key hash and the IP. |
| OM1 (amended R1) | **Q2:** the connection user by default, or an account configured for the MCP grant. |
| Field descriptors (closed by R4) | **Q3:** the type comes from OOM as a portable type; lazysite refuses a field without one. Options filed to OOM. |
| Outcome 9 | Holds on the public path too: a state-changing public call without a valid visitor-bound token is refused. |

# Built

Stacked branches from n470, each with its tests and a sabotage run (every guard
below was broken on purpose and its test went red; backups under
`tmp/sab-bak/sm747/`, restored and compared). OOM is loaded from its tree for the
tests (`t/lib/OdooTest.pm`, `LAZYSITE_OOM_LIB`), which says 0.01: a test that needs
OOM to run raises `$Odoo::Ops::VERSION` to the 0.02 the deb will carry and says so;
the refusal of 0.01 is tested without it. (The tree no longer says 0.01: it says 0.09 since
2026-10-13 (0.06 by the afternoon), so t/unit/odoo/04 and 05, which tested that refusal against it, fail on main;
branch n576 stands up an Odoo::Ops of its own that says 0.01.) No test reaches a network: OOM's
`Context` takes an injected transport, and the fake Odoo is OOM's own test double.

## Slice A - built 2026-10-12 (n471)

| Row | What | Where |
| --- | --- | --- |
| OB7, R3 | The extension, `plugins/odoo.pl`: a contract extension (born off), its config keys, and `owns.deps` = `Odoo::Ops (libodoo-oom-perl >= 0.02)`. The dep grammar gained `(package >= version)` (`Lazysite::Plugins::Owns::parse_dep`), read by the validator and by the enable path, which now refuses a module that loads but is older and names the declared package rather than one guessed from the module name (the guess was `libodoo-ops-perl`, which does not exist). At run time `Lazysite::Odoo::oom_check` refuses by the same name | `plugins/odoo.pl`, `lib/Lazysite/Plugins/Owns.pm`, `lib/Lazysite/Manager/Plugins.pm` (`_missing_deps`), `lib/Lazysite/Odoo.pm`; t/unit/odoo/04, 05 |
| OB1 | The connection in the extension's config (`lazysite/odoo.conf`): `odoo_url`, `odoo_db`, `odoo_login`, `odoo_timeout` (30), `odoo_max_kb` (2048), `odoo_allow_writes` (off), `odoo_packs` (extra operation-pack namespaces). Read and checked once, by `connection()` | `Lazysite::Odoo::connection`; t/unit/odoo/01 |
| X4-a, OB6 | https:// to any host; http:// to loopback only; plain http:// to an RFC1918 address refused in its own sentence, naming the remedy (https:// to the private hostname); a user or password in the URL refused | `check_url`; t/unit/odoo/01 |
| OB5 | OOM's kinds and Odoo's fault categories mapped to `{ ok: 0, kind, error }`: `session-expired`, `invalid-credential`, `odoo-access-refused`, `transport-failure`, plus `odoo-validation`, `odoo-missing`, `odoo-fault`, `scope-refused`, `read-only`, `stale`, `applied`, `edited`, `refused`, `config`, `invalid`, `internal`. The text is logged, never returned | `fault`, `outcome_of`; t/unit/odoo/02 |
| OB8 | One record per call in `lazysite/odoo/calls.jsonl` (0660), fixed fields `at call_id actor visitor ip login binding operation mode phase outcome kind ms`; the sink refuses any other key; one line in the shared audit trail (`odoo-call`) | `record_call`, `read_calls`; t/unit/odoo/03 |
| OB4, X4 | The mode gate is `Lazysite::Egress::may_invoke`, and `gate()` asks, in order: who (mode, callers), the extension switch, OOM present and new enough, the connection. Every refusal is a row | `may_call`, `gate`; t/unit/odoo/04 |
| *The rule that keeps it general-purpose* | **The boundary lint**: no RPC method or endpoint, ORM method name, dotted Odoo model name, Odoo field type or exception class in any functional file (comments and POD excepted, tests out of scope) | `t/lint/240-lazysite-holds-no-odoo-knowledge.t` |

Decisions taken in A, each from the filing's own text:

- **The endpoint.** The slice table says "endpoint config as a new handler type";
  OB1 and R1 put the connection, one per site, in the extension's config. Both are
  kept: the connection is the extension's, and the handler type `odoo` (slice CU) is
  how a form, the schedule or a page reaches it, naming an operation. Repeating a URL
  and a credential on every handler would be several copies of one connection.
- **No `storage` declared.** `lazysite/odoo/` will hold the connection user's key and
  plans carrying Odoo's records; a site package carries declared storage to another
  site, and neither belongs there.
- **The override capability is `manage_connectors`** until slice E brings
  `manage_odoo` (OM3), which the plan places in E: it is the capability that already
  governs where site data is sent and who sets a destination's secret.
- **The CHANGELOG key is `odoo-extension`, not SM747.** (Applies to every slice.) t/lint/75 reads SM747 as
  already shipped: c53a7143 ("the mapper specification filed") landed
  `t/lint/207` under an SM747 subject in a tagged release whose section has no
  SM747 bullet, so an Unreleased `- SM747` entry reads as stranded work. The
  entries name SM747 in their titles instead.

## Slice CU, the engine - built 2026-10-12 (n472)

| Row | What | Where |
| --- | --- | --- |
| OB1 (R1) | **The connection user's key**: one file per account under `lazysite/odoo/keys/`, written alone through a 077 umask and renamed into place (0600 from the moment it exists), never returned or logged; `has_key` answers 1, 0, or undef when the file exists and cannot be read. OOM reads it through its own `file` strategy, so OOM's mode check applies too. Outcome 4's inspection: after a full call the key is in that file and in no other file under the site | `Lazysite::Odoo::Secret`; t/unit/odoo/06 |
| R1 | **An OOM context per call**, built in memory, carrying the key, the connection, `allow_writes` and the ACTOR (`account:<name>`, `visitor:<hash>`, `scheduled`), which OOM's Guard writes on every RPC record. One attempt (`retries => [0]`): OOM's default ladder sleeps up to 22 s, right for a batch and wrong for a waiting visitor | `Lazysite::Odoo::context`; t/unit/odoo/09, 10 |
| OM2 seam | **Operations through OOM's registry**: OOM's packs plus `odoo_packs`, by namespace | `registry`, `operation_class` |
| OB2, SM579 | **The binding is a handler of type `odoo`**: `operation`, `params` (`field=parameter` - the only names a request may set), `fixed` (the operator's, never overridable), `visitor_param` (the server's key, never input), `modes`, `callers`, `apply` (`confirm` or `immediate`), `rate_per_visitor_hour` (20), `rate_per_hour` (200). Saving it checks it against the operation's own declaration when OOM can be asked (unvalidated is not invalid otherwise). Configured under `manage_connectors` until E | `lib/Lazysite/Handlers.pm`, `Lazysite::Odoo::Binding`; t/unit/odoo/08, 13 |
| Q1 | **Parameter injection**: a request feeds only `str`, `int` or `bool` parameters, each checked against the declared type, 1,000 characters at most, no control characters; a `json` (domain), `list` or `path` parameter can only be fixed, and a `path` cannot be set at all | `Binding::check_against`, `assemble`; t/unit/odoo/08 |
| Q1 | **The visitor key**: 256 bits minted server-side, carried `HttpOnly; SameSite=Strict` and signed under the extension's own secret (`lazysite/odoo/visitor.secret`, 0600); a key the server did not mint names nobody; the CSRF token is an HMAC of the key; records carry a hash of it | `Lazysite::Odoo::Visitor`; t/unit/odoo/07, 10 |
| OB4, Q1 | **The call**: `Lazysite::Odoo::call` - the one function that sends - asks, in order, the gate (slice A), the key, the operation, the binding against the operation, the parameters, the caps; then a read returns its report and a write returns its plan's preview (buckets, and each change's bucket and action - never values or before-images) or, for `apply: immediate`, applies it in the same request | `call`; t/unit/odoo/09, 10 |
| Q1, OB5 | **The caps**: per visitor (or account) per hour and per binding per hour, decided by `Egress::within_caps` from a rolling one-hour record taken under a lock; the slot is taken before the call, so attempts count whether Odoo accepts them or not, and a record that cannot be read refuses | `_take_cap`; t/unit/odoo/11 |
| A + CU | **Plans in a private store**: `lazysite/odoo/plans/<128-bit id>/` holds the plan, its owner and, once applied, OOM's journal and audit. `confirm` applies a plan only for the account or visitor that made it (anyone else gets exactly "not found"), within an hour, through the binding as it stands now; OOM's refusals arrive as `applied` (replay), `stale`, `edited`, `read-only`. Pruned after 7 days | `confirm`; t/unit/odoo/10, 12 |
| SM842 | **A form and the timer run a binding** as `public` and `scheduled`, as they run a connector; a binding needing a visitor key, or a write waiting for a confirm, is refused there by name | `Handlers::_to_odoo`; t/unit/odoo/13 |
| SM670 | The Odoo kinds have statuses in `%REFUSAL_STATUS` (Odoo answering badly is 502; Odoo refusing the operation 403; a plan that no longer fits 409; expired 410) | `lib/Lazysite/Manager/Common.pm` |

Decisions taken in CU, from the rulings and the filing:

- **A form is public and the timer scheduled**, exactly as a connector handler is
  told (SM842's precedent), and neither carries a visitor or a confirmer.
- **The preview carries no values.** A plan holds Odoo's records as the operation saw
  them; "present the plan's buckets" (section 5) is what a page is given.
- **Found while building, not this filing's to fix (reported):** `Connectors::sweep` initialises
  `my ( @keep, $expired, $unanswered ) = ( (), 0, 0 )`, so the array swallows both
  zeros and a sweep that expires nothing reports `expired: null`. The same shape was
  written here first and caught by t/unit/odoo/06.

### OOM's approval gate - found 2026-10-13, built (n585)

On 2026-10-13 (OOM's run registry, `Odoo::Ops::Runs`, merged 17:35) OOM's `Runner->apply`
began to refuse a plan nobody had approved (`unapproved`, `approval-stale`), unless the
config says `approval = none`, which OOM describes as for tests and trusted batches.
Every lazysite apply - a confirm, and an `apply: immediate` binding - was then refused
(`refused`, "the call was refused before Odoo answered"), and so were
t/unit/odoo/09 to 12 and 17 against OOM's tree.

**Decision taken** (not settled by the rulings, taken because the alternative is the
safer door left open): the approval is the act lazysite already has. A confirm is the
approval of the account or visitor that made the plan (the owner, who alone can
confirm), and `apply: immediate` is the operator's standing approval of that one
operation, given when they saved the binding. The engine records it with
`Odoo::Ops::Runs->approve_plan` - by whom, a note, the plan's own fingerprint -
immediately before the apply, and **does not set `approval = none`**: OOM's gate stays
on for anything lazysite did not approve. A plan already applied is not approved again
(OOM refuses the replay by name, `applied`). An OOM without the registry has no gate and
nothing is recorded. t/unit/odoo/40.

**Asked of the release manager, if the other reading is wanted:** that a confirm is not
enough and a second, separate approval step is. That is a design change to Q1's
"nobody confirming" cases and is not taken here.

## Slice CU, the surfaces - built 2026-10-12 (n473)

| Row | What | Where |
| --- | --- | --- |
| OA5, outcome 9, Q1 | **The page endpoint, `lazysite-odoo.pl`** (declared in `owns.endpoints`, shipped in the deb, classified as a core CGI). `GET ?csrf=1` gives the visitor token - minting the visitor cookie if there is none - and, for a signed-in account, the session token; `GET ?binding=` runs a READ binding (a write sent as a GET is 405); `POST {binding, params}` runs one; `POST {plan, confirm}` applies a plan this caller made. It verifies its own caller (SM411). A POST needs the session token when the call is authenticated and the visitor token - with the SameSite=Strict cookie it is bound to - when it is public. 64 KB body cap; statuses from the shared refusal map (429 for the caps, 409 for a replayed confirm). Switched off, it answers 403 and mints nothing | `lazysite-odoo.pl`; t/integration/170 |
| OT (CU's "report handed to TT") | **`tt_page_var: x: odoo:ID`** renders a READ binding's report into a page, run as `public` with no request input. A render never runs an operation that writes (or one that cannot be asked whether it does); never renders a binding that works on a visitor's key (the render is shared and cached); and escapes every scalar in the report as a `db:` row is (SM786). Logged by name when it refuses | `lazysite-processor/sources.pm` (`resolve_odoo`, `_odoo_inert`); t/unit/odoo/14 |
| OB1 (R1) | **The operator's actions**: `odoo-status` (the connection without its key, `has_secret` three-state, OOM's state, the installed operations), `odoo-secret-set`, `odoo-secret-clear` (POST-only), `odoo-calls` (the record). `manage_connectors`, on every lint the connector's four pass; no MCP twin - setting a credential is an operator act, and the agent's surface is slice E's | `Lazysite::Odoo::action_odoo_*`, `lib/Lazysite/ControlApi/Actions.pm`, `lazysite-manager-api.pl`; t/unit/odoo/15 |

Decisions taken here:

- **The endpoint's mode.** A verified session is `authenticated` where the binding
  admits that mode, and `public` everywhere else - the form handler's precedent
  ("public because anyone could have posted"). A signed-in account reaching a public
  binding as the public gains nothing an anonymous visitor lacks.
- **A page render is `public`, always,** and refuses a write: whatever a page binds is
  read on behalf of whoever loads it, and cached for the next.
- **The ledger moved**: t/lint/98 counts 112 token-reachable actions (was 108), with
  the four named and the reason.

## Slice R - the interface built 2026-10-12 (n474); the wiring STOPPED on a question

| Row | What | Where |
| --- | --- | --- |
| R4, Q3 | **The portable-type interface Q3 asked R to be built against.** Per field it reads `portable_type` (one of the data extension's seven), `values` (enum), `digits`/`places` (decimal), `string` (label), `required` - and NEVER Odoo's own `type`, so it cannot guess. A field without a portable type, with one the data extension does not know, or that fails the data extension's own descriptor check (`Lazysite::Data::Descriptor::load_descriptor`, so an Odoo column is held to a site's rules) is refused BY NAME with the reason. The key name is one constant (`$TYPE_KEY`) for OOM's answer to move | `Lazysite::Odoo::Fields::descriptor_fields`; t/unit/odoo/16 |
| R4 | **The parameter form**: one field per name the binding lets a request set, typed from the operation's declaration (OOM's `str`/`int`/`bool` to `text`/`integer`/`boolean`), required where the operation requires it without a default, carrying the default - and no field for the visitor key or a fixed value | `Lazysite::Odoo::Fields::form_fields`; t/unit/odoo/16 |

### Open: R-Q1 - where a report carries its rows' descriptors (STOPPED HERE)

Neither the rulings nor this filing settle it, and it is an interface between OOM's
operations and lazysite, so per the standing instruction the wiring stopped and the
question is recorded rather than decided.

The interface above turns descriptors into the data extension's fields. What it
needs from a REPORT is the rows and the descriptors that describe them, and an OOM
report is whatever its operation returns: `crm.select`'s, `crm.inspect`'s and a
future pack's each have their own shape. The descriptors come from OOM's
`Profile->descriptors($logical_model)` (section 8), which only the operation can
call - the logical model is the pack's knowledge, and lazysite naming one would break
*The rule that keeps it general-purpose*.

**Recommended:** a read operation meant for display returns `rows` (a list of
hashes) and `fields` (descriptors keyed by the row keys, with `portable_type`, as
`Profile->descriptors` gives them once OOM adds the portable type). Lazysite then:

1. hands TT `x.rows`, `x.fields` (drawn by `descriptor_fields`), `x.refused` and
   `x.form` (`form_fields`) beside the report for an `odoo:` page binding;
2. answers the same keys from the endpoint, so the data helper
   (`starter/assets/lazysite-data.js`) can fill a region from a binding as it fills
   one from a table (`data-ls-odoo="ID"` beside `data-ls-db`);
3. leaves a report without `fields` exactly as CU hands it over (unformatted), so
   nothing that works today changes.

The test pack's `shop.products` already returns that shape. The question is filed to
OOM with the options paper (its second section), since OOM decides what its
operations return. Answering it unblocks the wiring (about half of R's S-M), and
then E.

**ANSWERED 2026-10-13 by OOM: agreed as recommended**, in 0.02. A display read returns
`rows` (a list of hashes keyed by logical field) beside `fields` (the descriptors keyed the
same way, carrying `portable_type`), built with `Operation->fields_for($model, @fields)`;
`crm.export` does so with `inline=1`, and other reads adopt it as they are touched. A report
without `fields` is handed over as today. The key is `portable_type` (the first question,
answered as option A with the per-field override of B). The wiring described above is now
unblocked; it is not built in this re-filing. See section 8 of the filed specification and
`/srv/projects/odoo/oom/inbox/archive/2026-10-13-answered/2026-10-12-field-type-mapping-options-for-lazysite.md`.
## Slice R, the wiring - built 2026-10-13 (n581)

OOM answered R-Q1 as recommended (0.02; see the answer under *Open: R-Q1*), and the release
manager said on 2026-10-13 that the updated deb "can now start to be integrated".

| Row | What | Where |
| --- | --- | --- |
| R4, R-Q1 | **A display read's descriptors, drawn or refused by name.** `odoo_run`/`odoo-run` (and the page endpoint, which answers the same result) hand back `fields` (drawn by `descriptor_fields`, so each is held to the data extension's own descriptor check) and `refused` (`{ field, why }`) **beside** `report`, which stays as the operation returned it. The `odoo:` page binding hands TT the report with `fields` drawn, `refused` named and `rows` cut to the drawn columns: a value of a field lazysite refused to draw is never put on a page. A report whose `fields` is not a mapping of descriptors (none, or the list of names from before 0.02) reaches every door exactly as it did. A field title from Odoo is escaped like any other value | `Lazysite::Odoo::Fields::present`, `page_report`; `_run` in `lib/Lazysite/Odoo.pm`; `resolve_odoo`; t/unit/odoo/23 |

Not built: `x.form` (the parameter form, `form_fields`) on the page binding, and a
`data-ls-odoo` region in the browser data helper; the second is slice D's browser module.

## Slice B - built 2026-10-13 (n582), session-only

The release manager, 2026-10-13: "oom deb is now updated. still more to do, however it can
now start to be integrated." The coordinator took that as the go for the B-Q1 recommendation
(build B session-only first, then C and D). **Not built, and not ruled: an API-key strategy**
(an API key cannot start a session on Odoo 16 or 19). Not built: F2, the per-user path's
SECURITY.md and docs entries.

| Row | What | Where |
| --- | --- | --- |
| OA2, B | **A person signs in to Odoo through a page.** `POST {signin, login, password, visitor_token}` to the Odoo endpoint hands the password to OOM's session transport (`Odoo::Transport::Session`, OOM 0.03), once; the answer sets the session cookie and carries a name for a greeting. `POST {signout, visitor_token}` ends the session at Odoo and clears the cookie. A sign-in needs the visitor token (bound to the visitor cookie, `SameSite=Strict`), so a cross-site form cannot sign a victim in as someone else | `Lazysite::Odoo::sign_in`, `sign_out`; `lazysite-odoo.pl` (`_signin`, `_signout`); t/unit/odoo/25, 27 |
| OA4 | **The credential cookie** `lzs_odoo_session`: the session id, the time it was minted and a signature (HMAC, domain-separated, under the extension's own secret), so a value this server did not mint names nothing and the cookie ends in 12 hours whatever Odoo says; `HttpOnly`, `SameSite=Strict`, `Secure` over HTTPS, `Path` the endpoint's own (nothing else on the site receives it). The id is never in a URL, a body, a log or a record: a record names `session:<hash>` | `Lazysite::Odoo::Session`; t/unit/odoo/24, 27 |
| B | **A binding says whose credential runs it**: `credential: connection` (the default) or `session`. A session binding is authenticated mode only (no public, no schedule: there is no person), takes no callers (Odoo decides, for the person) and no visitor key, and **needs no connection-user key**. It runs through OOM's session context carrying the person's session as the cookie on every call | `Lazysite::Odoo::Binding::parse`, `context`, `session_binding`; t/unit/odoo/26 |
| B | **No fallback, ever.** Without a sign-in a session binding is refused (`signin-required`, 401) and the connection user is not asked; when Odoo has ended the session (or no longer accepts it) it is the same refusal, the cookie is cleared, and nothing is run in its place. The override capability is not a sign-in | `gate`, `_session_end`; t/unit/odoo/26, 27 |
| B | **No other door runs one**: the control API and MCP refuse it and do not list it; a form and the schedule refuse it by name; the `odoo:` page binding renders nothing for it (a page render is shared and cached, and what one person may see is never put in it). A session handed to a connection binding is ignored: what runs as the connection user is never recorded or owned as a person | `action_odoo_bindings`, `Handlers::_to_odoo`, `resolve_odoo`; t/unit/odoo/26 |
| B | **A plan made by a session is that session's**: owned by the hash of the session, applied only by it, approved by it (OOM's run registry), through the person's own session. A binding changed between the plan and the confirm does not change whose plan it is | `confirm`; t/unit/odoo/26 |
| B | **Two-factor accounts are refused by name** (`two-factor`, 403): Odoo accepts the password and opens no session. OOM names this case only in its message, which is read for it and nowhere else; a distinct fault is asked of OOM (below). A wrong password and an unknown login are told alike (`signin-refused`, 401) | `Lazysite::Odoo::Session::_classify`; t/unit/odoo/25 |
| B | **Sign-in attempts share the site's limiter**: `Auth::LoginRate`, counted before Odoo is asked, per address and per login (`odoo-ip=`, `odoo-login=` keys; the login by hash), five in five minutes; the sixth is `rate`, 429 | `Lazysite::Odoo::sign_in`; t/unit/odoo/27 |
| B | **The declared minimum is OOM 0.03** (the first with the session transport), in `owns.deps`, the gate's refusal, the tests and the docs | `plugins/odoo.pl`, `$OOM_MIN` |

**The password**, tested with a stand-in for HTTP under OOM's real transport that records every
post: it is in exactly one post (the authenticate route), in no URL or cookie, and in no result,
log, call record or audit line - including when a transport failure echoes the request body into
its own message. No text of an error from a sign-in is returned or logged, only its kind.

**Asked of OOM** (in the groups-read filing, n583): a distinct fault, or a field on the error,
for "the login was accepted and no session was opened", so that a two-factor account is not
recognised by reading OOM's message.

## Slice C - built 2026-10-13 (n583)

The identity half of the per-user path (OI1 to OI5, OT1, OT2), on the same release manager
go as slice B. **Identity is for presentation only, never authorisation (OI4):** nothing in
the engine reads it to permit anything; a call is run, or refused, on the person's session,
which Odoo checks.

| Row | What | Where |
| --- | --- | --- |
| OI1, OI2 | **The identity cookie** `lzs_odoo_identity`, a second cookie beside the credential: a name, language, time zone, the companies and the groups - never the session id, a user id, a login, an admin flag or a password. Signed under the extension's secret with a label of its own (a session cookie's signature cannot be replayed as an identity), so **a tampered identity is no identity** and the page renders as though nobody had signed in. `HttpOnly`, `SameSite=Lax` (a link from another site still greets the person; it carries nothing that can act), `Secure` over HTTPS | `Lazysite::Odoo::Identity`; t/unit/odoo/28 |
| OI3 | **Short, and refreshed on the next call after it ends.** `odoo_identity_ttl` (60 to 86400 seconds, default 900), dated inside the signature and as the cookie's `Max-Age`. A person with a session and no current identity cookie is asked of Odoo once, through their own session (one round trip), on the endpoint's next call; Odoo having ended the session clears both cookies and the call is told to sign in | `Lazysite::Odoo::identity_ttl`, `refresh_identity`, `Session::identity_of`; `_refresh_identity` in `lazysite-odoo.pl`; t/unit/odoo/29 |
| OT1, OT2 | **The TT namespace**: `tt_page_var:` with `me: odoo-identity:` gives `me.name`, `me.lang`, `me.tz`, `me.company_id`, `me.company_ids`, `me.groups`; every value HTML-escaped as a `db:` value is. A viewer with no cookie, an ended one or one that does not verify gets an empty mapping | `resolve_odoo_identity`; t/unit/odoo/30 |
| OI5 | **The cache, fail-closed, by SM857's own mechanism**: a page whose front matter holds an `odoo-identity:` binding is per-viewer (`$per_viewer`), so it is never read from or written to the page cache and is no-store on output; a binding the front-matter peek did not see (a variable outside the page's own front matter) is REFUSED rather than rendered, because what it read could be cached for everyone | `_peek_md` (`odoo_me`), `main`, `resolve_odoo_identity`; t/unit/odoo/30 |

**Groups: empty until OOM provides them.** OOM's session identity carries no groups, and the
read of them (`res.users`, under `groups_id` to 16 and `group_ids` on 19) is Odoo knowledge
that t/lint/240 keeps out of lazysite. `me.groups` is an empty list, filled from OOM when it
offers a read. Asked of OOM, with a distinct fault for a login that opened no session:
`/srv/projects/odoo/oom/inbox/2026-10-13-lazysite-asks-for-a-groups-read-and-a-no-session-fault.md`.

## Slice D - built 2026-10-13 (n584)

The browser half of the per-user path (OA6), and the last slice of the stack the release
manager's go covered. **Not built: F2.**

| Row | What | Where |
| --- | --- | --- |
| OA6 | **One browser module for the Odoo endpoint**, `/assets/lazysite-odoo.js`, so no page writes its own fetch: it fetches the tokens (`?csrf=1`) and sends the right one on every POST; on a stale token fetches fresh ones and **retries once, never twice**; on `signin-required` asks the person to sign in and **retries the call once** (so a wrong password cannot loop), or not at all when the caller says `prompt: false`; signs in and out; fills regions as text. `read`, `write`, `confirm`, `signIn`, `signOut`, `prompt`, `load`, `fill` on `window.LazysiteOdoo` | `starter/assets/lazysite-odoo.js`; t/unit/odoo/31 (under node, with a fake fetch that records every request) |
| OA6, outcome 10 | **The re-authentication prompt**: a dialog (`role=dialog`, `aria-modal`) with a login box and a password box (`type=password`, `autocomplete=current-password`, so a password manager fills it). The password is read, **the box is cleared before the answer arrives**, and it is in the body of one POST to the page's own endpoint and nowhere else: not a URL, a header, a later request, a cookie, storage, the console or an event. The session id is in an HttpOnly cookie this script cannot read; the script never holds it | `API.prompt`; t/unit/odoo/31 |
| OA6 | **Regions**: `data-ls-odoo="BINDING"` (request fields as `data-ls-odoo-<name>`) with a `<template>` row, as `data-ls-db` is; filled from the report's rows, **only for the fields the server drew** (`fields`; a field it refused is never filled) and **always as text** (`textContent`; nothing here builds markup from what Odoo returned). `data-ls-odoo-signin`, `data-ls-odoo-signout` and `data-ls-odoo-name` are the controls. A region that needs a sign-in keeps what it had and says `data-ls-odoo-state="signin-required"` unless it carries `data-ls-odoo-prompt` | `API.load`, `fill`; t/unit/odoo/31 |
| SM382, DP-3b | **Shipped as the data helper is**: injected only on a page whose rendered markup carries a region or control it binds, on both render paths, once, with a version query; on the exact engine-asset list so it resolves on a domain with its own content root | `lazysite-processor/layout.pm` (`_inject_odoo_helper`), `pipeline.pm` (`_is_engine_asset`); t/integration/174 |

The module holds no storage (`localStorage`, `sessionStorage`, `indexedDB`, `document.cookie`),
no `innerHTML`, no `eval` and no `console`: held against its source by t/unit/odoo/31.

## Slice E - built 2026-10-12 (n475)

| Row | What | Where |
| --- | --- | --- |
| R5, OM2 | **Every Odoo action has its MCP twin**, declared once on the action (SM943): `odoo_status`, `odoo_calls`, `odoo_secret_set`, `odoo_secret_clear` (`manage_connectors`, as on the control API; the key is never returned), and three new action pairs for running a bound operation - `odoo-bindings`/`odoo_bindings` (what this caller may run, with each one's fields), `odoo-run`/`odoo_run`, `odoo-confirm`/`odoo_confirm` | `lib/Lazysite/ControlApi/Actions.pm`, `lazysite-mcp.pl`, `lazysite-manager-api.pl`; t/unit/odoo/17, t/integration/171 |
| OB4, OM2 | **An operation reaches an agent through a binding**, as it reaches a page: gate `ALWAYS` on the action (as connector-call's), and the binding's modes, callers and caps decide inside `Lazysite::Odoo::call`; only mapped fields, checked as on every door. An agent is AUTHENTICATED and never a visitor: a binding that works on a visitor's key is neither listed nor run on this door | `action_odoo_bindings`, `action_odoo_run`, `action_odoo_confirm`; t/unit/odoo/17 |
| Q2, OM1 | **A grant runs as its own Odoo account when one is configured, else as the connection user.** `odoo-secret-set` with `grant` (the lazysite account) and `login` stores that account's key as the connection user's is (0600, its own file, named by a hash of the account); `odoo-status` lists each grant with `has_secret` three-state; a grant map that cannot be read refuses rather than falling back to the (likely wider) connection user; a configured grant without its key is refused, not run as the connection user. The control API's door stays the connection user's | `account_for_grant`, `_as_account`; t/unit/odoo/18, t/integration/171 |
| Forgery, instance-wide | The four key and status actions and their twins sit in t/unit/manager/226 and t/integration/114; `odoo-run` and `odoo-confirm` are recorded in t/lint/218 as not instance-wide (the binding decides, and running one changes no setting) | |

Not built in E, and why:

- **`manage_odoo` (OM3).** The Odoo actions stay under `manage_connectors`, the
  capability that already governs where site data goes and with what credential;
  a capability of its own costs the map, the grid, both gates and the docs and is
  a decision to take on its own.
- **One tool per registry operation, unbound.** Every operation reaches an agent
  through a binding instead, so the binding's callers, modes, caps and parameter
  rules (no json, list or path from a request) hold on this door too. An
  operation an operator wants an agent to run is bound for it.

### E-Q1 - what a binding's `domain:` limits (found 2026-10-12 on SM1051's rebase) - RULED AND BUILT

**E-Q1: as recommended, approved 2026-10-13.** The release manager's words,
relayed by the coordinator: "a binding with a `domain:` runs only for requests
on that domain (the page endpoint, the `odoo:` page binding, and
odoo-run/odoo_run, with the caller's own domain for MCP and the control API);
a binding without one stays instance-wide."

Built (branch n576) in the one function that sends, `Lazysite::Odoo::call`,
so every door meets it: a request on a host (the page endpoint, the `odoo:`
page binding, a form bound to the binding) runs a domain's binding only when
its host is that domain; the control API and MCP, which have no host, run it
only for a caller that reaches the domain by SM976's one rule (an unconfined
operator does, a grant confined elsewhere does not, a grant naming no scope
reaches none); the schedule names neither and runs what the operator
scheduled; a call that names neither outside the schedule is refused, never
assumed. The refusal is kind `wrong-domain` (403), recorded in the call record,
and `odoo-bindings`/`odoo_bindings` list only what the caller may run.
t/unit/odoo/19-20, t/integration/172.

The finding as filed:

SM1051 gave every handler an optional `domain:`, and an `odoo` binding is a handler,
so it takes one. What the domain governs today is what SM1051 built for every
handler type: who may create, change and delete the binding (that domain's editors)
and which forms may bind it. It does **not** limit where the binding RUNS: the page
endpoint (`lazysite-odoo.pl`), an `odoo:` page binding, `odoo-run` and `odoo_run`
find a binding by id on any domain the instance serves. A binding an operator
meant for one site's shop can therefore be run from another site's pages or by an
agent confined to another domain, within the binding's own modes, callers and caps.

Neither the rulings nor this filing settle whether it should. **Recommended:** a
binding with `domain:` runs only for a request on that domain (the page endpoint
and page binding by the request's host, a confined caller by its reach); a binding
without one stays instance-wide, as it is for every other handler type.

Once OOM answers R-Q1 (where a report carries its rows' descriptors), `odoo_run`
and `odoo-run` hand back `fields` (drawn by `descriptor_fields`) and `refused` beside
`report`, as the page binding will.

## F1 - built 2026-10-13 (n577)

| Row | What | Where |
| --- | --- | --- |
| F1 | **SECURITY.md**: four operator entries - the connection user's key, the visitor key, the anonymous write path and its caps, a grant's own Odoo account | `SECURITY.md` |
| F1 | **FEATURES.md**: the extension's section (beside plugins and handlers) and one line in *The security model in one place* | `docs/FEATURES.md` |
| F1 | **The extension's page**, `/docs/odoo`: what it needs, the connection, the key, bindings, where a binding runs, the anonymous write path, a grant's account, domains, the call record, refusals, what is not built; listed in the docs index | `starter/docs/odoo.md`, `starter/docs/index.md` |

# What this is for, and the work - RESTATED 2026-10-01

This replaces a section I wrote earlier the same day. **I had it wrong, and the
correction matters more than the error**: I read a description of future scope as a
programme to build, and wrote SM747 up as a "headless ERP programme". It is not one.

**What the release manager actually said, and what follows from it:**

- The functions named - invoicing, sales, quotes, timesheets, expenses, stock
  movement, manufacturing, visitor registrations - are **future scope, shown to
  convey where this leads. They are not a build.** Whether any of them exists is an
  outcome a lazysite app might or might not implement.
- **The apps are the site agent's work, guided by demand on the day.** Not planned
  here, not sized here, and not this filing's business.
- **What is needed here is a general-purpose Odoo interface, as originally
  described, that apps can be built WITH.** A facility, not an application.

So this filing's scope is unchanged from its original shape. What changed is that the
reason for it is now evidenced rather than asserted.

## Why a facility, from three attempts that each stopped short

| Attempt | What it proved |
| --- | --- |
| **jpm stock correction** - Claude read the lazysite database and transferred to Odoo by hand | The agent WAS the API. It works once and does not scale: every correction needs a person-shaped process, and nothing a visitor does can reach Odoo at all |
| **The agent CRM for opendigital** - Claude talks to Odoo through OOM | Better: one way of speaking to Odoo, with scope and audit. Still agent-driven, so **still no real-time UI** - a person waits for an agent rather than using a page |
| **Pocket portal** - built to bridge exactly that gap | A bridge works and is **heavy to adapt**. One per app is the bespoke-connector sprawl in another form |

The pattern is the same each time: the capability exists, and **the engine offers no
way for an ordinary page to use it**, so every app improvises a bridge. That is the
hole this filing fills - and it is why the measure of success is "an app could be
built on this without inventing a transport", not "Odoo is integrated".

## The rule that keeps it general-purpose

> **Lazysite holds no Odoo knowledge.** Model names, field names, domains,
> `execute_kw`, RPC shapes and the ERP's semantics live in OOM's operation packs.
> Lazysite names an operation, binds its parameters, renders the descriptors it is
> handed, and presents a plan for confirmation.

This is what makes it a facility rather than a connector: an app that needs invoices
needs an operation pack, not engine work. It is **checkable** - a lint refusing any
Odoo model name, `execute_kw` or Odoo RPC endpoint in lazysite code - and the gate
lands with the first code, since there is nothing to check today.

And the rule already in *Scope control* becomes more load-bearing as apps multiply:
a lazysite interface narrows **what is asked for**, never what came back. Odoo's own
ACLs are the bound, under the user's own credential (X4-b). A page that filters is a
page that can be wrong in the direction nobody notices.

# The plan, SIZED 2026-10-02 against the machinery it would reuse

> **Re-planned 2026-10-12 under the ruling** - see *The slices, re-planned
> 2026-10-12* below. The two subsections that follow ("there is no cheap read-first
> slice"; "the real blocker is a ruling") were right against the text as it stood and
> are kept as the reasoning the ruling answered: R1 permits the site-level account,
> and R2 takes the ruling they asked for.

Five stages. **Each one ends somewhere an app could be built**, which is the test of
whether a stage is worth cutting at. Sizes are mine, calibrated on SM929 from
2026-10-01 - one definition adopted at 44 call sites, two lints, three tests and docs
came to 34 files and about 1,540 lines, which is one working session.

## First, a correction: the slices cannot be ordered the way I first wrote them

An earlier version of this section proposed starting with a **site-level Odoo
account**, so that a read-only page could be built before the per-user credential
work. **This filing's own required outcomes forbid it**, and I had not read them
against my own plan:

- **outcome 2**: every operation is attributed in Odoo to *that user*, **not to a
  shared integration account**;
- **outcome 4**: no Odoo credential is stored anywhere on the lazysite server, in any
  file, table, log or cache;
- **OB1**: no shared service account for the user-facing path - a service account is
  permitted only for the MCP surface (OM1), on the mode-600 convention.

So **there is no cheap read-first slice.** The same pass found a second invention of
mine: I described stage 2 as "a page surface rendering an operation's result", but the
TT surface this filing asks for (OT1, OT2) is **identity exposure for presentation**.
"Render an operation's result in a page" is not a requirement row at all.

## And the real blocker is a ruling, not a build

OA2 is the session strategy. OA3's *preferred* form uses the API key **once** to
obtain a session and discards it. Both need `/web/session/authenticate` +
`/web/dataset/call_kw` - **the transport OOM does not have**, whose `Credential`
refuses `session` and `cookie` by name (see the filed specification, section 7).

OA3's stated fallback is to carry the key in the cookie, and OA3 says in its own words
that this "is a materially different risk and must not be silently adopted".

> **Everything per-user waits on one answer: carry the key with the risk documented,
> or wait for OOM to gain the session transport.** That is a ruling, and until it is
> taken, slices B, C and D below cannot start.

**UPDATE 2026-10-13: OOM built it.** `Odoo::Transport::Session` shipped in 0.03 and is live on
Odoo 16 and 19 (section 7 of the filed specification); the blocker below is gone, and the
ruling it asked for is narrower than this section says - see *B-Q1* near the end, which
also records that an API key cannot start a session on either series, so OA3's preferred
form does not exist.

And the transport belongs in **OOM**, not here: endpoint paths and payload shapes are
Odoo knowledge, which *What this is for* puts in the operation packs. The
specification says "for the extension to implement"; that would put Odoo RPC knowledge
in lazysite and contradict the rule. **Resolving that is part of stage 0.**

## What the existing machinery actually gives, measured

| Need | What exists | Cost |
| --- | --- | --- |
| OB4 mode gating | `Lazysite::Egress` (187 lines); `may_invoke` is called from exactly one site, `Connectors::may_call`, and `call()` invokes it **before anything is sent** so all three of its callers are gated whether they remember or not. Its comments already name `proxy` | **nil** - and copy the placement, not just the call |
| OA5 CSRF on the lazysite leg | `Auth::Session::generate_csrf_token` / `verify_csrf_token`, with manager-api's token endpoint and its three accepted carriers | **wiring only** |
| OI5 cache safety | `nocache` is peeked by `_peek_md` and bypasses `try_serve_cache` entirely; `query_params` already skips the cache read when a declared param is present; a `url:`-backed page is marked live in its `.deps` record | **S** - the "fail closed on an identity binding" half is another key in the same peek, not new machinery |
| Outcome 8's two-session proof | `t/lib/ManagerSession.pm` (180 lines): `add_user`, `cookie_for`, `csrf_for`, `call` | **nil** |
| Plan-then-confirm (when writes arrive) | Three precedents, the best being `Data::Tables::import_rows` - validate-and-diff then commit **through one function selected by `apply`**, so "the preview and the action cannot disagree". Also `data-migrate-plan`/`data-migrate`, and `group-reset` where the dry run's diff *is* the confirmation | **nil as design** |
| OB1 config and the store shape | `Manager::Connectors` (979 lines): secrets in a separate 0600 file never returned, `has_secret` as a three-state answer, modes, callers, a per-call JSONL log, age pruning | **copy the pattern** |

**Two rows I first called free and are not:**

- **The HTTP client.** `Lazysite::Fetch` (103 lines) cannot serve Odoo: GET only, no
  headers, no body, no credential, returns the decoded body or nothing - and its SSRF
  guard **refuses private ranges**, which is where an internal Odoo lives. The
  connector already met this and builds its own agent inline in `call()`, deliberately
  not running `is_safe_url` and saying why. So OB6's "the connector's transport
  discipline, reused as behaviour" means **extracting that agent from a 979-line
  module that 53 test files mention** - M to L, not free. Neither client *asserts* TLS
  verification; both inherit LWP's default, which an environment variable can change,
  so the extension should assert it rather than inherit it.
- **The rate cap.** `Egress::within_caps` exists for this shape and **the connector
  does not use it**: it recomputes a rolling hour by scanning `calls.jsonl` on every
  call, and refuses if the log is unreadable. OB5 wants a cap **per identity**, which
  is a different key and a per-request file scan on a page-rate surface. A design
  question, not a copy.

**And the extension point is not where I assumed.** A connector has **no `type`
field**; `format` is `json|slack` in a regex with four touch points. The real registry
is handler types - `@TYPE_ORDER = qw(smtp file table connector)`, each with its own
schema. An Odoo endpoint is naturally **a new handler type**, not a connector format.

## The slices, re-planned 2026-10-12 under the ruling

**The 2026-10-02 table, as history.** It had six slices: A (endpoint config, proxy
skeleton, fault kinds, the audit record, mode gating) buildable but demonstrating
only refusals; B (one per-user credential strategy) blocked on a ruling; C (identity
cookie, TT exposure, cache fail-closed) and D (browser data module, CSRF, re-auth
prompt) after B; E (MCP under the agent's own account) independent of B; F (docs and
the boundary lint) last. The first page capability was A + B + C + D, four M slices.
R1 removes B from the front of that queue: the connection user gives a page Odoo
facts with nobody signed in to Odoo, so the first page capability no longer needs
the per-user legs.

Sizes keep the 2026-10-02 calibration (one working session is about 34 files and
1,540 lines, from SM929). **Building** needs nothing from anybody: the engine works
against the OOM tree on a library path, and OOM's `Odoo::Ops::Context` takes an
injected transport for tests (`Context.pm:49`), so `t/unit/odoo/` needs no Odoo.
**Shipping** waits on the deb carrying the Ops layer (R3, OB7).

| Order | Slice | What it is | Size | Waits on |
| --- | --- | --- | --- | --- |
| 1 | **A** | Endpoint config (`odoo_url`, `odoo_db`, `odoo_timeout`) as a new handler type; OOM's fault kinds and categories mapped to `{ ok: 0, error, kind }` with OB5's distinct kinds, the fault text logged and never returned; the OB8 audit record; mode gating through `Lazysite::Egress`; X4-a's URL rule; **the boundary lint** from *The rule that keeps it general-purpose*, which lands with the first code | **M** | nothing to build |
| 2 | **CU** (new) | **The connection user.** Its secret store (OB1 as amended: 0600, written alone, never returned, `has_secret` three-state, set and clear actions); an OOM context per call with the key and `actor` = the lazysite account that triggered it; operations found through `Odoo::Ops::Registry`; a page binding that names an operation, binds its parameters and declares its SM579 modes; a read operation's report handed to TT; a write operation's plan shown as its buckets and applied on confirm through `Odoo::Ops::Runner`, the confirm carrying the manager-api CSRF token (OA5, brought forward from D); plans and journals in the extension's private store, never the docroot, pruned by age | **L** | nothing to build; Q1 before any unattended apply |
| 3 | **R** (new) | **Shared rendering** (R4): an operation's rows and its parameter form drawn by the data extension's table and form rendering, from OOM's `Profile` descriptors (`Profile.pm:211-221`) | **S-M** | CU; Q3 decides where the type mapping lives |
| 4 | **E** | **MCP, all operations** (R5): one tool per registry operation, generated from its declaration; list and describe; one apply-plan tool; under the connection user (OM1 as amended), the `manage_odoo` capability (OM3), lazysite-side audit | **M** | CU (shares its runner and store); Q2 |
| 5 | **F1** | SECURITY.md (the outbound interface, and the connection user's stored credential as a threat delta), FEATURES.md (OB9), the extension's page including the onchange obligation (spec section 10) | **S** | A, CU, E |
| later | **B** | One per-user credential strategy end to end: acquire, carry, replay, clear, logout, outcome 10's re-authentication prompt | **M** | OOM's session transport (R2) - **shipped 2026-10-13, 0.03**; B-Q1 |
| later | **C** | Identity cookie (OI1-OI3), signed and TTL'd; TT exposure (OT1, OT2); the cache fail-closed (OI5) | **M** | B |
| later | **D** | The shared browser data module (OA6) and the re-authentication prompt in the UI; CSRF has moved to CU | **S-M** | B |
| later | **F2** | The per-user path's SECURITY.md and docs entries | **S** | B, C, D |

**The first demonstrable page capability is A + CU + R**: a page lists Odoo facts
from a named read operation under the connection user, drawn as a data table, and a
page whose operation writes shows the plan's buckets and applies them when a signed-in
lazysite user confirms. M + L + S-M, about three sessions. A + CU alone already
demonstrates it with the report unformatted; R is what makes it an app rather than a
dump. **E follows at about one session** and is the cut that answers R5. B, C and D
were to start when OOM shipped the session transport; it shipped 2026-10-13 (0.03).
Whether to start them is the release manager's, asked as B-Q1; the per-user path is
the original A + B + C + D minus the work CU has already done.

## Two findings from the measurement, neither urgent

- **Two retention numbers for one fact.** `connector_call_retention_days` (default 90)
  prunes the call log on every append, while `$KEEP_CALLS_DAYS = 30` is used only by
  `sweep()`. One of them is wrong about how long a call record lives.
- **OB8's record does not exist in any form yet.** `audit_log` is never called from
  `Manager::Connectors`; the audit trail records at *delivery* level - `act='deliver'`,
  naming the handler rather than the connector or the `call_id`. One record per proxied
  call naming model, method and mode is new work, and `audit_log`'s seven positional
  fields have no obvious room for it.

**What is NOT in the plan:** any of the ERP functions named earlier. They are what apps
do with this, built by the site agent when somebody asks.

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
   proxied call. *(Amended 2026-10-12, R1: holds for every user's credential;
   the connection user's is the one stored credential - see* Ruled 2026-10-12*.)*
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
| OB1 | Per-site Odoo connection in the extension's config: `odoo_url`, `odoo_db`, `odoo_strategies`, `odoo_timeout`, `odoo_identity_ttl`. No shared service account and no stored credential for the user-facing path. If the MCP surface needs a service account (OM1) it follows the mode-600 credentials-file convention and is never displayed. **Amended 2026-10-12 (R1):** the config may hold a connection user, its API key stored as connector secrets are - see *Ruled 2026-10-12*. |
| OB2 | **Scoped mode**: a declared allowlist of models and permitted methods per app. Refused by lazysite before the call leaves. The default for a purpose-built app. (P1's "named queries" live here - a named query is a scoped allowlist with bound parameters.) |
| OB3 | **General mode**: no model or method allowlist; bounded by the user's own Odoo permissions exactly as Odoo's web client is. An allowlist here would mean enumerating Odoo badly and forever. **Applies only to a call made with the user's own credential** - see *Reconciling*. |
| OB4 | Caller gating is lazysite's: the proxy is reached by a lazysite session on an app page (mode 2 of [[SM579]]), and the call carries the Odoo credential from the cookie. No scheduled and no public mode for the per-user proxy. **Amended 2026-10-12 (R1):** the connection-user path takes SM579's three modes, declared per binding. **Ruled 2026-10-12 (Q1):** a public or scheduled binding may apply a write operation unattended when it declares `apply: immediate`, under the controls in *Ruled 2026-10-12 (Q1-Q3)*. |
| OB5 | A per-call timeout (`odoo_timeout`); a rate cap per identity; Odoo faults mapped to lazysite's `{ ok: 0, error, kind }` shape with **distinct kinds** for session-expired, invalid-credential, odoo-access-refused and transport-failure. The fault's own text is logged, never returned verbatim (three leaks in three passes taught this - [[SM713]], [[SM738]], [[SM739]]; `t/lint/112` checks the source). **2026-10-12 (Q1):** the per-identity cap is per visitor key on the public path and per account on the authenticated path, with a per-binding cap beside it. |
| OB6 | Transport discipline, the connector's reused as behaviour: no redirect following - a 3xx is a named refusal, because the credential would travel with it; a response size cap sized for Odoo reads and configurable; TLS peer verification on; `https://` to any host and `http://` only to loopback. **X4-a settled this 2026-09-28: no plain `http://` to an RFC1918 Odoo** - `https://` to a private hostname, which the connector rule already permits, is what "internal network" means here. |
| OB7 | OOM is delivered as a versioned package (`libodoo-oom-perl`); the extension declares a minimum version in `owns.deps` and never carries a copy of the code. Settled by the release manager 2026-09-03. **MEASURED 2026-10-01: THE PACKAGE THAT EXISTS CANNOT SATISFY THIS.** `/srv/projects/packages/libodoo-oom-perl_0.01_all.deb` (2026-09-03, 26,972 bytes) carries **8 modules - the mapper layer only**: Client, Commands, Error, Model, Record, RecordSet and the two transports. The OOM tree has **41**, and the 33 it is missing are the whole `Odoo::Ops::*` layer the specification's layer table says the extension consumes - including `Odoo::Ops::Guard`, **which IS the scoped mode.** Installing 0.01 would therefore give the engine a mapper with no scope guard: general mode only, which X4-b permits solely with the user's own credential, so the named-query mode this filing is built around would be unavailable. `Odoo/Transport.pm` itself is also absent. A **0.02 carrying both layers is a prerequisite of OP-25**, not a later tidy. **Ruled 2026-10-12 (R3):** the deb will be updated; what it must carry is filed to OOM's inbox. **Delivered 2026-10-13:** `/srv/projects/packages/` holds 0.02 to 0.09; 0.02 carries the Ops layer (42 modules) and 0.09 has 63, including `Odoo::Transport::Session`, `Odoo::Transport::JSON2`, `Odoo::Portable`, `Odoo::Ops::Runs`, `Odoo::Ops::Core::User`, `Core::Attach`, `Core::Fetch` and `Core::Doctor`. It is not installed on this host (`dpkg -s libodoo-oom-perl`). **What 0.07 to 0.09 change for the extension (2026-10-13, from the filed specification and OOM's changelog):** (1) **the run registry (`Odoo::Ops::Runs`)**: `Runner->apply` now refuses a plan nobody approved (`unapproved`), one approved as another plan (`approval-stale`) or one past its time (`expired`, `plan_ttl`, default 24 hours), unless the config says `approval = none` - the extension therefore records its own approval, by the plan's maker or by an `apply: immediate` binding, before it applies, and does not turn the gate off (see *OOM's approval gate*); (2) **revert and resume**: a `custom` change may say how it is undone, `revert_plan` and `resume_plan` build new plans, and a run over many rows can continue past a failure - the extension exposes none of these, and a plan it makes is applied once; (3) **`core.user`, `core.attach`, `core.fetch`**: named operations for users (including a portal user made through Odoo's portal wizard, and an API key minted as the user), attachments in and out of any record - they reach a page or an agent only through a binding, as every operation does, and what they may do is the connection user's rights in Odoo; (4) **`Odoo::Transport::JSON2`** for series 19 (`/json/2`, the API key as a Bearer header): selected by OOM's `transport` config key, which the extension does not set, so it uses the default transport; (5) **`oom-ops doctor`**, an OOM operation (config, key file mode, TLS, authentication and groups, write readiness) that is OOM's to run and is not wired here. |
| OB8 | One audit record per proxied call on the lazysite side: actor (lazysite account if any), Odoo login, model, method, mode, outcome state (answered / unanswered / refused / odoo-fault), never the payload and never the credential. Written the way connectors write theirs. **Amended 2026-10-12 (R1):** for a connection-user call the actor is the lazysite account (or mode and binding) that triggered it. **2026-10-12 (Q1):** a public call's actor is `visitor`, recorded with a hash of the visitor key and the IP. |
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
| OM1 | An agent uses ITS OWN Odoo account, configured by the operator - never a human user's credential and never impersonation. Attribution in Odoo's audit trail stays truthful; the agent's Odoo permissions are what bound it. **2026-10-12 (R1):** met by the connection user; Q2 asks whether MCP gets its own. **Ruled 2026-10-12 (Q2):** the connection user by default, or an Odoo account configured for the MCP grant, stored as the connection user's key is. |
| OM2 | Tools follow the connector's naming and error conventions. The exact set is settled when the mapper spec is merged; at minimum: introspect models and fields, read, write, all within the agent's own permissions. **Ruled 2026-10-12 (R5): all operations** - every operation the registry lists is a tool. |
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
   integration account. *(Amended 2026-10-12, R1: on the per-user path. A
   connection-user operation is attributed in Odoo to the connection user and in
   lazysite's audit to the lazysite account or mode that triggered it.)*
3. An operation the user is not permitted to perform is refused by Odoo, and
   the refusal is distinguishable in the response from a transport failure.
4. No Odoo credential is stored anywhere on the lazysite server, in any file,
   table, log or cache. Demonstrated by inspection. *(Amended 2026-10-12, R1: no
   user's credential. The connection user's key is in the extension's 0600 secret
   file and nowhere else, and the inspection proves the second half too.)*
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
  or "for performance". *(2026-10-12, R1: user credentials. The connection user is
  the ruled exception, on OB1's amended terms only.)*
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

# The mapper specification, FILED 2026-10-01

The seam this filing held open is closed. The specification was written in the OOM
tree from what has been built and exercised against Odoo rather than in advance of
it, and the release manager directed on 2026-10-01 that it be filed here.

**Provenance, and the reason it is recorded rather than trusted:**

| | |
| --- | --- |
| Source | `t/vendor/oom/docs/MAPPER-SPEC.md` |
| Written | 2026-09-28, status DRAFT, "growing with use"; RE-FILED 2026-10-13 from OOM's working tree as of 6844779 (2026-10-13), after OOM's 0.02 to 0.09; that text is exactly the copy the 0.09 deb installs, and it is the copy lazysite now VENDORS (t/vendor/oom, OOM commit 2edc3db, SM1081) |
| sha256 at filing | `8231bb2f29b5c50a3917fa4aa869f848d6d4ad1febe7d0582e2d3f2d15c2c2bc` |
| Living copy | stays in the OOM tree - that project owns it, and its working tree may be AHEAD of the vendored copy without any failure here |
| Re-file when | a newer OOM is adopted: `tools/vendor-oom.sh` refreshes `t/vendor/oom` and this section is updated from it in the SAME commit (t/lint/207 enforces it, t/lint/261 holds the snapshot to its MANIFEST) |
| Drift gate | `t/lint/207-the-filed-mapper-spec-matches-its-source.t` |

A second copy of a document that is still being edited elsewhere is how two
descriptions of one thing come to disagree, and this filing has already been stale
twice (see *Sequencing*). So the hash is recorded and a lint compares it.

**The gate follows a pinned snapshot, not OOM's working tree (SM1081, 2026-10-14).** The
lint first compared the filing with OOM's working tree, which moved three times on
2026-10-13 and 14 and failed the release gate each time with nothing wrong in lazysite.
It now compares with the copy of the spec inside this repository,
`t/vendor/oom/docs/MAPPER-SPEC.md`, which is always present, so the "source not
readable" skip is gone. OOM's tree is ahead of it (0.10: `session_groups`, the no-session
fault) and is adopted by a reviewable commit when the release manager decides. The gate
follows the released spec. B, C and D's blockers, R-Q1 and the rest of this filing are
unchanged by it.

**Every claim in the spec says what it rests on**, and that grading is the most
useful thing in it: **tested** (offline suite against a fake Odoo), **source** (read
from the Odoo 16.0 source), **live** (verified against a named instance and series),
or **design** (decided, not yet exercised).

## 1. Layers

| Layer | Modules | Responsibility |
| --- | --- | --- |
| Mapper | `Odoo::Client`, `Model`, `Record(Set)`, `Commands`, `Transport::*`, `Error` | RPC, introspection, read/write, x2many grammar, fault classes |
| Operations | `Odoo::Ops::*` | named operations, scope guard, profiles, plan/apply/journal/revert, audit |
| Function packs | `Odoo::Ops::CRM::*`, `Odoo::Ops::Comms::*` | the business operations |

The extension consumes the mapper **and the operations layer** as the
`libodoo-oom-perl` package (OB7), never a copy. **That was a requirement on the
package, which the 0.01 deb did not meet (OB7); the debs 0.02 to 0.09 do.**

## 2. Transport discipline (OB6) - tested

- No redirect is followed; a 3xx dies as kind `refused` (code `redirect`) naming the
  target. HTTP::Tiny follows a 303 even on POST by default; switched off.
- `max_response_bytes` caps an answer; over it dies `refused` (`oversize`), not
  retried.
- TLS verification on. Only kind `transport` is retried.

This is OB6 satisfied in the layer below the engine, which is why OB6's engine-side
work came off the build on 2026-09-28.

## 3. Fault kinds (OB5) - tested, wire shapes from source

`Odoo::Error->fault_category`: `access` (AccessError), `credential` (AccessDenied),
`session` (SessionExpiredException), `validation` (ValidationError, UserError),
`missing` (MissingError), `other`. JSON-RPC carries the class in `error.data.name`;
**XML-RPC only in the traceback, from which it is recovered.** Plus kinds
`transport`, `refused`, `config`, `usage`.

## 4. Named operations and scope (OB2, OM2) - tested

An operation declares `op_name`, `params` (typed, validated, unknown names
refused), and `read_scope` / `write_scope` as `{model => [methods]}`.
`Odoo::Ops::Guard` wraps the transport and refuses any `execute_kw` outside the
running operation's scope **before it leaves**. Base scope is `common.*`,
`fields_get` on any model, `res.users.read`.

**This is SM747's scoped mode, and it already exists.** A named query is an
operation with a declared scope and bound params. General mode (OB3) is the
*absence* of the guard, and applies only with the user's own credential - which is
exactly the division X4-b ruled.

## 5. Plan / apply - tested

Write operations only plan. A plan is JSON: changes (create, write, unlink, call,
custom, skip, hold) each in a named bucket with the before-image it saw; buckets sum
to the input; sealed by fingerprint; bound to an instance; `applied: 0`. Apply
refuses read-only configs, other instances, edited plans, re-applies and stale
before-images; reads every write back; journals each change as it happens;
`applied: 1`. Revert is itself a plan.

**A lazysite app presents the plan's buckets as the preview and calls apply on
confirm** - so the preview-then-confirm shape the briefing asked for is the mapper's
own, not something the engine has to invent.

## 6. Audit (OB8) - tested

One record per RPC call, fixed fields only: `ts actor login service model method op
outcome fault_category ms`. **The sink refuses any other key**, so a payload or a
credential cannot be added by accident. OM3's lazysite-side audit sits beside this,
not instead of it.

## 7. Credential strategies (OA1) - session shipped (0.03), live on 19

`Odoo::Ops::Credential->resolve($config)` returns what the client
needs. `file` (API key file, mode 600 enforced) ships. `session`
ships in 0.03: the config carries a run-time session value (never a
file entry: `Config->load` refuses it), and the context speaks
`Odoo::Transport::Session` as that user. `cookie` stays a reserved
name that refuses: a consumer replaying a per-user credential from a
cookie turns it into a session first.

The session transport: one round trip to `/web/session/authenticate`
(db, login, password) returns the identity and a session id the
caller carries; every later call goes through
`/web/dataset/call_kw/<model>/<method>` with the session cookie,
presented as `call('object','execute_kw', ...)` so the Guard and
everything above it are transport-blind; `/web/session/destroy` on
sign-out; `/web/webclient/version_info` for `common.version`;
`/web/session/get_session_info` once for a resumed session. Expired
or destroyed: category `session` (and the transport forgets the id);
refused login: category `credential`; neither retried. Two-factor
users cannot complete a password session login (Odoo refuses). Groups
are not in the identity: read `res.users` (in the Guard's base scope),
minding the field name per series (`groups_id` to 16, `group_ids` on
19).

## 8. Field descriptors - tested (shape and portable type), live on 19

`Profile->descriptor($model, $field)` returns the server's metadata
under the logical name: `type string help required readonly store
relation relation_field selection`, plus `name` (physical), plus a
**portable reading of the type** for consumers that hold no Odoo
knowledge (0.02, `Odoo::Portable`): `portable_type` is one of `text
integer decimal boolean date datetime enum`; an enum carries `values`
(selection keys) and `labels`; a decimal carries `places` (and
`digits`) when the server states them. Odoo types with no single
reading carry no `portable_type`: many2one, html, binary, the x2many
types, reference, json, properties. A profile overrides per field with
the map form `logical: { name: physical, portable_type: text }` (a
many2one shown as its label); an unknown portable type is refused at
load. A consumer that meets a field without `portable_type` refuses to
render it by name - the mapping never lives on the consumer's side.

**Display reads** return `rows` (a list of hashes keyed by logical
field) beside `fields` (those descriptors keyed the same way), built
with `Operation->fields_for($logical_model, @fields)`. `crm.export`
does so with `inline=1`; its report keys are `count`, `file`,
`fields`, `rows`.

## 9. Series - tested (mechanism), live pending

Logical->physical profiles per pack and series, validated against live
`fields_get`; nearest-lower fallback with a warning. Behaviour beyond
names (e.g. sending mail) dispatches per series and refuses on an
unprobed one.

| Behaviour | 16 | 17 | 18 | 19 | 20 |
|---|---|---|---|---|---|
| crm profile | live 2026-09-28 (16.0-20250909): 42/42 fields, restricted CRM user; live 2026-10-13 (local cluster): 43/43 | not probed | live 2026-10-13: the 16 profile validates 43/43 (loader warns it is the 16 file) | live 2026-10-13: the 16 profile misses `crm.lead.mobile` (removed); `profiles/crm/19.yaml` maps it to `~` and validates 42/42 | - |
| `crm.inspect` and `crm.export` (counts by type/stage/tag/source/team/salesperson; rows + descriptors with portable types, no faults) | live 2026-10-13: 9 leads, 31 fields | not probed | live 2026-10-13: 6 leads, 31 fields | live 2026-10-13: 12 leads, 30 fields (no `mobile`); same run over json2: inspect ok | - |
| crm profile | live 2026-09-28 (16.0-20250909): 42/42 fields, restricted CRM user; live 2026-10-13 on the local 16: 9 models, 50 fields with `res.partner` mapped (`core.check`) | 16 file validates live (TEST-RESULTS, series 17 and 18) | live 2026-10-13: `profiles/crm/18.yaml`, 9 models, 50 fields | live 2026-10-13: `profiles/crm/19.yaml`, 9 models, 49 fields; `crm.lead.mobile` is absent on 19 (the 16 file named it) | - |
| `/jsonrpc` + `execute_kw`, API-key auth | live (jpm clone; local cluster 16.0 2026-10-13) | - | - | live 2026-10-13 (19.0, odoo-cluster) | - |
| `copy` answers a list of ids (multi-record since 18) | single id | - | - | live 2026-10-13: `Model->copy` returns one id for one id on every series | - |
| html field written as plain text reads back wrapped in `<p>` | verbatim | - | - | live 2026-10-13 | - |
| `res.partner.date` | present | - | - | absent, live 2026-10-13 | - |
| read/write/unlink/x2m commands/verify_credentials (t/98, t/99) | live (jpm clone; local cluster 16.0 2026-10-13) | - | - | live 2026-10-13 | - |
| a pallet moved into `WH/Output` by a validated internal transfer reads fully reserved | not seen: the relocate-and-return test ran clean (t/94, 2026-10-13) | not probed | not probed | observed 2026-10-13 (t/94): `reserved_quantity` 8 of 8 after the transfer; cause not isolated | - |
| the opposite transfer of a transfer that left a package split is refused (a package in two places) | refusal reproduced offline only (t/33, the stock fixture); the live mirror undo was not run in this piece; the relocate undo applied live 2026-10-13 (t/94) | not probed | not probed | the relocate undo applied live 2026-10-13 (t/94); the mirror undo not run live | - |
| session transport: authenticate, call_kw, identity, destroy, expiry (t/97) | live 2026-10-13: 17/17 | - | - | live 2026-10-13: 17/17 | - |
| sale: basket as draft order, lines by x2m commands, action_confirm, invoice via `sale.advance.payment.inv` + `create_invoices`, `action_post`, payment via `account.payment.register` + `action_create_payments` (t/95) | live 2026-10-13: paid | - | - | live 2026-10-13: paid | - |
| chart of accounts on a fresh db | `l10n_generic_coa` is a module: `ir.module.module.button_immediate_install` over RPC loads the chart for a company without one; `res.company.chart_template_id` says so (live 2026-10-13) | - | - | `account.chart.template.try_loading('generic_coa', company=)`; `res.company.chart_template` (live 2026-10-13) | - |
| crm.lead create + ir.attachment (image) + message_post note (t/95) | live 2026-10-13 | - | - | live 2026-10-13 | - |
| hr.expense submit | report: `hr.expense.sheet` create + `action_submit_sheet`, state `submit` (live 2026-10-13) | - | - | no sheet: `hr.expense.action_submit`, result in `approval_state` (auto-approved when the submitter is the approver), live 2026-10-13 | - |
| portal user writes their own res.partner over RPC | REFUSED (access) live 2026-10-13, same pattern | - | - | REFUSED (access) live 2026-10-13: the app verifies the session identity (`partner_id`) and applies through its service connection, as Odoo's portal controller does | - |
| portal user reads crm.lead | refused (access), live | - | - | refused (access), live | - |
| API key at `common.authenticate` (RPC) | live 2026-10-13: ACCEPTED (key minted as the user; an earlier probe minted as the superuser was refused and misreported) | - | - | live 2026-10-13: ACCEPTED (same correction) | - |
| API key accepted at `/web/session/authenticate` | live 2026-10-13: REFUSED (credential) - a web session needs the password; "key once, then session" does not exist | - | - | live 2026-10-13: REFUSED (credential) | - |
| module enable over RPC (`button_immediate_install`), `ir.config_parameter.set_param`, `res.config.settings` create + `execute` | live 2026-10-13 (l10n_generic_coa) | - | - | live 2026-10-13 (survey; group_multi_currency; a parameter) | - |
| core.import: keyed create/update of res.partner (country by code, tag created when missing), product.template by default_code, product.product barcode by default_code; re-run all unchanged (t/96) | live 2026-10-13: 31/31 | - | - | live 2026-10-13: 31/31 | - |
| stock profile: quant, location, package, lot, picking, picking type, move, move line, sale line, order, wizards | live 2026-10-13: 12 models, 88 fields; move line `reserved_uom_qty`/`qty_done`, `stock.immediate.transfer` | profile 17.yaml: one `quantity` + `picked`, no immediate wizard (pending live) | - | live 2026-10-13: 11 models, 85 fields; `stock.quant.package` renamed `stock.package`; `stock.move.name` absent | - |
| a transfer that leaves a package in two locations | REFUSED at validation (SA8), live 2026-10-13 (the mirror netting's reversal) | - | - | ACCEPTED, live 2026-10-13 (same reversal) | - |
| `stock.quant.create` with `quantity` (no inventory mode) and `write` of `package_id`/`quantity` by an administrator | ACCEPTED, live 2026-10-13 (how the test seeds anomalies; SB3 on the live site) | - | - | ACCEPTED, live 2026-10-13 | - |
| internal picking type of a one-step warehouse | archived (`active` false); a picking of it validates, live 2026-10-13 | - | - | same | - |
| `product.category.property_valuation` values | `manual_periodic`, live 2026-10-13 | - | - | `periodic`, live 2026-10-13 | - |
| context `lang` naming a language that is not installed | ACCEPTED silently (served in the user's language), live 2026-10-13 (`fr_FR`, `xx_XX`) | not probed (the instance shares the host's one spare alias with 18) | REFUSED on every call: "Invalid language code", live 2026-10-13 - the live harness now sends a lang only when the config names one | REFUSED on every call, live 2026-10-13 (`en_GB` installed there is accepted) | - |
| root product category name | `All` (live 2026-10-13) | - | - | `Goods` (live 2026-10-13) - resolve categories by name only with that in mind | - |
| serving slot after an external module install | needs a restart to see new models (live 2026-10-13); the cluster's module-install does it | - | - | same | - |
| `auth_ldap` server model | `res.company.ldap`, not `ldap.server`: `company`, `ldap_server`, `ldap_server_port`, `ldap_base`, `ldap_filter`, `ldap_binddn`, `ldap_password`, `ldap_tls`, `create_user`, `user` (the template), `sequence`; no name field. Live 2026-10-13 (t/24, 39/39); the admin reads `ldap_password` back over RPC | not probed (the instance shares the host's one spare alias with 18) | same fields, live 2026-10-13 (t/24, 39/39, after `module-install demo18.localhost auth_ldap`) | same fields, live 2026-10-13 (t/24, 39/39) | - |
| `ir.module.module.update_list` over RPC as the administrator | ACCEPTED, live 2026-10-13 (t/24: a missing addon name triggers it, then is held `unknown-module`) | not probed | ACCEPTED, live 2026-10-13 | ACCEPTED, live 2026-10-13 | - |
| `ir.config_parameter.unlink` over RPC as the administrator | ACCEPTED, live 2026-10-13 (t/24) | not probed | ACCEPTED, live 2026-10-13 | ACCEPTED, live 2026-10-13 | - |
| `fields_get` of `res.partner` for the mapping skeleton | live 2026-10-13 (t/24): relations, selections and magic columns as the skeleton expects | not probed | live 2026-10-13 | live 2026-10-13 | - |
| two-step delivery (`delivery_steps` = `pick_ship`): what confirming a sale order makes | a pick and a delivery, live 2026-10-13 (t/93) | not probed | the pick only; the delivery is made when the pick is validated, by the route's push rule `Output -> Customers`, live 2026-10-13 (t/93) | the pick only, as 18; `stock.rule` action `push` listed, live 2026-10-13 (t/93) | - |
| writing `delivery_steps` back to `ship_only` | not probed | not probed | REFUSED while the output location holds stock ("You can't disable locations WH/Output because they still contain products"), live 2026-10-13 | not probed | - |
| a pick's reserved move lines: who makes and writes them | created by user 1, written by the confirming user in the same second, live 2026-10-13 (t/93, first run) | not probed | not probed | not probed | - |
| domain term `product_id != 0` on `stock.move.line` | matches no record (0 rows where lines existed), live 2026-10-13; name the product | not probed | not probed | not probed | - |
| lot of a product with `use_expiration_date` and `expiration_time` 0 | `expiration_date` = `create_date`, live 2026-10-13 | not probed | same, live 2026-10-13 | same, live 2026-10-13 | - |
| `expiry.picking.confirmation` on validating a pick that draws such a lot | opened once the clock passed the creation time (SC4), live 2026-10-13 | not probed | not probed | asked for a lot with `expiration_date` 2030 and `removal_date` at creation, after the backorder wizard; none once all four lot dates were 2030, live 2026-10-13 | - |
| reservation of a lot whose lot dates are past, orders made seconds after the lots | not observed (reserved) | not probed | not probed | the second and third orders' picks stayed `confirmed`, nothing reserved; with the dates in 2030, `assigned` with the reservation, live 2026-10-13 (observed together, not isolated) | - |
| `process_cancel_backorder` on a pick or delivery validated below demand | closes it, no backorder picking left, live 2026-10-13 | not probed | same, live 2026-10-13 | same, live 2026-10-13 | - |
| adding a line (`picking_id`, `qty_done`/`quantity`, no `move_id`) to a done pick (SA3) | a done move with no `sale_line_id`, no `move_dest_ids`; `qty_delivered` unmoved, live 2026-10-13 | not probed | same, live 2026-10-13 | same, live 2026-10-13 | - |
| the same on the done delivery, then `write` of `sale_line_id` and `move_orig_ids` `(4, stranded)` | `qty_delivered` rises by the quantity (SC1); the stranded move gains its `move_dest_ids`, live 2026-10-13 | not probed | same, live 2026-10-13 | same, live 2026-10-13 | - |
| `date_done` on a validated picking, `date` on its moves and lines (SC6) | writable, live 2026-10-13 | not probed | same, live 2026-10-13 | same, live 2026-10-13 | - |
| `message_post` on `stock.picking` with `author_id`, `email_from`, `subtype_xmlid` `mail.mt_note` (SD1) | posts as a Note, live 2026-10-13 | not probed | same, live 2026-10-13 | same, live 2026-10-13 | - |
| an order with a draft invoice (a fixed-amount down payment) | `invoice_ids` readable by an accounting user; held `invoiced`, live 2026-10-13; the access error for a user without accounting rights not reproduced | not probed | same, live 2026-10-13 | same, live 2026-10-13 | - |
| read_group row count key `<field>_count` | live (crm.inspect) | - | - | - | - |
| read_group row count key (V14) | `<field>_count` for a lazy grouping, `__count` for `lazy=false`; live 2026-10-13 (crm.lead by type, tag_ids, stage_id) | not probed | same as 16, live 2026-10-13 | same as 16, live 2026-10-13 - not a series difference; `crm.inspect` reads either key | - |
| API key minted over the web session (make_key -> identitycheck -> run_check), then password spent | live 2026-09-28 | - | - | - | - |
| send via composer (mass_mail on one lead, V15) | live 2026-10-13 (t/91 16/16): composer driven by context `active_ids`, field `auto_delete_message` off; copy in the lead's history is `message_type` `email`; mail.mail in state `exception` with no outgoing server (sent at once) | source (17.0 composer: as 18); sender implemented, plan says so | live 2026-10-13 (t/91 16/16): `res_ids` text, `force_send` off; copy is `email_outgoing`; mail.mail `outgoing`, queued | live 2026-10-13 (t/91 16/16, also over json2): as 18 | - |
| composer fields `mail.compose.message` | `res_id`, `auto_delete_message` present; `res_ids`, `auto_delete_keep_log`, `force_send`, `use_exclusion_list` absent (live 2026-10-13) | `res_ids`, `auto_delete_keep_log`, `force_send` in the source; no `auto_delete_message` | `res_id` and `auto_delete_message` absent (a create naming `auto_delete_message` is refused: "Invalid field"); `res_ids` (text, a list), `auto_delete`, `auto_delete_keep_log`, `force_send`, `use_exclusion_list`, `partner_ids` present (live 2026-10-13) | as 18, and `composition_comment_option`, `notify_*` fields added (live 2026-10-13) | - |
| `/json/2/<model>/<method>` (V5) | absent: 404 HTML page (live 2026-10-13) | not probed | absent: the unauthenticated request is redirected (303) to the login page; no `json/2` in the 18.0 source (live 2026-10-13) | present (module `rpc`, `rpc/controllers/json2.py`), live 2026-10-13 | - |
| `/json/2` authentication | n/a | not probed | not probed (no API key minted on 18 for this) | `Authorization: Bearer <API key>` only (route `auth='bearer'`): no header 401 "User not authenticated, use an API Key with a Bearer Authorization header."; the password as bearer 401 "Invalid apikey"; the web session cookie 401 "Missing Authorization or Sec-headers"; live 2026-10-13 | - |
| `/json/2` database selection | n/a | not probed | not probed | header `X-Odoo-Database: <db>`; optional with one database (live 2026-10-13, the instance has one); the 19.0 `test_webjson2` suite: more than one database and no header, or a wrong one, answers a 404 HTML page | - |
| `/json/2` error shape | n/a | not probed | not probed | HTTP status plus JSON `{name, message, arguments, context, debug}` (`debug` is a traceback, never copied by the transport). Missing record 404 `odoo.exceptions.MissingError`; unknown model 404 `werkzeug.exceptions.NotFound`; unknown method 404 (the message names `model.method`); `UserError` 422; bad field in a create or domain 500 `builtins.ValueError`; bad argument name 500 `builtins.TypeError`; missing argument 422 `UnprocessableEntity`; ids given to a model method 422; live 2026-10-13 | - |
| `/json/2` calling convention | n/a | not probed | not probed | the body is the method's keyword arguments by name, plus `ids` (record methods) and `context`; no positional arguments (`default_get` takes `fields`, `write` takes `ids` and `vals`, `create` takes `vals_list`); `create` answers a list of ids, `copy` a list, `write` true; `common.version` is not served here: `/web/webclient/version_info` answers unauthenticated; the key owner's uid comes from `res.users/context_get`; live 2026-10-13 (t/93 18/18, t/95 7/7, t/98 and t/99 45/45 over `transport = json2`) | - |
| `properties` fields (V3): `crm.lead.lead_properties` (definition on `crm.team.lead_properties_definition`, type `properties_definition`) | present, live 2026-10-13: `fields_get` type `properties`, stored; a read answers a list of definition hashes each with its `value`; create and write take a list of `{name, value}`; the default read, `search_read`, `find` and a Record read it without a fault; `Portable::describe` gives no type; filtering by `lead_properties.<name>` faults ("'Properties' object has no attribute 'auto_join'"); writing a dict `{name: value}` replaces the whole set, unlisted values reading `0` (t/92 11/11) | not probed | as 16, except that a domain on `lead_properties.<name>` works (t/92 11/11) | as 18, except that after a dict write the unlisted values are absent from the read (t/92 11/11) | - |
| `project.task` (the other properties model named in V3) | not installed | not probed | not installed | not installed | - |
| send via composer (mass_mail on one lead) | source | - | - | - | - |
| composer field for keeping a copy in the record's history | `auto_delete_message` (source 16.0 mail.compose.message) | `auto_delete` + `auto_delete_keep_log` (source origin/17.0) | same as 17 (source 18.0) | same as 17 (source 19.0) | - |
| a sender with no email address and `message_post` (a lead note) or a lead created for another salesperson | REFUSED "Unable to send message, please configure the sender's email address", live 2026-10-13 (`tmp/probe-noemail.pl`); the same create under `mail_auto_subscribe_no_notify` ACCEPTED | refused (source origin/17.0 `_message_compute_author` raises); not probed, 17 unreachable | REFUSED, live 2026-10-13, as 16 | ACCEPTED both, live 2026-10-13 (source 19.0: `_message_compute_author` has no `raise_on_email`) | - |
| `button_validate` subscribes the validating user | yes (source 16.0) | yes (source origin/17.0) | yes (source 18.0) | no (source 19.0: no `message_subscribe` in `stock_picking.py`) | - |
| the "package in two places" refusal counts | every quant of the package with a quantity or a reservation, negative ones too (source 16.0 `stock_move._action_done`; the mirror reversal REFUSED, live 2026-10-13) | only quants with a positive quantity (source origin/17.0) | same as 17 (source 18.0) | same as 17 (source 19.0; the mirror reversal ACCEPTED, live 2026-10-13) | - |
| `crm.lead` unarchive: clears `lost_reason_id`, re-scores | in `toggle_active` (source 16.0) | in `toggle_active` (source origin/17.0) | in `toggle_active` (source 18.0) | in `action_unarchive`; no `toggle_active` on the lead (source 19.0) | - |
| `mail.activity` refuses an assignee who cannot read the record when the activity is not automated | yes, `_check_access_assignation` (source 16.0) | method kept but deprecated and not called (source origin/17.0 docstring) | no such method (source 18.0) | no such method (source 19.0) | - |
| `activity_schedule` marks the activity `automated` unless `automated` is passed | yes (source 16.0) | yes (source origin/17.0) | yes (source 18.0) | yes (source 19.0) | - |
| `crm.note` through the lead's `message_post` route (`subtype_xmlid mail.mt_note`), message id read back | not run | not run | not run | live 2026-10-13: applied, verified 1 (`ODOO_OOM_BEHAVIOURS` pointing at a one-route file) | - |
| apply invariants: `probability-manual` and `lot-totals-internal` read around an apply | live 2026-10-13: `crm.tag` apply, 10 open leads follow their automated score before and after (preexisting, not the apply's); `stock.net` t/94 31/31 | not run (unreachable) | live 2026-10-13: `crm.tag` apply, 10 before and after; t/94 31/31 | live 2026-10-13: `crm.tag` apply, 17 before and after; t/94 31/31 on the third run (see TEST-RESULTS: the first two failed when another session moved stock the sum read) | - |
| `res.partner` address written on a company reaches its children of type contact, not those of another type; written on a contact it stays there | live 2026-10-13 (t/92, 28/28) | source origin/17.0 (no upstream step); not live | live 2026-10-13 (t/92, 28/28) | the contact's address is also written on the company: live 2026-10-13 (t/92, 28/28; source 19.0 `_fields_sync` "To UPSTREAM") | - |
| `res.partner` vat written on a company replaces its non-company children's; written on a contact | stays on the contact, live 2026-10-13 | source origin/17.0 (as 16); not live | stays on the contact, live 2026-10-13 | written on the company too (`vat` is a synced commercial field), live 2026-10-13 | - |
| `res.partner` Tax ID check (`base_vat`) on an invalid number | REFUSED at write and create, with or without a country, accepted under `no_vat_validation`, live 2026-10-13 (`base_vat` installed on the local 16 for the run) | not probed | same as 16, live 2026-10-13 (`base_vat` installed for the run) | REFUSED with a country; ACCEPTED when the partner has no country (source 19.0 `_run_vat_checks` returns at once), live 2026-10-13. `base_vat` was already installed there | - |
| `res.partner` `company_type` (writes `is_company`), `commercial_partner_id`, `display_name` "Company, Contact", website `http://`, `email_normalized` lower-cased and a malformed address accepted | live 2026-10-13 (t/92) | not probed | live 2026-10-13 (t/92) | live 2026-10-13 (t/92) | - |
| `res.users.has_group` over RPC (doctor's group test) | a model method: `execute_kw(res.users, has_group, [group])` answers; with ids first it faults "takes 2 positional arguments but 3 were given" (live 2026-10-13, `oom-ops doctor`) | not probed | not probed | a record method: `[[uid], group]` (live 2026-10-13, `oom-ops doctor`) | - |
| `common.db.list` over `/jsonrpc` (LIST_DB) | refused: `odoo.exceptions.AccessDenied`, code 200 (live 2026-10-13, the local cluster, `oom-ops doctor`) | not probed | not probed | refused: `AccessDenied` "Access Denied", code 0 (live 2026-10-13, as 16) | - |
| `/web/login` through the cluster proxy | HTTP 200 with a `Date` header (live 2026-10-13) | not probed | not probed | HTTP 200 with a `Date` header (live 2026-10-13) | - |
| portal user made the way Odoo's portal does (core.user, 0.09): `portal.wizard` create with `partner_ids`, its computed `portal.wizard.user` line, `action_grant_access` on the line; the user's login is the line's email, normalised | live 2026-10-13 (t/35-core-user-live.t 40/40); the wizard exists, `portal.mail_template_data_portal_welcome` | source origin/17.0: as 16 (the modal action loses `view_type`); 17 unreachable, not probed | live 2026-10-13 (40/40); source 18.0: a revoked user is archived and kept in the portal group; the grant always writes `active` and the portal group | live 2026-10-13 (40/40); source 19.0: `group_ids`; the invitation is `auth_signup.portal_set_password_email` sent to the user | - |
| the portal wizard's invitation email | sent at the grant, `force_send`; with no outgoing server the `mail.mail` is left in state `exception` and the grant succeeds, live 2026-10-13 | not probed | same as 16, live 2026-10-13 | a `mail.mail` in state `exception` with no `email_to` (the recipient is the partner), live 2026-10-13 | - |
| `res.users` created with no groups named | gets the template user's groups: the local 16 gives a new user Sales, Inventory, Invoicing, Expenses and Employees administrator groups among others (live 2026-10-13); naming `groups_id` `(6, 0, [base.group_user])` gave a user who cannot read `crm.lead` (t/36-core-attach-live.t) | not probed | not probed | the new user held "Role / User" only (live 2026-10-13) | - |
| `password` written on `res.users` by the administrator over RPC | ACCEPTED; `common.authenticate` with it answers the user's uid, and answers false once the user is archived, live 2026-10-13 | not probed | ACCEPTED, live 2026-10-13 | ACCEPTED, live 2026-10-13 | - |
| API key minting path (core.user `api-key`): a web session as the user; `res.users.apikeys.description` create `{name}` + `make_key` answers the identity-check action (`res.users.identitycheck`, `res_id`); the check reads the password, then `run_check` answers the action `res.users.apikeys.show` whose `context.default_key` is the key. The acting user needs the identity check (10 minutes per session) | the password is written to the wizard's `password` field, then `run_check`; live 2026-10-13 (40/40) | same as 16 (source origin/17.0); not probed | same as 16, live 2026-10-13 (40/40); the wizard adds `duration` and `expiration_date` | the password goes in the call's context (`context.password`; the wizard's `password` field is not stored), then `run_check`; live 2026-10-13 (40/40) | - |
| who may mint an API key | internal users (`user_has_groups('base.group_user')`, source 16.0); a portal user is refused | source origin/17.0: as 16 | source 18.0: `_is_internal()` | source 19.0: `_is_internal()`; live: the plan holds a portal user `not-internal` before any call | - |
| default expiry of a key minted by a user who is not an administrator | none (no expiry field on `res.users.apikeys`), live 2026-10-13 | none (source origin/17.0 `_generate(scope, name)`) | the day after the creation date at midnight (`expiration_date`; the user's groups' `api_key_duration` allows one day), live 2026-10-13 | the same, live 2026-10-13 | - |
| `action_reset_password` on a user with an email, no outgoing mail server | FAILS: "Unable to connect to SMTP Server" (the call sends with `raise_exception`), live 2026-10-13 | not probed | applied, live 2026-10-13 | applied, live 2026-10-13 | - |
| `ir.attachment.checksum` and `file_size` | `checksum` is the SHA-1 (hex) of the raw bytes, `file_size` their count; both set at create, live 2026-10-13 (t/36-core-attach-live.t 37/37) | not probed | same, live 2026-10-13 (37/37) | same, live 2026-10-13 (37/37) | - |
| attachment access for a user who cannot read the record the attachment is on (an internal user holding only `base.group_user`, an attachment on a `crm.lead`) | `read` REFUSED: "You are not allowed to access 'Lead/Opportunity' (crm.lead) records" (category access); `search_read` by id answers an empty list; `/web/content/<id>?download=true` with the user's web session answers HTTP 404; an attachment on a partner is read normally. Live 2026-10-13 | not probed | the same checks pass, live 2026-10-13 | `read` REFUSED ("Uh-oh! Looks like you have stumbled upon some top-secret records."), search empty, `/web/content` 404, live 2026-10-13 | - |
| binary path of an attachment | `read` of `datas` over RPC answers base64 of the content; `/web/content/<id>?download=true` with a session cookie answers the bytes (HTTP 200, same SHA-1), live 2026-10-13 | not probed | same, live 2026-10-13 | same, live 2026-10-13 | - |

## 10. Onchange and x2many (SM747 seam)

Writes never invoke onchange (mapper decision, `docs/USAGE.md`): the
tools set only stored fields they name, and a created lead is what the
API creates, not what a form would. x2many values go through
`Odoo::Commands`; operations add tags by `(4, id)` and never replace a
set unless told to (`on_match: overwrite`).

# What filing the spec closed, and what it did not

| Seam this filing held open | State |
| --- | --- |
| The proxy's request-shaping layer (OB2, OB3) | **CLOSED.** Section 4: the Guard is the scoped mode and its absence is general mode, which is the division X4-b already ruled |
| Onchange and x2many (OM2's write behaviour) | **CLOSED**, section 10 - with a documentation obligation attached rather than a free choice |
| Which strategies ride on OOM | **CLOSED, and the work it found is done (2026-10-13)**: `file` and `session` ship (0.03); `cookie` refuses by design, a consumer turning it into a session first; an API key cannot start a session (sections 7 and 9) |
| Field descriptors sharing a rendering layer with the data extension | **CLOSED 2026-10-12 by ruling (R4)**: they share it. Slice R; where the type mapping lives was Q3, **answered by OOM in 0.02**: `portable_type` on the descriptor, and `rows` beside `fields` on a display read (section 8) |
| The MCP tool set (OM2) | **CLOSED 2026-10-12 by ruling (R5)**: all operations. The spec settled the vocabulary - a tool is a named operation with a declared scope; the registry lists 12 CRM, 2 Comms and 2 Core operations today, and a new pack becomes tools with no engine work. Slice E |

**The spec's own open list, carried here rather than left in another tree:**

1. live verification on the v16 CRM account (pending);
2. the session transport for OA2 - **still listed in the source's own Open section, but its
   section 7 says it shipped in 0.03 and section 9 says it is live on 16 and 19**; the list is
   behind the text above it, and is carried here as it stands;
3. descriptor comparison with the data extension - answered by ruling on
   2026-10-12 (R4): they share the data-table rendering; and OOM's 0.02 gave the
   descriptors a portable type for it (section 8).

# Sequencing

Scheduled 2026-09-28 at the release manager's direction, after the egress policy
it sits inside. Four gates stood in front of it; three are down, and the last is not
engineering's.

| Gate | State |
| --- | --- |
| X4 and its sub-questions ruled | **DONE 2026-09-28**, as recommended |
| SM579's invocation-mode policy becomes shared, so the proxy can be mode 2 *inside* it | **DONE, AND RELEASED.** `lib/Lazysite/Egress.pm` landed in 0.15.1 - `@MODES` and `may_invoke`, proved equivalent over 960 combinations, and its own comments already name `proxy` as a caller. This row said "the piece being built first" for three days after it was built, which is why the drift gate above now exists |
| The mapper specification filed and merged here | **DONE 2026-10-01.** Filed above with its source hash. It closed three seams, left two open and **found one new piece of work** - the session transport OOM did not have (section 7), which OOM built in 0.03 (RE-FILED 2026-10-13) |
| OOM reachable by this engine (OB7) | **STILL OPEN, and it is the only gate left - but it is a DECISION, not a packaging task.** `perl -MOdoo::Client -e1` fails on this host. This row first said a 0.02 deb had to be built; the release manager's direction of 2026-10-01 corrects that - OOM is under test and will have consumers beyond lazysite, so its delivery shape belongs to all of them. What survives is the requirement on CONTENT: whatever is delivered carries the `Odoo::Ops::*` layer, or there is no scoped mode. See *The direction, 2026-10-01*. OP-25. **RULED 2026-10-12 (R3): the deb, updated to carry what the extension needs.** The exact module list is filed to OOM's inbox (below). Building proceeds against the OOM tree; shipping waits on that deb. **2026-10-13: the deb exists (0.02 to 0.09, /srv/projects/packages) and is not installed on this host** |
| OOM's session transport (per-user path only) | **SHIPPED 2026-10-13, OOM 0.03 (R2)**, live on Odoo 16 and 19 (17/17 checks each). Slices B, C and D no longer wait on OOM; whether to build them is B-Q1. Request filed 2026-10-02, followed up 2026-10-12 (below) |

The first scoped app is the stock-corrections portal's live facts (P1).

# Open: B-Q1 - build the per-user path now that OOM's session transport has shipped (2026-10-13)

**For the release manager. Nothing is built for it, and the plan for B, C and D is unchanged
from the slice table; only their blocker has moved.** R2 ruled that the per-user path waits
for OOM's session transport. It shipped in OOM 0.03 and is live on Odoo 16 and 19, and the
live probes that came with it changed one thing the plan assumed.

**What the probes found** (section 9 of the filed specification, live 2026-10-13, 16 and 19):

- An API key minted as the user authenticates over RPC (`common.authenticate`).
- **`/web/session/authenticate` refuses an API key on both series** (kind `credential`): a web
  session needs the password. OA3's preferred form - use the key once to obtain a session, carry
  the session, discard the key - **does not exist**. OA3's own fallback is to carry the key,
  which OA3 says "is a materially different risk and must not be silently adopted", and R2
  already declined it.
- A two-factor user cannot complete a password session login (Odoo refuses), as OA2 said.
- **A key can be minted for the person, but only by a session that has passed Odoo's password
  identity check** (OOM's `core.user api-key`, live 2026-09-28 and in 0.09; section 9 of the
  filed specification). So "key once, then session" stays impossible in the other direction
  too: a key still needs the password, in a session, once. It does not change the
  recommendation below; it is the only way an API-key strategy could be fed without the
  person pasting a key.
- A portal user is refused a direct write on their own contact over RPC; Odoo's portal controller
  verifies the session identity and applies through its service connection, and OOM's use-case
  test shows the same shape. That is the connection user's path (slice CU) with a verified
  identity, not a per-user write. **OOM 0.09** adds `core.user`, which makes a portal user the
  way Odoo's portal does (the portal wizard's grant, live on 16 and 19), so an operator can
  create the person this pattern signs in.

| Slice | What it needed | What OOM now provides | What lazysite still has to build |
| --- | --- | --- | --- |
| **B** (M): one per-user credential strategy end to end | A transport that signs a person in and carries their session | `Odoo::Transport::Session`: `authenticate(db, login, password)` once, returning the identity (uid, login, name, lang, tz, companies) and an opaque session id; resume with `session => $id`; `destroy` on sign-out; expiry dies as category `session`, a refused login as `credential`, neither retried; `Odoo::Ops::Config->new(credential => 'session', session => $id)` runs every operation as that person (in memory only: a config file may not carry a session) | The sign-in step that takes the password and hands it to OOM without logging, storing or echoing it; the credential cookie (httpOnly, Secure, SameSite, path-scoped, OA4) carrying the session id; replay on each call; clearing on logout and on a `session` fault; outcome 10's re-authentication prompt; a named refusal for a two-factor account; a rate limit on sign-in attempts; the declared minimum raised to the OOM that carries the transport (0.03) when this lands |
| **C** (M): identity cookie, TT exposure, cache fail-closed | The person's Odoo identity once, at sign-in | The identity from `authenticate` (and `session_identity` on a resumed session). **Groups are not in it**: they are read from `res.users`, which the Guard allows, under a field named `groups_id` up to 16 and `group_ids` on 19 | The signed identity cookie with its TTL and refresh (OI1-OI3); the TT namespace (OT1, OT2); the cache fail-closed rule, reusing SM857's mechanism (OI5). The groups read is series-specific Odoo knowledge, so it needs to be an OOM operation or helper, not lazysite code (t/lint/240); that is a small ask of OOM |
| **D** (S-M): shared browser data module, re-authentication prompt | B | Nothing directly. The `session` fault category is the cue for the prompt. CSRF has moved to CU and is already built | The browser module (OA6: fetch, the CSRF token with one retry, the prompt), beside or inside `starter/assets/lazysite-data.js` |
| **F2** (S) | B, C, D | - | The per-user path's SECURITY.md and docs entries |

**Recommendation, sized:**

1. **Build B as a session-only (password) strategy first, then C, then D** - about one working
   session each for B and C and half of one for D (the calibration the slice table already uses:
   one session is about 34 files and 1,540 lines), F2 on the end. The first demonstrable result is
   a person signing in with their Odoo password on a lazysite page and a page rendering their own
   Odoo records, attributed to them in Odoo's own trail.
2. **Do not build the `apikey` strategy (OA3) until it is ruled.** With the key-once form gone it
   is only "carry the key", which R2 declined. If it is wanted, it is a separate ruling with the
   risk written out; if not, outcome 11 ("both session and apikey strategies work") is amended to
   the session strategy alone and two-factor accounts stay unsupported on this path.
3. **For a customer-facing site, consider the connection-user path with a verified identity before
   the per-user write path**: sign the person in over the session transport (B), then run the
   write as the connection user with the verified `partner_id` as a bound parameter - the portal
   pattern OOM tested live. That needs one new binding source (a parameter fed from the verified
   Odoo identity, beside `fixed` and `visitor_param`), about S, and is a decision to take with C.
4. **Ask OOM for the groups read** (above) so C does not put Odoo field names in lazysite.

**Asked:** (a) build B, C, D now, in the order above, or wait; (b) the `apikey` strategy: carry the
key (with the risk documented), or drop it from the outcomes; (c) whether the connection-user path
with a verified identity (3) comes first.

# Where the 2026-10-12 requests were filed

Both in OOM's inbox, in the house filing style, each claim graded with its file and
line:

| Request | Filed | Kind |
| --- | --- | --- |
| The session transport for the per-user path (R2) | `/srv/projects/odoo/oom/inbox/2026-10-12-lazysite-needs-the-session-transport.md` | **A follow-up.** The request itself was filed 2026-10-02 as `2026-10-02-the-session-transport-lazysite-needs-from-oom.md` in the same inbox and is still there unanswered; the follow-up records the ruling, re-measures, and adds what the first left out - logout, and the call surface the Guard wraps |
| The `Odoo::Ops::*` layer in the deb (R3, OB7) | `/srv/projects/odoo/oom/inbox/2026-10-12-lazysite-needs-the-ops-layer-in-the-deb.md` | **New.** The 2026-10-02 note mentioned the 8-of-41 measurement and expressly did not ask, the delivery shape being open then. It names every module the engine will import, the version lazysite will declare in `owns.deps`, two runtime dependencies missing from `debian/control`, and Q3's portable type as an optional ask |
