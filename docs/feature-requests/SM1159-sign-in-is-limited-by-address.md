---
id: SM1159
title: "SM1159: sign-in is limited by the address it is made from"
subtitle: "L2 from the OOM agent: lazysite's own sign-in and the Odoo extension's sign-in through a page (both steps) can be limited to address ranges per site, and a session binding can narrow that on its calls."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-17
raised-by: inbox/2026-10-17-L2-ip-limits-on-sign-in.md (the OOM agent, at the owner's request)
area: auth
status-note: "SHIPPED on n651 (builds on SM1134, SM1138, SM1140): AddressScope::signin_refused, lazysite-auth.pl, lazysite-odoo.pl, Odoo::Binding, Config page; t/unit/auth/67, t/unit/odoo/54. A binding's rule is held on its calls (sign-in names no binding). Open: list-delete guard does not read bindings."
---

# What happened

The inbox item, filed 2026-10-17 by the OOM agent, "L2 (backlog): IP limits on sign-in":

> The owner added this to the lazysite backlog: sign-in (lazysite's own, and the
> Odoo extension's sign-in through a page) can be limited to address ranges per
> site, and optionally per binding. For example, a warehouse site accepts sign-ins
> only from the factory and warehouse networks.
>
> It is a compensating control alongside the second factor, not a second factor
> itself. It pairs with L4 (Odoo's two-factor in the sign-in dialog).
>
> - The present limiter is `Auth::LoginRate` (per address and per login). An
>   address allow-list is a refusal before it, with its own reason in the record,
>   not a rate.
> - Behind a proxy, the address is the one the site already trusts for the limiter.

# What shipped

It reuses SM1134's pieces and adds no mechanism: the named address lists (SM1138), `Auth::AddressLists::decide()` (deny wins; an allow list present and no match denies; a faulted store denies), the visitor's address through `trusted_proxies`, and the SM1140 audit-once-an-hour writer.

lazysite.conf `signin_addresses:` and `signin_addresses_deny:` (comma separated list names, as `manager_addresses`):

- lazysite's own login (`lazysite-auth.pl`, `handle_login`), the Odoo endpoint's `signin` and its `signin_code` step all ask `AddressScope::refuse_signin` first. The refusal comes before the token is read, before the password is checked and before `Auth::LoginRate` counts: a refused address is not a rate, and trying again and again from it never turns into a rate limit.
- Its own reason everywhere: the login redirects to `?error=address` and the page says "Sign-in is not available from your address."; the Odoo endpoint answers `403` kind `address` with the same sentence; the event log says "sign-in refused: address not allowed"; the auth audit has `login fail address-refused`; and the address audit has one `address-refused signin` row per address per hour.
- Signing out is never refused, and a session already open is untouched (this limits getting one).
- The Config page has both keys beside `manager_addresses`: names must be real lists of the right kind, cookie sessions only, and a value that would refuse the setter's own address is refused ("shut your own address out of signing in"), the same guard SM1140 gave `manager_addresses`.
- `lazysite check` and the address-list delete guard (`Auth::AddressRefs`) count the two keys, so a list sign-in uses cannot be deleted by accident.

## Per binding: held on the calls, not at sign-in

The Odoo endpoint's sign-in names no binding (`{signin, login, password, visitor_token}`), so at sign-in it cannot know which binding's page the person is on. So the site-wide rule limits the sign-in itself, and a session binding's own `signin_addresses` / `signin_addresses_deny` (names of address lists) are held where the binding is named, on its calls (GET and POST, single or in a batch): a call from an address the binding refuses is answered `403` kind `address` ("This page is not available from your address.") with its own audit row `address-refused signin <binding>`. A binding's list narrows and never widens: the site's rule still decides who can sign in at all. A connection binding carrying these fields is refused at save, not ignored (it has no sign-in).

# Open

- Two sign-in doors still outside this: lazysite's password reset and claim pages (`forgot`, `claim`), which are not sign-in. Not changed.
- A binding's own list names live in the handler store, which `Auth::AddressRefs` does not read, so deleting a list a binding names is not yet refused. Filed here rather than widening that module in this branch.
