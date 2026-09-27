---
title: "lazysite - decision register"
subtitle: "What the engine is waiting on the release manager to decide, each with the question, the options and a recommendation. A question asked only in conversation is a question nobody can find again."
brand: plain
standard-margins: true
---

# Why a register

The same argument `docs/gate-register.md` and `docs/manual-check-register.md`
make, for decisions.

The engine agent regularly reaches a point where the next step is a judgement
that is not its to make - which release carries a breaking default, whether a
message is worth the thing it costs, who may write a destination. Those were
being asked in conversation, where they scroll away, and the release manager
had no list to read. This is that list.

**The filings are the source of truth.** Each row points at its SM, which
carries the reasoning, the evidence and what was already built. This register
carries only the question, so it can be read in a minute.

A row leaves when the decision is made: the SM records the ruling in its
`status-note`, and the row is deleted rather than marked answered - the
register is what is OPEN, not a history.

# Open

```datatable
columns: Item | The question | Recommendation
widths: 3cm | X | 6cm
bold: 1
tone: medium
---
bench | `work_users_tool_statements` has now refused three of the last five cuts (0.13.9 +10, 0.13.13 +7, 0.13.14 +41) and the answer has been "accept" every time. It is zero-tolerance by design, and **SM685 removed its original reason**: the tool no longer compiles on the default credential path (`verify_token_ms` 62ms -> 0.6ms, with `verify_token_cli_ms` as a separate gauge). It still measures a real cost on two narrower paths - a deployment that sets `LAZYSITE_USERS_TOOL`, and every account mutation - so it should not simply go. Keep it zero-tolerance, give it a small tolerance, or re-point it at what actually costs per request now? | **Keep it, and decide separately whether the CLI half of that tool belongs behind the counter at all.** A gate that is always accepted is not gating, but the fix is not a tolerance - it is that the counter's name promises more than its subject now delivers. Not urgent; after the expo.
SM857 (b) | What does a `mine` binding show an **anonymous** viewer? | **No rows, never all rows.** The page should be gated anyway; falling back to everything is the failure this whole item exists to prevent.
SM857 (c) | What if the table has **no `created_by`** (no `timestamps: true`)? | **Refuse at render, by name, in the log.** A `personal` row is untestable without the stamp, so a table carrying policies needs timestamps; a silently empty table reads as "no data" and is acted on as such.
SM857 (d) | A `mine` page is **per-viewer, so it cannot be cached** for everyone. Accept that cost? | **Accept it and reuse the existing mechanism** - a gated page already bypasses the cache, and `mine` implies the same treatment. This is the reason the feature is not free and why rendering has been viewer-independent until now.
SM857 (f) | "Absent means shared" is right for compatibility and wrong for the expo: **a form handler writing applications creates SHARED rows**, so every applicant could amend every other application. Should a handler be able to declare the policy it writes rows with? | **Yes, and it is the piece the expo actually depends on** - otherwise the safe case is the one that takes extra work. A second piece of work, after the row policy itself.
SM857 (g) | The stronger "amend **any** row's policy" right - reuse `manage_data`, or mint a capability? | **Reuse `manage_data`.** It already means "configure this table" and is already the operator grant on every data surface; a new capability costs the map, the grid, `describe-capabilities`, both channel gates and the docs, for a distinction `manage_data` already draws.
X3 (estate) | The sites agent's X3 table - `manager` account present, capabilities held, named sysop present, on 29 sites - cannot be built from what it holds: `users` (and `principals`, `protected-sections`) are cookie-only by design (SM779; `describe-capabilities` publishes `cookie_only: true`), MCP has no accounts tool, and the one row it could fill came from a browser session on edge. Two ways to the other 28: make the READ half of `users` (list) callable by a token holding `manage_users`, or lend the agent a manager login per site for its browser rig. Which? | **A manager login per site, for this table.** The cookie-only ruling was made because `users` settles capability decisions and a token client should not; opening the read half for one table is a permanent surface change bought for a one-off estate survey. Alternatively the operator runs `lazysite users --all list` on the host, which already answers all three columns in one command and needs no login at all - that is the cheapest of the three.
X4 (SM747) | The Odoo extension's proxy leg must put the **signed-in user's own credential** on the wire. Which egress policy applies to it? The audit (recorded in SM747, *The egress question*) found no "one egress path" rule in the tree: the rule is SM579's three invocation modes (ruled 2026-09-03, "regardless of what is at the other end"), and SM747 already binds an Odoo call to them. `Lazysite::Fetch` is GET-only, credential-free and refuses private ranges because CONTENT chooses its destination; connectors permit private ranges deliberately because the OPERATOR does, and hold one operator secret, a flat text payload and a 64 KB answer landing in a table - four decisions the per-user leg reverses. Three candidates: (1) the proxy does its own HTTP as a distinct transport; (2) connectors gain a per-user credential mode; (3) the proxy is exempted by design. | **(1), stated as mode 2 INSIDE SM579's policy, not beside it**: a logged-in user holding an Odoo credential is the only caller; the connector's transport discipline reused as behaviour (no redirect follow with a named refusal, a response cap sized for Odoo reads, a timeout, TLS verified, `https://` anywhere and `http://` only to loopback); a rate cap per identity and one audit record per call - actor, login, model, method, outcome - never the payload or credential; a SECURITY.md entry as a new outbound interface (SM136 precedent). (2) would be a second transport wearing the connector's name - SM579 refuses generalisation by default. (3) documents an exemption from a rule that does not exist. **Two sub-questions ride with it:** may plain `http://` reach an RFC1918 Odoo (the brief's "internal network"), and does the brief's general mode supersede SM747's "no raw passthrough, ever" - reconcilable only by naming the credential holder (user's own credential: Odoo's ACLs bound the call; service account, Part 6 MCP: SM747's rule stands).
```

# The rate limiter as a plugin, answered

Asked 2026-09-09, and worth writing out because the reasoning generalises.

The mechanism is real: a plugin declares `owns.deps`, and `_missing_deps`
refuses to enable it while any are absent. So the shape of the idea works.

It does not help here, for a reason that only shows on inspection: **`DB_File`
is a core Perl module.** `debian/control` says so in as many words - "perl
covers the core modules (JSON::PP, Digest::SHA, DB_File, ...)" - so the branch
that fails open for a missing `DB_File` is guarding something that essentially
cannot occur on a supported host.

The branch that *can* fire is the other one: a counter that will not open -
permissions on `lazysite/auth/`, a full disk, a read-only tree. **A dependency
check cannot see any of those**, because they are facts about the site at the
moment of the request rather than about what is installed.

There is a second objection, which would stand even if the dependency were a
real risk. A plugin is **opt-in and disableable**, and a login rate limiter is
neither: making it a plugin would mean a site could turn off its own brute-force
protection, and the disabled state would look exactly like the failure this SM
exists to make visible.

**What gets the benefit without either problem** is the health check.
`lazysite-check` is where an operator looks for facts about their site, and a
line there - *the login rate limiter is not in force, and why* - catches the
permissions case, which is the one that happens. It is recorded as not-built in
SM798 and is a small change if the release manager wants it.

# How this register is kept

The engine agent adds a row when it reaches a decision that is not its to make,
and deletes the row when the decision arrives. It is committed with the change
that raised the question, so the question and its context land together.
