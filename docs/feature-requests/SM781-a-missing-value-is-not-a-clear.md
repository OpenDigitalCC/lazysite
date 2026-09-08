---
id: SM781
title: "SM781: a missing value is not a clear, connector-call is on every channel's list, and the visitor's refusal names what happened"
subtitle: "137E on 0.13.7, three small things from one run: start-page-set with the value under another key answered ok:1 and silently cleared the setting; connector-call worked and was missing from actions-list (declared capless the way a cookie-only action is - and SM779's map would have marked it cookie_only); the visitor's 'no active delivery target' sent the owner to the binding when a connector had refused the mode."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-08 on claude/sm781-a-missing-value-is-not-a-clear. start-page-set refuses a body without `value` ('value is required ... an empty string clears the start page') and leaves the setting untouched; connector-call is declared caps => [] (no capability; the connector gates it) so every channel's actions-list carries it and the map does not call it cookie-only; the form's not-delivered message says nothing accepted the submission - switched off or refused - and that the owner can see why in the event log. t/unit/manager/158, t/unit/manager/10 and t/lint/58 assert the three."
---

# What the field saw (137E)

- `start-page-set` with `{start_page: ...}` → `ok: 1`, and the start page
  cleared. An absent `value` read as an empty one, which is the clear.
- `connector-call` answered every call and was absent from `actions-list`;
  `describe-capabilities` (with SM779) would have marked it `cookie_only`.
  Its declaration said `caps => undef`, which is the spelling for "the
  cookie channel alone serves this".
- A visitor's submission refused by the connector's mode came back "This
  form is not accepting submissions right now (no active delivery target)".
  The owner reading that goes to `handler-list` and finds nothing wrong; the
  reason was in the connector's record.

# What is built

- `start-page-set`: a body without `value` is refused, naming the key and
  how to clear (`"value": ""`); nothing is written.
- `connector-call`: `caps => []` - no capability, gated by the connector -
  so `actions_for` lists it on every channel. Lint 58's capless-token
  expectation names it beside the three introspection actions, with the
  reason.
- The not-delivered message: "nothing accepted the submission: its delivery
  is switched off or refused it - the site owner can see why in the event
  log".

# Also from 137E, not built

The primary host's token in `choices.domains` is the literal `(default)`,
not its hostname (SM724's spelling); a value built with the hostname is
refused as "not a domain this instance serves", which is the truth. Noted
for the next plan rather than changed.
