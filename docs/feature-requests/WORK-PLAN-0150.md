---
title: "Work plan - 0.15.0"
subtitle: "The whole open backlog at 27 September 2026 - ninety-nine filings, each with a complexity and what blocks it - grouped into work that shares a mechanism, a decision or a test surface. 0.15.0 opens a new edge series because the work already landed on main includes a published-surface removal, so this is the release that can afford the changes a patch line cannot."
brand: plain
standard-margins: true
---

# What 0.15.0 already is

Main already carries eight entries under `## Unreleased`, landed and gated. They
decided the channel: [[SM903]] removes `theme-rename` from the control API and is
flagged breaking, [[SM901]] turns a silently-accepted ACL list that resolves to
nobody into a refusal on three surfaces, and [[SM899]] adds `--installdir` and
changes the CLI's exit contract. A stable patch line cannot carry those, so
0.15.0 is a new edge series and 0.14.x stays where the fleet is.

The rest of what is landed is correctness: [[SM904]] (a form value stored as
typed), [[SM900]] (a parse error reported at the file line), [[SM902]] (the
manager guide describes controls that exist), plus [[SM894]] and [[SM895]], which
ship nothing and only change how this repository tests and cuts.

**That shape is the argument for what to add.** A release that already breaks one
published action and moves one refusal is the right release to land the work that
regenerates derived files and moves theme assets out of a gated root. Those are
awkward in a patch and unremarkable in a new series.

# How to read this

Every open filing is below exactly once. Nothing is omitted as too small or too
speculative, because the release manager asked for the full table.

**Complexity** is the work that remains, not the work already done, and for a
`partial` item the description covers only the remainder:

| | Meaning |
| --- | --- |
| **S** | One surface, under a day, its test included |
| **M** | A few days; several surfaces, or a new option or field |
| **L** | A week or more; a new subsystem, or a contract that crosses surfaces |
| **XL** | A programme spanning several filings |

**Blocked on** names the thing precisely. "A ruling" means the release manager;
where a question is already on `docs/decision-register.md` the row is named.

# Group A - declared, not assembled

Four filings, one mechanism. The engine keeps a derived thing beside the code it
describes, a lint notices when the two drift, and somebody edits both. Each of
these replaces the lint with generation, so the second copy stops existing.

They belong together because they share the generation pattern and the test
surface, and because A1 unblocks A4. A2 extends the rule that `t/lint/139`
already applies to refusal kinds.

| Ref | Source | Cx | What the work is | Blocked on |
| --- | --- | --- | --- | --- |
| A1 | [[SM662]] | S | Generate `ControlApi::Actions` and the `unlocks` map from the declarative `%need` table instead of checking them against it | none |
| A2 | [[SM873]] | M | Give every store-inspection refusal a literal kind with a decided status instead of a runtime-concatenated `store_<reason>`, and lint that every `kind =>` is a literal | none |
| A3 | [[SM654]] | M | Generate the MCP and control-API `unlocks` maps from the tool and gate declarations, and add the missing `manage_themes` / `manage_layouts` rows | none; the filing names [[SM653]], which has shipped |
| A4 | [[SM594]] | L | Generate the published channel matrix from the capability tables so it cannot diverge from engine behaviour | A1 |

Order: A1 and A2 are independent, then A3, then A4.

# Group B - one ACL answer, and the write paths that need it

The release manager ruled on both halves of this on 14 September, so it is
buildable now. B1 and B2 are one new resolver with two consumers, which is why
they must be built together rather than in sequence. B3 is the residue of the
same review and the same class of defect.

| Ref | Source | Cx | What the work is | Blocked on |
| --- | --- | --- | --- | --- |
| B1 | [[SM881]] | L | Add an engine resolver that answers whether a path is gated by asking the ACL store, and have git-sync call it after every merge to relocate a protected file a pull just published | none, ruled |
| B2 | [[SM882]] | M | Move the theme mirror's assets out of a fully gated content root, and assert in `lazysite check` that a gated root contains nothing public | shares B1's resolver |
| B3 | [[SM852]] | M | Fix the three remaining docroot write paths: `domain_add` with a seed into a protected folder, a plugin's store-rewrite path, and `domain_remove`'s purge leaving the protected half | none |

B2 changes where a file lives on upgrade, which is the part that wants a new
series rather than a patch.

# Group C - cheap, sharp, unblocked

The shape 0.14.3 used. Each is a day or less, none waits on anybody, and between
them they close four field findings and two process gaps.

| Ref | Source | Cx | What the work is | Blocked on |
| --- | --- | --- | --- | --- |
| C1 | [[SM871]] | S | Teach the form rule tokenizer about escaped quotes so a stray quote in a `value:` literal cannot truncate the value and have the remainder parsed as further rules | none |
| C2 | [[SM864]] | S | Have `lazysite-check` flag an existing account literally named `manager` as a shared-looking role account, renaming and deleting nothing | none |
| C3 | [[SM829]] | S | Add the last pre-commit guard: refuse a commit touching a file marked generated-do-not-edit | none |
| C4 | [[SM456]] | S | Record that some field verifications are blocked by the agent harness rather than by lazysite, so their absence from a report reads as unrun instead of unmentioned | none |
| C5 | [[SM888]] C1, C2 | M | A no-CDN gate that also catches a stylesheet reached by `@import` | none |
| C6 | [[SM888]] A5 | S | Fix the single-checkbox `required` attribute and the refusal copy that describes it wrongly | none |
| C7 | [[SM888]] P2 | S | Stop the Files asset count including rendered HTML | none |

C5 to C7 are the only rows of [[SM888]]'s field digest still classed as this
repository's work and still open. The rest of that filing is estate or operator.

# Group D - an account can be asked for and approved

D1 and D2 are the same button. Splitting them would mean building it twice, so
they group whatever else is chosen.

| Ref | Source | Cx | What the work is | Blocked on |
| --- | --- | --- | --- | --- |
| D1 | [[SM858]] | S | An Approve button on the Submissions view that passes the address automatically for a form declaring `account_email:` | none |
| D2 | [[SM673]] | M | Generalise that button so the operator never retypes a username or address | a form-schema convention naming which fields are username and address, not yet written; the escaping proof it also names is [[SM709]], which has shipped |
| D3 | [[SM674]] | XL | Unattended self-registration with no operator step: verified email, a safe default group, a name-allocation rule, ceilings and bulk undo | a ruling; the release manager deferred it as beyond a build |

# Group E - find the slowdown, then fence it

Two ends of one problem. E1 finds the cause; E2 stops the next one being
invisible. E2's question is the register's `bench` row.

| Ref | Source | Cx | What the work is | Blocked on |
| --- | --- | --- | --- | --- |
| E1 | [[SM883]] | M | Bisect 10 to 13 September for the uniform slowdown across six unrelated timed operations, ruling out host factors before the code | none |
| E2 | [[SM663]] | S | Add a host-independent work counter to the authenticated path so the bench gate fails on real per-request cost rather than a duration ratio | register row `bench` |

# Group F - the manager under an enforcing policy

F1 is the prerequisite for actually enforcing a content-security policy on the
manager, and it is large because the count is large. F2 is the other side of the
same headers.

| Ref | Source | Cx | What the work is | Blocked on |
| --- | --- | --- | --- | --- |
| F1 | [[SM490]] | L | Convert about 250 inline event-handler attributes across sixteen manager pages to delegated `data-action` handling | none |
| F2 | [[SM710]] | M | An opt-in `permissions_allow` key so a site can re-enable a hard-denied browser feature such as the microphone, failing safe on an unrecognised value | a ruling on per-instance versus per-domain scope |

# Group G - the manager's own consistency

One style-guide-and-lint programme. G1 decides an idiom that G2 needs, and G3
and G4 are the same conversion work on two different declarations. Together this
is most of a release on its own.

| Ref | Source | Cx | What the work is | Blocked on |
| --- | --- | --- | --- | --- |
| G1 | [[SM845]] | L | Decide and record one word and one container for opening a row's detail across every manager list, then apply it | none |
| G2 | [[SM841]] | S | Scroll signposting for a row's hidden action, and the missing headroom for the Files trigger at phone width | G1, for the option of moving the trigger rather than shrinking it |
| G3 | [[SM726]] | L | Convert every remaining manager page with a save onto the six-behaviour save contract, and lint that a page implements the behaviours rather than declaring the classes | none |
| G4 | [[SM728]] | L | Convert the remaining 199 controls across seventeen pages to declare their data impact | a ruling on which pages and in what order |
| G5 | [[SM698]] | L | Replace the manager's legacy-class shim with the design vocabulary so all three stylesheets apply, then the style-guide preview modal | none |
| G6 | [[SM424]] | M | Move the blocked-IP list off the stats page into Plugin Config with a per-entry disabled flag and a toggle | none; the filing names [[SM640]], which has shipped |

# Group H - the auth cookie and the session

A chain, not a set. H1 unblocks H2; H3 unblocks H4. [[SM297]] asks for its own
security review and its own release, which makes H1 a poor passenger in a mixed
batch.

| Ref | Source | Cx | What the work is | Blocked on |
| --- | --- | --- | --- | --- |
| H1 | [[SM297]] | L | Rewrite the auth wrapper so cookie validation returns an identity value handed straight to handlers, so the pooled front door stops forking for identity | none; wants its own review and release |
| H2 | [[SM614]] | M | Sliding session expiry with a moving last-seen time beside the immutable issue time, plus the decided absolute cap | H1 |
| H3 | [[SM813]] | M | A per-instance key putting a Domain attribute on the auth cookies, default host-only, so one sign-in spans an operator's subdomains | a ruling on whether to offer it, where the key lives, whether the value is validated |
| H4 | [[SM814]] | S | Put the shipped intranet on its own subdomain using the domain record's existing settings instead of per-page rules in a folder | H3 |

# Group I - the form's way out, and consent

I1 and I2 are both the smtp handler's output and share its configuration. I3
builds on both. I4 is the escaping safety of the same surface and its filing asks
for a release of its own, because getting it wrong reintroduces a
cross-site-scripting class the project has already closed once.

| Ref | Source | Cx | What the work is | Blocked on |
| --- | --- | --- | --- | --- |
| I1 | [[SM877]] | M | A `to_field` option so the smtp handler can also mail the submitter, gated by a new per-destination cap, since the per-IP limiter does not cover the relay risk | scheduling, plus decisions on the cap, envelope sender and naming |
| I2 | [[SM762]] | M | Markdown email-body templates with the submission's fields in scope, so a form sends its own wording rather than a field dump | a ruling on template location and the escaping and missing-variable rules |
| I3 | [[SM761]] | L | A confirmed opt-in handler that withholds the payload until the visitor clicks a mailed link proving the address | rulings on the verb route, token store, dispatch trigger, quarantine and expiry |
| I4 | [[SM869]] | L | Make each sink escape for its own context instead of relying on the query parser's incidental escaping | scheduling; wants its own release and an adversarial test |
| I5 | [[SM273]] | M | Correlate submissions with the scanner and bad-URL signals, and put block and reject counts in the day buckets | none |

# Waiting on you, and buildable the moment it is answered

Nothing here is blocked on engineering.

| Source | Cx | The question | Where it sits |
| --- | --- | --- | --- |
| [[SM857]] | L | Five questions on row-level access: the anonymous case, a table with no `created_by`, the cache cost, whether a handler declares the policy it writes, and whether `manage_data` carries the stronger right | Register rows SM857 (b) (c) (d) (f) (g) |
| [[SM747]] | XL | Which egress policy the Odoo extension's per-user proxy sits under, plus plain `http://` to a private host and whether general mode supersedes the no-passthrough rule | Register row X4 |
| [[SM663]] | S | Keep the work counter zero-tolerance, give it a tolerance, or re-point it | Register row `bench` |
| [[SM707]] | M | Never accept an uploaded pandoc template, mint a capability for it, or allow a vetted subset | not yet on the register |
| [[SM414]] | M | How a per-query search page is cached, and whether it gates beta | not yet on the register |
| [[SM405]] | M | Re-derive the stored day files onto the new visitor classes, or leave them on the old basis | not yet on the register |
| [[SM276]] | L | Who supplies translations for the engine's own pages: bundled, or overridable per site | not yet on the register |
| [[SM708]] | M | Which to build first: narrower protection for a literal `[%` in page script, or surfacing render failures | not yet on the register |
| [[SM863]] | S | Whether to offer an alias host as a suggestion the operator confirms, or nothing | not yet on the register |
| [[SM792]] | S | What the daemon's Status action discloses while the daemon is disabled | not yet on the register |
| [[SM784]] | L | Scheduling: the four-state boolean survey and its lint | held out of the current release |
| [[SM408]] | M | Six releases need their significant-change assessment, and the declaration needs signing | yours by definition |
| [[SM811]] | S | The release-workflow rule file is outside this repository and needs your edit | yours by definition |
| [[SM887]] | S | The skill's acceptance needs a real claude.ai conversation, which a container cannot reproduce | yours by definition |

# Programmes, not this release

Each is a chain where the first item gates the rest. Naming them keeps them out
of a release plan without losing them.

| Source | Cx | The programme | First buildable step |
| --- | --- | --- | --- |
| [[SM666]] | XL | The persistent runtime, then the local socket and proxy map, then the WebSocket transport, then federation | Prove phase 1 on a real host, which needs an operator |
| [[SM221]] | L | The WebSocket transport as a service plugin under a gated `realtime` capability | [[SM666]] phase 2 |
| [[SM646]] | L | An XMPP client plugin with a local anonymising map, treating every inbound message as untrusted | [[SM666]], and [[SM485]] |
| [[SM485]] | M | The SMTP endpoint, the notice-store read surface, and the optional `to` field so a notice can be addressed | none - this one can start |
| [[SM222]] | XL | Finish the inline units, then move five endpoint services onto one lifecycle contract | none - and its L0 gates [[SM817]] |
| [[SM817]] | L | Finish the extension rename: loader, internal names, constrained enablement | [[SM222]]'s render-time registry |
| [[SM827]] | M | One Agent Skill packaging the build method from existing docs | [[SM817]] |
| [[SM828]] | S | Decide the position on agent-knowledge standards | [[SM827]]'s result |
| [[SM824]] | M | Emit JSON-LD from metadata the page already has, never guessing Article | [[SM222]]'s registry, with [[SM817]] |
| [[SM825]] | M | Serve each page's markdown beside the rendered page, gated the same way, front-matter secrets stripped | sequenced after [[SM824]] |
| [[SM823]] | unscoped | An ingestion plugin with pluggable sources, Silex first | [[SM817]], and a decision on whether sources reuse the extension contract |
| [[SM715]] | L | The apps manifest schema: what an app owns, requests and descends from | none - it starts the chain |
| [[SM716]] | M | The namespace register that admits an app and tombstones it on uninstall | [[SM715]] |
| [[SM717]] | M | The install-time seed loader for reference and example rows | [[SM715]], [[SM716]] |
| [[SM718]] | L | Install completion: roles onto groups, path grants, connector binding, the data plugin check | [[SM715]], [[SM716]]; connectors need [[SM579]] |
| [[SM719]] | M | Add-only updates, and a named refusal for anything needing a declared migration | [[SM717]] |
| [[SM720]] | M | A fixed vocabulary of declarative migration operations, backed up before it runs | extends [[SM719]]; may follow [[SM722]] |
| [[SM721]] | M | Uninstall retention, reinstall reattachment, and a one-shot fork migration | [[SM715]], [[SM716]] |
| [[SM722]] | L | Refactor a real bespoke app to the manifest and prove the round trip by hand, then remove each manual fix | [[SM715]] to [[SM719]] |
| [[SM723]] | XL | The external marketplace design record | [[SM722]]; marked do-not-build until then |
| [[SM430]] | XL | Consolidate the duplicated write-path logic across four surfaces, including WebDAV's ACL-blind move and delete | none; every row is unblocked, CF-8's [[SM422]] having shipped |
| [[SM611]] | L | A data store per site with an instance-wide table as the declared exception, about 22 call sites and a live migration | decisions on precedence and a rehearsed migration |
| [[SM516]] | XL | The ranked backlog from ten structural code reviews, each row becoming its own filing when picked | none - pick a row |
| [[SM659]] | L | Correct the remaining documentation and comment uses of "operator" to the principal each actually means | none |
| [[SM683]] | L | A second, separately-permissioned repository outside the docroot so protected content can have history | none |
| [[SM735]] | L | Make the generated documentation index reach the layouts repository, a running site and the website | a cross-tree listing contract, unspecified |
| [[SM265]] | M | The browser session surface: a private per-session store with ETag concurrency, gated raw assets, a short-lived scoped token | an operator ruling on token authority and spend |
| [[SM579]] | M | Spend caps distinct from rate caps, and the visitor-facing check-back-later banner | none |
| [[SM754]] | M | Move the remaining 471 ratcheted fixtures off bare-tempdir docroots | none |
| [[SM493]] | L | A standard styled component set with a components-list on the control API | deliberately waiting for the first consuming site |
| [[SM688]] | XL | Per-item nav visibility, and several named navs placed anywhere | a nav.conf format decision, and [[SM349]] |
| [[SM693]] | S | Measure the render stages before sizing a content-only cache | belongs inside [[SM688]] |
| [[SM349]] | L | Rewrite 22 catalogue layouts to render the site's real navigation | the layouts repository, not this one |
| [[SM217]] | M | A first-class alias action so a host can share another's content root without hand-editing | none |
| [[SM208]] | M | The integrations docs namespace and the Figma transfer how-to | none |
| [[SM745]] | S | One-time addressed token issuance so a credential reaches an agent outside a transcript | soft-held behind [[SM746]] |
| [[SM746]] | unknown | Diagnose the edge connector's tools vanishing mid-session | needs incident evidence before it can be scoped |
| [[SM090]] | XL | Syndication in and out, ActivityPub and AT Proto | [[SM666]], [[SM579]] |
| [[SM184]] | XL | Publish by email, with sender verification and a confirmation-gated loop | [[SM666]], and a sender-trust ruling |

# Parked, with no trigger

| Source | Cx | Why it is parked |
| --- | --- | --- |
| [[SM075]] | L | Wildcard multi-tenant hosting; no demand |
| [[SM086]] | M | Pandoc construct renderers; needs a ruling on appetite |
| [[SM089]] | L | A 3D-rendered layout; never scoped past the slot |
| [[SM092]] | L | Gopher and Gemini servers |
| [[SM211]] | S | Withdrawn; the guard was correct. An optional residue remains, validating raw DAV writes to the `.conf` carve-outs |
| [[SM232]] | S | Ruled: no subject-scoped export or erasure. Submissions are a capture surface, not a record store |
| [[SM236]] | S | An icon link per catalogue layout; the layouts repository, not this one |
| [[SM497]] | L | A second database engine behind the adapter; waits for a real trigger |
| [[SM826]] | S | An Open Knowledge Format export; waits for the format to have consumers |

# The backlog overstates how blocked it is

A filing records what blocked it on the day it was written and is not revisited
when the blocker ships. Five of the blockers named across these ninety-nine
filings have already shipped, so five items read as waiting when they are not:

| The filing | Names as its blocker | Which shipped in | So what is actually left |
| --- | --- | --- | --- |
| [[SM857]] | [[SM860]], to stamp the row author | 0.13.14 | The five register questions alone |
| [[SM654]] | [[SM653]], for the path-aware rows | shipped | Nothing |
| [[SM424]] | [[SM640]], Plugin Config as a line list | shipped | Nothing |
| [[SM673]] | [[SM709]], the script-block escaping proof | shipped | Only the form-schema convention |
| [[SM430]] | [[SM422]], the parity map, for CF-8 | shipped | Nothing; all fourteen rows are open |

[[SM857]] is the one that matters for planning: it is an L-sized item that reads
as engineering-blocked and is in fact waiting on five answers, so answering them
converts it from parked to buildable.

This is worth a habit rather than a one-off sweep. A `partial` or `candidate`
filing naming another SM as its blocker could be checked against that filing's
status by a lint, the way `t/lint/53` checks that a changelog's commit refs exist.
Not proposed as work here, and not filed.

# One thing nobody filed

The housekeeping report of 21 September asked two things that
never became a filing, so they are in no queue: a retention rule for superseded
versions in `dist/`, and three files there that are not lazysite artefacts, two
`.stl` and one `.scad`, dated 8 August. `dist/` is now 463 MB across the releases
since 0.11.0. The pressure that prompted it has eased, `/srv` being at 52 per
cent against 92 per cent when it was written, so this is a filing to make rather
than work to schedule.

# What I would put in 0.15.0

Groups A, B and C, on top of what is already landed.

That gives the release one theme a reader can state: **the engine stops keeping
two copies of the same truth.** Group A removes four hand-kept derivations,
Group B replaces two disagreeing answers to "is this path gated" with one, and
Group C clears the cheap field findings that are sitting there. It is also the
right release for Group B, because moving theme assets out of a gated root is a
change of location on upgrade, and this series already carries a break.

Group D is a sensible addition if the release wants a visible feature, since D1
is small and D2 only needs a convention written down.

Everything else either waits on an answer from you, wants a release of its own
because of what it risks, or is the first step of a programme that should not
start inside a mixed batch.
