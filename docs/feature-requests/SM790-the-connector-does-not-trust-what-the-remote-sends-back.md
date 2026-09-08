---
id: SM790
title: "SM790: the connector does not trust what the remote sends back"
subtitle: "Security review, 0.13.8, VERIFIED against the source: the connector call path builds a bare LWP::UserAgent with none of the three protections Lazysite::Fetch was hardened to carry. A GET connector follows a 3xx blindly into any host with the operator's secret header still attached, and the response body is pulled whole into memory with no cap. The design says the risk is who can cause the call; in public mode the answer to that is anyone."
brand: plain
standard-margins: true
status: candidate
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
   and is the smallest change of the four.
2. `max_size`, at the 64 KB the answer cap already names.
3. `is_safe_url` on the configured URL and on the webhook URL.
4. Strip the credential header on any host change, as belt-and-braces with 1.

The open URL policy for the CONFIGURED endpoint is deliberate and is not
questioned here: an operator may point a connector where they choose. It is the
redirect target and the response - neither of which the operator chose - that
this is about.

# Provenance

`inbox/2026-09-08-connector-egress-hostile-remote-response.md`, with the render
half in SM786. Accepted: the absent UA options were read-verified in
`Connectors.pm` against `Fetch.pm`, and the public trigger in
`plugins/form-handler.pl`.
