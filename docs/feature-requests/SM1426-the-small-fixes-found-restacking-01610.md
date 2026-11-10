---
id: SM1426
title: "SM1426: the sign-in's marker has one writer, and the package recommends git"
subtitle: "The sign-in wrapper wrote its own copy of the lzs_session marker line instead of the helper the renewals use. The common package did not recommend git, which content history runs."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-10
raised-by: "release manager, the 0.16.10 restack"
area: auth
status-note: "SHIPPED (PENDING): lazysite-auth.pl sets the sign-in's lzs_session marker through Lazysite::Auth::Session::session_marker_header, with the same attributes; t/lint/592 holds the line to that one writer and fails without the change."
---

# What happened

SM1425 gave the signed-in marker one helper, `Lazysite::Auth::Session::session_marker_header`,
used by `session_cookie_headers` and by both renewals. The sign-in wrapper
`lazysite-auth.pl` still printed its own copy of the header line, so a change to the
marker's attributes could reach the renewals and miss the sign-in.

# What changed

`lazysite-auth.pl` prints the helper's line. The attributes are unchanged: `SameSite=Lax`,
`Path=/`, `Max-Age` from `session_lifetime`, and `Secure` over HTTPS. The module was
already loaded there, so nothing new is loaded.

# Tests

t/lint/592 reads every engine program and module and holds the line that sets the marker
to `Lazysite::Auth::Session` alone, and checks the wrapper calls the helper. It fails with
the change reverted. t/unit/auth/74 and 75 still pass.
