---
id: SM790
title: "SM790: the connector does not trust what the remote sends back"
subtitle: "Security review, 0.13.8, VERIFIED against the source: the connector call path builds a bare LWP::UserAgent with none of the three protections Lazysite::Fetch was hardened to carry. A GET connector follows a 3xx blindly into any host with the operator's secret header still attached, and the response body is pulled whole into memory with no cap. The design says the risk is who can cause the call; in public mode the answer to that is anyone."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-08 on claude/sm790-the-connector-does-not-trust-the-remote, and built NOW rather than later because SM579 phase 2 made the unattended case live: scheduled invocation calls a connector on a timer in the long-lived daemon, with nobody watching what comes back. max_redirect => 0 (a 3xx is a recorded failure naming why it is not followed), max_size at the answer cap, and the same two on the webhook dispatcher - the other egress a public form can drive, which had no bounds at all. THE THIRD RECOMMENDATION WAS NOT TAKEN, and that is a disagreement rather than a deferral: is_safe_url on the CONFIGURED url would refuse a destination the operator deliberately chose in the reserved tree (http:// to loopback is allowed by design and the 138E-08 field test depends on it) while closing nothing the redirect refusal has not. The brief\'s own analysis says the same - it is the redirect target and the response that were never the operator\'s choice."
---

# The finding

`Connectors::call` builds its agent as
`LWP::UserAgent->new( timeout => ..., agent => 'lazysite-connector/1' )` -
no `max_redirect`, no `max_size`, no `is_safe_url`. `Lazysite::Fetch::fetch_url`
carries all three, added under SEC-2026-07 H6. The connector is a second egress
path that never learned what the first one was taught.

Three consequences, all following from LWP's defaults rather than from anything
the module does:

- **A GET connector follows a redirect.** `requests_redirectable` is GET/HEAD
  by default, up to seven hops, and the target is validated against nothing. A
  remote the operator legitimately pointed at - later compromised - can send
  the call to a link-local metadata address or a loopback port.
- **The secret rides along.** The credential is set as a request header, and
  LWP does not strip custom headers across a redirect, so it is presented to
  whatever host the remote nominates.
- **The body is uncapped.** The answer is read whole into memory, on a path
  that in phase 2 runs unattended in the long-lived daemon.

**The trigger surface is the part that makes this more than a configuration
choice.** `may_call` admits a `public` mode, and `plugins/form-handler.pl`
calls in it, so an unauthenticated visitor submitting a bound form causes the
outbound call. The module's stated model - "the risk is not what the remote
does, it is who can cause the call" - is sound for the trigger and does not
cover the response, and in public mode the "who" is the public.

# What is asked

At the wire, and shared with the webhook dispatcher, which has no guard at all
today:

1. `max_redirect => 0` on machine calls; a 3xx is a `failed` answer with its
   status recorded. This closes the redirect SSRF and the secret leak together,
   and is the smallest change of the four. **Built**, and the refusal names why
   it is not followed, so the remedy reads as "reconfigure the connector"
   rather than "follow it for me".
2. `max_size`, at the 64 KB the answer cap already names. **Built**, and it is
   now literally the same constant - the agent's `max_size` and the cap on the
   stored answer are one number: the amount of a remote's answer this instance
   will hold.
3. `is_safe_url` on the configured URL and on the webhook URL. **Not built, and
   this is a disagreement rather than a deferral.** Both URLs live in the
   reserved tree (`connectors.json`, `handlers.conf`), so both are the
   operator's choice, and the private-range policy here is open *by design*:
   `_normalise` accepts `http://` to `127.0.0.1` and `localhost` because a
   service on this host is a legitimate destination, and the 138E-08 field test
   depends on exactly that. Running the guard over them would refuse a
   destination the operator deliberately configured while closing nothing item
   1 has not already closed. The reasoning is written where the check would
   have gone, and a test asserts its absence so it cannot be added back without
   meeting the argument.
4. Strip the credential header on any host change. **Moot, and better than
   moot**: with no redirect followed there is no host change, so the credential
   cannot travel. Closed by construction rather than by remembering to strip a
   header.

The webhook dispatcher takes 1 and 2 as well. It is the other egress a public
form can drive, it had no bounds at all, and it carries no credential - but a
redirect there sends the **visitor's own submitted fields** to a host the
operator never configured.

The open URL policy for the CONFIGURED endpoint is deliberate and is not
questioned here: an operator may point a connector where they choose. It is the
redirect target and the response - neither of which the operator chose - that
this is about.

# Provenance

`inbox/2026-09-08-connector-egress-hostile-remote-response.md`, with the render
half in SM786. Accepted: the absent UA options were read-verified in
`Connectors.pm` against `Fetch.pm`, and the public trigger in
`plugins/form-handler.pl`.
