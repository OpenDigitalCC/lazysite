---
title: "SM427: a permission should say what it grants, in full"
subtitle: "The Groups page names each capability in a line. What it does not say is the reach - which surfaces it opens, what an agent holding it can do without asking again, and what it therefore places inside the grantee's trust. Facts, not warnings."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED in 0.11.3 (2026-08-27). A `grants` sentence per capability, in Capabilities.pm beside the title, carried through describe() and SERVED to the Groups page - never restated there. That matters more than usual here: the page already carries a hardcoded label list with a comment admitting it must match @CAP_KEYS, and the SENTENCES are the part that has to be right, so a second copy would drift the moment either changed. SM277 set exactly this precedent in the same API action and for the same reason. FACTS, NOT WARNINGS, as the filing instructed: the test asserts that the capabilities whose reach surprised somebody this month NAME the thing that surprised them - audit says the trail is instance-wide and carries source IPs, manage_forms says delivery can go somewhere nobody pre-defined and that it reads what visitors sent, purge says the backup store reaches other sites, manage_data says an unscoped table is reachable from any site here, manage_users says it has no remote surface - and it asserts that NONE of them shouts, because a warning teaches people to click past. It also refuses a sentence that merely echoes its own title, which is the way a presence check gets satisfied without the copy being written. THE COPY WAS THE WORK, as the filing said: nineteen sentences, each grounded in what the capability actually unlocks. Two hover targets are kept separate on purpose - the label carries the TECHNICAL NAME (SM617), the marker carries the SENTENCE; merging them makes a tooltip nobody reads to the end. FILED 2026-08-20 at the release manager's instruction, arising from SM421. The ruling there was that permission is the control - where a capability is granted, every surface delivers it in full - which is coherent and makes the GRANT the decision point. That only works if the person granting knows what they are granting. TODAY: Capabilities.pm carries a one-line title plus an `unlocks` map naming the actions/tools per channel, and the Groups page renders the title. The unlocks map is the raw material for something better and is already maintained per channel, which is the hard part. THE ASK: a per-capability information surface - a tooltip, an expander, or a panel beside the checkbox - stating in plain sentences what the capability reaches, across WHICH surfaces, and what follows from granting it. FACTS, NOT WARNINGS, per the instruction: 'manage_forms lets this group choose where a form's submissions are delivered, including to an address or URL you have not pre-defined' is a fact an operator can weigh. 'Warning: dangerous!' is not, and it teaches people to click past. SIZE: M - the copy is the work, not the mechanism, and the copy is the part that must be right."
---

# Why this follows from SM421

If a capability behaves identically everywhere it is granted - which is now the
rule - then the only place a decision is made is the moment of granting. A
grant screen that names a capability without describing its reach asks for a
decision while withholding what the decision is about.

# What "in full" means for the operator

Take `manage_forms` as the worked example, because it is the one that prompted
this:

::: widebox
It lets a group create and edit forms, wire them to any operator-defined
delivery handler, **and name a delivery destination directly** - a URL or a
file path - on every surface: the manager, the control API, WebDAV and the AI
connector. Submissions carry whatever visitors type into the form.
:::

Every clause there is a fact. None of it is a warning, and an operator reading
it can decide whether this group should hold it. Today they get "Create and
edit forms."

# Shape

- Source the text from `Capabilities.pm`, beside the existing `title` and
  `unlocks` - one place, already per-channel, already maintained.
- Render it where the decision happens: the Groups page checkbox, and the
  onboarding brief a partner grant produces.
- Say reach, surfaces, and consequence. Do not say "careful".
- The generated capability docs should carry the same sentences, so the answer
  is identical wherever it is read.
