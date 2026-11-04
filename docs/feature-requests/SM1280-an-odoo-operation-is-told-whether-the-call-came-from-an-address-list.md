---
id: SM1280
title: "SM1280: an Odoo operation is told whether the call came from an address list"
subtitle: "Ruling 3: a binding names an address list and a yes/no parameter, and its operation receives only whether the call came from inside that list - never the address. The server decides it from the endpoint's own address behind the trusted proxies, and the page cannot set or override it."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-22
raised-by: "the lazysite-sites agent for the OOM Lab (inbox 2026-10-22, P-8 to P-10); ruled by the release manager, ruling 3"
area: odoo
status-note: "SHIPPED (PENDING) on n733: binding keys address_profile + address_param (Lazysite::Odoo::Binding parse, check_against, assemble), decided in Lazysite::Odoo::call by _address_inside (AddressLists::in_list on the call's ip); the list is a binding reference in AddressRefs (slot match); a page variable refuses such a binding. t/unit/odoo/112."
---

# What was asked

The OOM Lab's attendance app accepts a clock-in from the office network without the
phone's position. To do that, the operation has to know where the call came from
(inbox `2026-10-22-site-chosen-permissions-policy-and-the-visitor-address-for-an-operation.md`,
P-8 to P-10). P-10 offered two shapes: pass the address, or name an address list and
pass only whether the call came from inside it. Ruling 3 (2026-10-22) picked the second:
"the operation gets only whether the call came from inside a named address list, never
the address."

# The report, checked

- **P-8 holds.** The endpoint works out the visitor's address (`_ip`:
  `Lazysite::Util::request_address` with the instance's `trusted_proxies`, SM929). It
  passes the address to the engine as `ip`, which records it with each call
  (`record_call`). No path gives it to an operation: `Binding::assemble` builds the
  parameters from `params`, `file_params`, `fixed` and `visitor_param` only.
  - The line numbers given (214, 289, 519-539, 788-793) are of another revision. In
    this tree `_ip` is called at 215 and defined at 866. The other ranges hold the
    multipart reader and the sign-in cookies, not the address.
  - That Odoo's clock route records `request.geoip.ip` is Odoo's behaviour and was
    not checked here.
- **P-9 holds.** SM1159's `signin_addresses` on a session binding refuses every call
  from outside the listed addresses (`_address_refusal`). It is a hard fence, and the
  ask is a soft one.

# What shipped

- **Two binding keys, together**: `address_profile` (for now an address-list name, SM1138's
  `[a-z0-9_-]{1,64}`) and `address_param` (a parameter name).
  - Saving refuses one without the other.
  - The parameter is a source of its own, so it cannot also be in `params`, `fixed`,
    `file_params` or `visitor_param` (the one-source rule).
  - The operation must declare it, and as `bool` (`check_against`).
  - A `scheduled` binding is refused: a timer comes from no address.
- **The server decides it.** `Lazysite::Odoo::call` asks `_address_inside($b, ip)`:
  `Lazysite::Auth::AddressLists::in_list` on the call's address. That is the matcher
  every address rule uses, and the page endpoint gives it `_ip`.
  - `assemble` sets the parameter to 1 or 0 last, after everything a request or the
    operator supplied.
  - The page cannot send it: the endpoint refuses an unmapped field.
  - No address, a list the store does not hold, or a store that will not read, is 0.
  - The address goes to nothing but the matcher.
- **Membership only.** `in_list` does not care whether the list is allow or deny, so
  either may be named.
- **The list counts as in use.** `Lazysite::Auth::AddressRefs` reports it as the
  binding's rule with slot `match`. The users tool's delete guard therefore refuses to
  delete it while a binding names it, and `lazysite check` warns if it is missing. The
  check's wrong-kind warning skips `match`.
- **A page variable refuses such a binding.** A render is shared and cached, and the
  answer depends on the viewer's address (`lazysite-processor/sources.pm`).
- **The Handlers page** offers the two keys, with notes (`Lazysite::Handlers`).
- **Docs**: `starter/docs/odoo.md`, `address_profile`, `address_param`, and how an
  operation reads the value: declare it `type => 'bool'` with a default of 0, and read
  `$self->param(...)`.

# Tests

t/unit/odoo/112, with an allow list `office` (203.0.113.0/24) and a deny list `blocked`,
and a test operation `shop.where` that answers what it was given:

- **Saving** refuses:
  - a list alone, or a parameter alone;
  - a bad list name;
  - the parameter also in `params`, or in `fixed`;
  - a non-bool parameter;
  - a scheduled binding.
  - the old key `address_list`, which is no alias.

  It accepts a deny list, and a list not yet made.
- **The engine** answers:
  - inside 1, outside 0, no address 0;
  - a deny list asked for membership 1;
  - an unknown list 0, and an undecodable store 0;
  - a request that sends the parameter is refused by name;
  - the binding's own fields still reach the operation, and the address is in nothing
    the operation was given.
- **The address refs** name the binding's list with slot `match`.
- **The page endpoint**:
  - from inside 1, and the address is not in the answer;
  - from outside 0;
  - behind a trusted front end, the forwarded address decides;
  - a forwarded address from a peer that is not trusted is not believed;
  - `?onsite=1` is refused 400.

With Binding.pm, Odoo.pm, Handlers.pm and AddressRefs.pm at SM1277, all five subtests
fail.

# The key's name (ruling 58, 2026-11-04)

The key was built as `address_list` and renamed `address_profile` before it shipped.
Address lists are to become address profiles: neutral named sets, allowed or denied where
they are used (inbox `2026-10-24-address-profiles-replace-address-lists.md`). For now the
key names an existing address list by its name. There is no alias (ruling 56: rename
outright): a binding that says `address_list` is refused at save by name ("does not
take: address_list"). t/unit/odoo/112 holds that. The refusal
messages, the Handlers page label and the in-use guard's reader
(`Lazysite::Auth::AddressRefs`, which reads the binding's `address_profile`) say profile.
`address_param` keeps its name.

# Not done

- **The Permissions-Policy half of the same request (P-4 to P-7)** is n729's and n736's,
  not this branch's.
- **The control API and MCP doors** decide it from their own request address, as the
  call record keeps it. Every door is held to one rule, but on those doors that is the
  agent's address, not a visitor's. Tell me if those doors should answer 0 instead.
