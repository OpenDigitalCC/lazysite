---
title: "SM573: the brief is checked against the grant"
subtitle: "The operator's brief for a partner account listed seven capabilities. whoami reported seventeen. /.well-known/ai-partner lists five. Three documents describe one grant and no two agree, and the brief is the only one a partner reads before it connects."
brand: plain
standard-margins: true
status: candidate
status-note: "OBSERVED BY THE SITE AGENT 2026-08-25 on a partner grant issued by the operator: the operator's brief named seven capabilities; whoami answered seventeen, among them manage_users, manage_domains, manage_data, read_submissions, audit and create_sub_users; /.well-known/ai-partner (partner-agnostic by design) lists five. The brief is how a grant is COMMUNICATED and nothing checks it against the grant. A brief that OVERSTATES costs a refusal; a brief that UNDERSTATES hands out authority nobody wrote down - the partner holds manage_users without having been told, and the operator believes the seven they typed. The instance is most likely group-membership drift (SM564's subject: the account's groups reach further than the group the brief was written for), so the two filings pair. PLANNED for 0.10.33 under SM516: (1) a per-partner brief whose capability block is GENERATED from the account's effective capabilities - whoami's answer - and never typed; (2) a lazysite-check warning when a brief's stated capabilities differ from the account's effective set, in either direction. Proving tests: a unit test that a generated brief's capability block equals the account's effective caps; a check-tool test that a hand-edited divergence is reported."
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
