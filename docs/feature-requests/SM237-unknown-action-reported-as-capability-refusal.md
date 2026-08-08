---
title: "SM237 - An unknown action is reported as a capability refusal"
subtitle: "'Action not available to token clients' answers both an action a token client may not call and an action name the server does not recognise. The two send an agent in opposite directions."
brand: plain
status: shipped
status-note: "IMPLEMENTED in the 0.10.2 edge line (2026-08-08, commit c447b79). Reported by the sjm-claude-code site agent 2026-08-07. Verified in lazysite-manager-api.pl. Same class as SM226 and SM227 - the platform saying something that reads as a capability problem when it is not - and a natural fit for the same release."
---

# SM237 - an unknown action is reported as a capability refusal

## Why

While diagnosing something else, an agent mis-sent several control-API calls with
the action name doubled in the query string, and received:

```
Action not available to token clients: action=nav-read
```

The wording is accurate for an action that exists and that token clients are not
permitted to call. It is also what the server says when it does not recognise the
action name at all - here, the literal string `action=nav-read`, which is not an
action and never will be.

Those are different faults and they point in opposite directions:

- *Not available to token clients* means **ask the operator for a grant, or use a
  different channel.**
- *No such action* means **fix your request.**

The agent read the first, reported a capability problem to the operator, and the
problem did not exist. That is the same failure SM226 and SM227 address from the
other end: a response that reads as "you lack permission" when the truth is
something else entirely.

## What is true today

`lazysite-manager-api.pl` builds `%need`, a map from action name to a capability
test, for the token-client path. The dispatch is:

```perl
my $check = $need{$action};
unless ($check) {
    respond( { ok => 0, error => "Action not available to token clients: $action" } );
    exit 0;
}
unless ( $check->( \%token_caps ) ) {
    ...
    respond( { ok => 0, error => "Insufficient capability for $action. Call "
                . "describe-capabilities to see what your account holds and what each "
                . "capability unlocks." } );
    exit 0;
}
```

The second message is good - it names the remedy and points at the introspection
call. The first covers two cases with one sentence, and `%need` alone cannot tell
them apart: an action absent from `%need` may exist for cookie clients or may not
exist at all.

## What to change

### Tell the two apart

The API knows its own dispatch. Compare the requested action against the full set
of recognised actions, not only the token-client subset:

- **recognised, not permitted on this channel** - keep the current message, and
  say which channel does serve it where that is known.
- **not recognised** - a distinct message: the action name is unknown, with the
  advice to check the spelling and call `describe-capabilities` for the actions
  this account can use.

### Do not echo the input verbatim without marking it

`action=nav-read` appearing after a colon reads as an action name, which is part
of why the message was believed. Quote it, or label it as "unrecognised action
name", so a malformed value looks malformed.

### Reuse the remedy that already works

The capability-refusal message points at `describe-capabilities`. The unknown-
action message should too, and with SM225 in place that call now also returns the
documentation index, so one instruction covers both "what may I do" and "where is
this written down".

## Verification

- A recognised action that token clients may not call returns the existing
  message.
- An unrecognised action name returns a distinct message that names the fault as
  the request's rather than the grant's.
- Both point at `describe-capabilities`.
- The unrecognised name is quoted or labelled so it does not read as a valid
  action.
- No action becomes callable that was not callable before.

## Not in scope

- Changing which actions token clients may call.
- Enumerating every recognised action in the error body. Naming the fault is the
  ask; `describe-capabilities` is where the list belongs.
