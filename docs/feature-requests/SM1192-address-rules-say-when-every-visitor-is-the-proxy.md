---
id: SM1192
title: "SM1192: the manager says when every visitor is the front proxy"
subtitle: "Where address rules are edited, a plain warning appears when the request's own peer is a private or loopback address that trusted_proxies does not name."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-19
raised-by: inbox/2026-10-19-test-plan-01510-results.md F-1
area: manager
status-note: "SHIPPED (0.15.11) on n681: Lazysite::Util::front_end_is_every_visitor, Auth::AddressLists::front_end_warning, the address-lists and config-read answers, three pages; t/unit/manager/365 and 366."
---

# What happened

The 0.15.10 walk of edge (finding F-1) reported:

    F-1, edge sees every visitor as its front proxy
    Every audited request carries 10.2.30.177: the operator's sign-in, and
    claude.ai's OAuth refreshes from Anthropic's servers. `trusted_proxies`
    does not name the front end, so every address rule on edge (pages,
    groups, sign-in, manager) applies to everyone at once. The docs say
    this; `lazysite check` warns, but the operator cannot run it from the
    manager. Edge's front end should be named in `trusted_proxies`, or the
    manager should say so where address rules are edited.

The value of `trusted_proxies` on edge is the operator's to set. This item is
the manager half: say so where the rules are edited.

# What shipped

- `Lazysite::Util::front_end_is_every_visitor($spec)` decides as the engine does:
  the peer (`REMOTE_ADDR`, before any proxy rule) is private, loopback or
  link-local AND `request_address($spec)` gives back the peer itself, so no
  forwarded visitor is believed. Absent and empty `trusted_proxies` mean the
  private-range default (only `none` trusts nothing), as `parse_trusted_proxies`
  reads them. It names the cause: (a) the peer is not in the effective trust set,
  or (b) it is trusted and no usable `X-Forwarded-For` arrives. No second parser.
  (A first version treated absent/empty as "names nothing" and so would have
  warned falsely on edge, where the default already trusts the front end.)
- `Lazysite::Auth::AddressLists::front_end_warning` makes the sentence, "Every
  visitor reaches this site from ADDR, ..." then, for (a), "which is not named in
  trusted_proxies (SET) ... Name the front proxy in trusted_proxies once its vhost
  appends the visitor's address ...; while it is older keep trusted_proxies: none",
  or for (b), "a trusted proxy, but no visitor address arrives in X-Forwarded-For
  ... rebuild its vhost (lazysite templates since 0.15.2, SM929). Until it is
  rebuilt set trusted_proxies: none (removing the line restores the default
  trust)". Both carry SM1194's account: an older front end passes a visitor's own
  header through, so the interim fix is `none`, never removing the line.
- The server carries it as `proxy_warning` in two answers the pages already call:
  `address-lists` (the Address lists page and the Groups page's address
  pickers) and `config-read` (the Config page, with the sign-in and manager
  address fields). It is absent when there is nothing to say. A page only
  shows it, as text, in a `#proxy-warning` note.
- Status surface: the manager has no check summary or health page, and
  `lazysite check` is not reachable from it, so none was built; the three
  pages above are where the fact is visible without a shell.
- Tests: t/unit/manager/365 (absent, empty or a naming list with no header: cause (b); `none` or another range: cause (a) naming the set; a list naming the peer with X-Forwarded-For, the default with the header, a public peer, no peer: silent) and 366 (the pages show it as text and hide it when absent). Both fail on the base.
