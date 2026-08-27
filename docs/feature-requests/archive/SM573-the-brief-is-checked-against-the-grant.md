---
title: "SM573: the brief is checked against the grant"
subtitle: "The operator's brief for a partner account listed seven capabilities. whoami reported seventeen. /.well-known/ai-partner lists five. Three documents describe one grant and no two agree, and the brief is the only one a partner reads before it connects."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.33. PART (1) DONE, AND IT MAKES PART (2) UNNECESSARY RATHER THAN SKIPPED. The brief's machine-readable capability block was a hand-written list of seven pushes in _onboarding_brief, which is why an account holding seventeen capabilities was described as holding seven. It is derived from @CAP_KEYS now - the same list whoami answers from - so the two cannot disagree, and a capability added in a later release appears without anybody remembering to add it, which is exactly the failure this was. The three inherited grants keep their resolution (manage_content from webdav, nav and forms from content) because effective_settings leaves them undefined when inherited; ui/api/mcp are CHANNELS rather than authority and are described by name elsewhere in the brief. The PROSE list is fixed the same way: anything held with no curated sentence is named plainly rather than omitted, so the human half cannot understate either. PART (2), a check warning when a brief's stated capabilities differ from the account's, is SATISFIED BY CONSTRUCTION rather than by a second piece of code, and there is no checker: a brief is GENERATED ON DEMAND from effective_settings and never stored, so once the block is derived there is no typed artefact that can diverge from the grant. The divergence such a check would report can no longer arise. THE PAIRING WITH SM564 STANDS: the instance the agent saw is most likely group-membership drift - the account's groups reach further than the group the brief was written for - and that is a real question about the GRANT, which this does not answer and does not claim to. What it guarantees is that whatever the grant is, the brief says it. Proven by t/unit/users/36, which asserts the brief and the account agree in BOTH directions rather than that seven named capabilities appear - the latter being the bug restated. Sabotage-verified: restoring a hand-list fails eight of nine assertions. OBSERVED BY THE SITE AGENT 2026-08-25 on a partner grant issued by the operator: the operator's brief named seven capabilities; whoami answered seventeen, among them manage_users, manage_domains, manage_data, read_submissions, audit and create_sub_users; /.well-known/ai-partner (partner-agnostic by design) lists five. The brief is how a grant is COMMUNICATED and nothing checks it against the grant. A brief that OVERSTATES costs a refusal; a brief that UNDERSTATES hands out authority nobody wrote down - the partner holds manage_users without having been told, and the operator believes the seven they typed. The instance is most likely group-membership drift (SM564's subject: the account's groups reach further than the group the brief was written for), so the two filings pair. PLANNED for 0.10.33 under SM516: (1) a per-partner brief whose capability block is GENERATED from the account's effective capabilities - whoami's answer - and never typed; (2) a lazysite-check warning when a brief's stated capabilities differ from the account's effective set, in either direction. Proving tests: a unit test that a generated brief's capability block equals the account's effective caps; a check-tool test that a hand-edited divergence is reported."
---

# Three documents, one grant

| Document | Capabilities named | Who reads it |
|---|---|---|
| The operator's brief for the account | seven | the partner, before connecting |
| `whoami` | seventeen | the partner, after connecting - if it asks |
| `/.well-known/ai-partner` | five | anyone; partner-agnostic by design |

No two agree. The well-known document is allowed to differ - it describes
the site, never one grant. The brief and `whoami` describe the same
account and disagree by ten capabilities, six of them administrative.

# Why understating is the dangerous direction

A brief that overstates is caught on first use: the partner tries the
action and is refused. A brief that understates is never caught. The
partner holds `manage_users` and `manage_domains` without having been
told, the operator believes the seven capabilities they typed, and the
authority exists on the site with no document that admits it.

SM570 was the same shape one layer down - an authority the grant never
expressed - and SM564 is the likely mechanism here: the account's groups
reach further than the group the brief was written for.

# The mechanism

- **Generated, never typed.** A per-partner brief carries a capability
  block produced from the account's effective capabilities - the answer
  `whoami` gives - at the moment the brief is issued or refreshed.
- **Checked.** `lazysite-check` warns when a brief's stated capabilities
  differ from the account's effective set, in either direction, naming
  the capabilities on each side.

# Proving tests

- A unit test that a generated brief's capability block equals the
  account's effective capabilities.
- A check-tool test that a hand-edited divergence is reported, with the
  differing capabilities named.
