---
id: SM910
title: "SM910: the well-known copy cannot answer the check the partner brief tells partners to make"
subtitle: "A partner brief opens by telling the agent to confirm its claims against /.well-known/ai-partner, and names that endpoint as the published copy of its machine-readable block. The endpoint is partner-agnostic, so its capability array is a statement about the SITE; on the reported host the two lists differed in both directions, five of nine. The reporter then exchanged the key and settled it by measurement: whoami vindicated the BRIEF's nine capabilities exactly, and the endpoint was the misleading one. endpoints and modes are published empty. And three shipped statements disagree about one WebDAV PUT, of which one is right."
brand: plain
standard-margins: true
status: candidate
status-note: "RAISED 2026-09-27 from the sites agent's inbox report and its same-day addendum, which is measured rather than read: the key was exchanged, whoami returned exactly the nine capabilities the brief named with manage_config FALSE, and the writes were tried. So the brief's snapshot was accurate and the well-known array was not, which confirms the filing's central point from the other direction - a partner told to 'confirm its claims' there would have concluded the brief was stale in five places while the brief was right in all nine. Two further readings were settled the same way: writes under lazysite/layouts/ ARE allowed (a 409 naming the missing parent, then MKCOL and ten PUTs at 201, two woff2 verified byte-identical on read-back), so the brief's Notes are wrong; and nav.conf over WebDAV is gated by manage_nav, not manage_config - 200 GET and 204 PUT on an account holding manage_nav and not manage_config. Nothing built: the engine agent has not re-measured any of it, and the rows below are the reporter's evidence, graded as measured on a live 0.14.4 host."
raised: 2026-09-27
raised-by: sites agent (inbox, 2026-09-27 18:10, with addendum)
area: partners, docs
---

# Why this one matters more than a docs drift

The brief is emphatic about why the check exists: "the field has lost a run to a
brief that named a capability the account no longer held, and spent a single-use
pairing key discovering it." The remedy it offers is the one check that cannot
settle the question, and it says two incompatible things in one document - confirm
the claims against the well-known copy, and `whoami` is the authority.

# The rows

| Ref | Cx | What |
|-----|----|------|
| WK1 | S | Say in the brief that the well-known copy confirms the SITE, the auth scheme and the deny list, and that only `whoami` confirms a grant. Measured: whoami returned the brief's nine exactly, with `manage_config` false, while the endpoint advertised `manage_config` and omitted `manage_nav` and `manage_content`. |
| WK2 | S | `endpoints` and `modes` are published as empty objects while `auth`, `scope`, `deny`, `deny_notes`, `docs` and `site` are populated. The brief directs a partner to parse endpoints from the machine-readable block, so a partner trusting the endpoint over the prose finds no exchange, rotate or control URL and no channel flags. Two fields never filled, not a deliberate omission. |
| WK3 | S | One statement about `nav.conf` over WebDAV, not three. The brief's body says a PUT is accepted with `manage_nav` (correct, measured 204); the brief's Notes say the same PUT is refused (wrong); the well-known `scope.webdav` says it needs `manage_config` (wrong - the write succeeded without it). The Notes contradicting the body of their own document is the worst of the three, because a careful reader trusts the Notes as the later correction. |
| WK4 | S | Remove "`lazysite/` paths are internal and not writable over WebDAV" from the brief's Notes. Measured false: MKCOL then ten PUTs under `lazysite/layouts/` all succeeded, and the 409 that preceded them named the missing parent rather than refusing the path. It decides whether `manage_layouts` on a token is usable at all, and as written it would send a partner to ask a sysop for something it can do itself. |
| WK5 | XS | Say beside the `nav-save` example that it REPLACES the whole navigation. It discarded a nine-item starter nav on the reported site, which is correct behaviour and worth saying out loud where the example is. |
| WK6 | XS | The brief's `channels` block says `mcp: true` and whoami reports `capabilities.mcp: true` with `services.mcp: false` - the capability is held, the service is off site-wide. Both are true answers to different questions and a partner reading either alone plans differently. One sentence in the brief naming which is which. |

# What this agent has NOT done

Re-measured any of it. The grade is the reporter's: a live 0.14.4 host, named,
with the key exchanged and the calls made. WK1 and WK3 are the two that change
what a partner does; WK2 is the one that looks like an unfinished field rather
than a decision.
