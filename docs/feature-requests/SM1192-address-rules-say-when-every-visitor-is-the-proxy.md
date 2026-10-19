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
status-note: "SHIPPED (PENDING) on n681: Lazysite::Util::unnamed_front_end, Auth::AddressLists::front_end_warning, the address-lists and config-read answers, three pages; t/unit/manager/365 and 366."
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

- `Lazysite::Util::unnamed_front_end($spec)` answers the peer's text when
  `REMOTE_ADDR` (before any proxy rule) is a private or loopback address and the
  `trusted_proxies` spec is absent, empty or does not hold it. It matches with
  `parse_trusted_proxies` and `_address_in_set`, the code `request_address` and
  the limiter use; there is no second parser.
- `Lazysite::Auth::AddressLists::front_end_warning` makes the sentence: "Every
  visitor reaches this site from ADDR, which is not named in trusted_proxies, so
  an address rule here applies to every visitor at once. Name the front proxy in
  trusted_proxies."
- The server carries it as `proxy_warning` in two answers the pages already call:
  `address-lists` (the Address lists page and the Groups page's address
  pickers) and `config-read` (the Config page, with the sign-in and manager
  address fields). It is absent when there is nothing to say. A page only
  shows it, as text, in a `#proxy-warning` note.
- Status surface: the manager has no check summary or health page, and
  `lazysite check` is not reachable from it, so none was built; the three
  pages above are where the fact is visible without a shell.
- Tests: t/unit/manager/365 (the answers: warning for a private or loopback peer
  with trusted_proxies absent, empty, `none` or naming another range; none for a
  named peer, a range holding it, a public peer or no peer) and 366 (the pages
  show it as text and hide it when absent). Both fail on the base.
