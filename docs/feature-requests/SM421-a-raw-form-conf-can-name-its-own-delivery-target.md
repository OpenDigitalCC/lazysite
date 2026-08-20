---
title: "SM421: a raw form config can name its own delivery target"
subtitle: "WebDAV accepts an unvalidated write of lazysite/forms/<name>.conf on the grounds that it 'only names which operator-defined handlers a form dispatches to'. The parser still accepts a legacy inline format that declares a delivery target directly - including a webhook URL."
brand: plain
standard-margins: true
status: candidate
status-note: "FOUND 2026-08-20 while verifying flag F4 of the security-review agent's cross-surface parity map, which recorded it as REPORTED - needs verification and flagged it as the one that could be more than cosmetic. It is. VERIFIED by driving the real parser and dispatcher: load_form_conf's legacy branch parses `- type: webhook` with an inline `url:`, and dispatch's non-handler branch assigns `%h_config = %$target`, so the target's OWN keys become the handler config and dispatch_webhook posts to whatever URL the file named. THE DIVERGENCE: a manage_forms holder using the structured verbs (bind_form on MCP, handler-save / form-targets-save on the API) can only REFERENCE an operator-vetted handler; the same capability writing the same file raw over WebDAV can DECLARE an arbitrary delivery target. Submissions carry visitor PII, so the practical shape is exfiltration to an attacker-chosen endpoint by a partner holding a capability that is not supposed to grant that. The WebDAV gate's own comment states the property it relies on - 'It only names which operator-defined handlers a form dispatches to, never credentials' - and that property is true of the new format and false of the legacy one the same parser still accepts. DECISION HELD for the release manager: the three fixes differ in compatibility cost and one of them can break a live site. NOT reachable anonymously and not a visitor-facing hole; the precondition is a manage_forms grant with WebDAV."
---

# What was driven

```
targets parsed: 1
  type=webhook url=https://attacker.example/collect
dispatch routes a non-handler target through its OWN keys: YES
webhook type reaches dispatch_webhook: YES
```

# The three ways to close it, and what each costs

validate on write
: WebDAV refuses a `<name>.conf` whose content declares an inline target -
  handler references only. Smallest blast radius, keeps the legacy format
  working where it already exists, and puts the check where the trust boundary
  is. Needs the validator to be the same one the structured verbs use, or it
  is a fourth opinion about the same file.

retire the legacy inline format
: One parser, one shape, and the gate's stated justification becomes true
  everywhere. **This can break a live site**: any existing form conf using the
  inline format stops delivering, and the failure is visible only when
  somebody submits. Needs a survey of what the fleet actually uses, and a
  migration.

deny the file over WebDAV
: Reverts to the pre-0.8.1 posture. Simplest and safest, but it removes a
  capability agents are documented to have, and the cross-plane consistency
  0.8.1 deliberately established goes with it.

# Related, unfixed here

The same parity map flags five more divergences (F1, F2, F3, F5, F6). F1 and F2
are small and are being handled alongside this; F3, F5 and F6 are recorded in
[[SM422]] with the verification each still needs.
