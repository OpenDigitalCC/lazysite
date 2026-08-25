---
title: "SM578: a site package download is confined only by dav_scope, and the listing not at all"
subtitle: "One instance holds every domain's packages in one directory. site-backup-download refuses a package outside the caller's scope - but only if the caller has a scope; an unscoped manage_domains grant reaches every site on the instance."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.33. THE EXEMPTION IS THE CHANNEL, NOT THE ABSENCE OF A SCOPE. _package_scope_refusal returned early whenever the caller had no dav_scopes, on the reading that no scope means unconfined - true of a COOKIE session, which is the operator at their own manager, and false of a token or MCP grant where it only means nobody set one. A cookie session is now the explicit exemption; every token grant must name a scope the package's content_root falls inside, and one naming none reaches NO package rather than all of them. That is the behaviour change the operator accepted on 2026-08-25, existing partners being theirs to re-scope. THE LISTING IS FIXED TOO, through the same refusal the download and delete verbs use, so the three cannot disagree about who reaches what - only `site` entries are filtered, a full or content backup being instance-wide and governed by manage_config. Proven in t/unit/manager/46 with a manage_domains token partner holding no dav_scope - THE WEAKER GRANT IS THE EVIDENCE, since every other test in that file authenticates with the trusted header, which is the exempt path and could never have shown the gap. The fixture needed control_api_enabled: true added: without it the token calls were refused by the SERVICE gate and four assertions passed for the wrong reason. Sabotage-verified: restoring the old reading fails five of them. ASKED BY THE SITE AGENT 2026-08-25 as an inference from SM577's verified mechanism (the backups directory is instance-local and holds other hosts' archives): if the read side is unfiltered it is worse than the delete side, because deletion destroys a copy while download EXFILTRATES a whole site to a partner granted nothing on it - and on this estate the sites belong to different people. ANSWERED FROM THE CODE, no probe run. TWO HALVES, opposite answers. (1) THE READ IS PARTLY CONFINED: action_site_backup_download inspects the package manifest and refuses when its content_root is outside_all_scopes(@REQUEST_SCOPES) - but @REQUEST_SCOPES is the caller's resolved dav_scopes, so the check is SKIPPED ENTIRELY when the list is empty. A cookie session has none (that is the operator, correctly unconfined); a TOKEN grant with manage_domains and no dav_scope also has none, and reaches every domain's package on the instance. The confinement is therefore a property of how a partner was scoped, not of the action. The listing carries no scope filter at all, so the names and sizes of every site's packages are readable by any manage_domains holder. (2) THE PACKAGE DOES NOT CARRY PROTECTED CONTENT: package_create counts protected files through Private::count_private and omits them, reporting private_omitted and the notice the agent saw from site-export-primary - so ACL-gated content is NOT reachable by this route, and the SM570-shaped fear (protected content reachable without touching an ACL) does not hold here. WHAT REMAINS is another client's unprotected site - pages, assets, theme, layout, configuration - obtainable wholesale by a partner scoped to a different site on the same instance. PRECONDITION CONFIRMED LIVE 2026-08-25: two client-facing MCP/OAuth accounts hold manage_domains with an empty dav_scopes; the agent established that from whoami and deliberately did NOT call list_domains to size the blast radius, since enumerating other clients' domains is the disclosure being raised. The MCP site_backup tool carries the same conditional and so shares the gap for CREATE; no MCP download tool exists, so exfiltration over MCP alone is not available. DECIDED BY THE OPERATOR 2026-08-25: the behaviour change is ACCEPTED and the fix is scheduled for the NEXT RELEASE (0.10.33) - managing the change for existing partners is theirs to handle, so the safer semantics win over compatibility. That settles the open question below: an empty dav_scopes stops meaning 'unconfined' for a token or MCP partner. SCHEDULED 0.10.33: make the confinement a property of the ACTION (derive the caller's own site from its grant and require the package's content_root to match, with an explicit operator-only exemption) rather than a property of whether a dav_scope happens to be set; and filter the listing the same way."
---

# The two questions, answered by reading

| Question | Answer | Established by |
|---|---|---|
| Does the download filter by host? | Only when the caller has a `dav_scope`; skipped entirely when the scope list is empty | code: `action_site_backup_download` |
| Does the listing filter? | No | code: `action_backup_list` |
| Does a package contain ACL-protected content? | **No** - counted and omitted (`private_omitted`) | code: `package_create` |

# The MCP path, answered by reading (2026-08-25)

The site agent reported the precondition present on two LIVE client-facing
accounts - `manage_domains: true` with `dav_scopes: []` - and asked
whether MCP shares the gap. It does, in the same shape, but MCP offers
less to do with it:

| Over MCP | Answer |
|---|---|
| `site_backup` (create a package of a named domain) | **Same conditional**: `if (ref $scopes eq 'ARRAY' && @$scopes && outside_all_scopes(...))` - so an empty `dav_scopes` skips the check and any configured domain can be packaged |
| Download a package | **No MCP tool exists** - the tool description itself says "download it with the backup tooling" |

So an MCP-only partner with an empty scope can cause another domain's
package to be WRITTEN into the shared store, but cannot fetch it over
that channel; fetching lives on the API path and needs a token
credential. The exposure is real and its reach depends on which channels
a given account holds.

# The two halves compose, and not necessarily in one account

Per ACCOUNT the MCP finding is narrower. Per INSTANCE it is not:

| Grant | What it gives |
|---|---|
| MCP partner, empty scope | can cause another domain's package to be **written** into the shared store; cannot fetch it |
| API token, empty scope | can **list and fetch** whatever is in that store |

Neither completes the exposure alone. **Together they do, and they need
not be the same account** - only the same instance. One partner packages
another client's site; a different partner, on a different site,
downloads it. Two grants that each look defensible in isolation compose
into "any partner can obtain any site".

*Marked as an INFERENCE from two verified code facts (the MCP conditional
and the API conditional, both read), offered by the site agent as a
reading. It has deliberately not been demonstrated end to end: doing so
would mean packaging and then fetching another client's site, and the
demonstration is the harm.*

**The write half is not harmless even with no reader.** Packaging another
client's site produces an artefact containing their content, in a store
they do not control, created by a partner they have no relationship with,
as a side effect nobody requested. On an estate where the sites belong to
different people that is a data-handling event whether or not anything is
later fetched.

**Consequence for prioritisation:** "MCP cannot download" must not reduce
the urgency. The planned fix - confinement as a property of the ACTION -
closes both halves at once, and its virtue is precisely that it does not
depend on reasoning about which channels a given partner happens to hold.
That reasoning is where this was missed the first time.

# Should an empty scope mean "unconfined" at all?

Raised by the site agent and worth deciding with the fix rather than
after it. For a COOKIE session an empty scope correctly means the
operator. For a token or MCP partner it currently means the same thing
**by accident** - and the live accounts show partners routinely have no
scope set, so the permissive reading is the common case rather than the
exception. Reading "no scope" as *no access outside my own site* would
have closed this without anyone noticing, and is the safer default.

It is a behaviour change for existing partners - a broadly-granted
partner that today reaches every domain would stop doing so. **The
operator has accepted that** (2026-08-25) and scheduled the fix for
0.10.33: managing the change is theirs, and the safer default wins. Two
of the site agent's own live accounts are affected and have been told.

# Why the gap is not "the scope check works"

The check reads: *if the caller has scopes, the package must be inside
them*. An unscoped grant satisfies it vacuously. Scoping a partner is
how an operator confines it to one site, so the site that most needs the
confinement - a partner given a broad grant on a shared instance - is
exactly the one that does not get it.

# What the exposure is, precisely

Another client's **unprotected** site, wholesale: pages, assets, theme,
layout and configuration. Not their ACL-gated content, which stays in the
private store and is omitted by construction.

# Proving test

A token holding `manage_domains` and NO `dav_scope`, on an instance with
two domains, is refused `site-backup-download` of the other domain's
package and does not see it in the listing; an operator cookie session
still sees and downloads both.
