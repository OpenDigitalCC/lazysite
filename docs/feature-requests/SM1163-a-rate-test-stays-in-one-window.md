---
id: SM1163
title: "SM1163: a rate test stays in one window"
subtitle: "The tests that count attempts against a fixed rate window now begin where the whole run fits one window, through one helper."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-17
raised-by: "lazysite developer agent, from the 2026-10-17 integration run"
area: tests
status-note: "SHIPPED on n646: t/lib/RateWindow.pm, t/unit/auth/66-a-rate-test-stays-in-one-window.t and the guards in seven existing tests; no product change."
---

# What happened

`t/unit/account/02-a-member-acts-only-on-their-own-account.t`, block "rate limit:
guessing the password behind a stolen session" (SM1043), makes six wrong
`me-password` calls and expects the sixth refused with kind `rate`, then the
right password refused too. In the 2026-10-17 integration
(`tmp/wt-integration/tmp/suite.log`) it failed:

    got 'forbidden' (not 'rate') for the sixth guess
    then the right password succeeded (undef)

The site was built at 17:19:55 and the guesses ran across the 17:20:00 boundary.
`Lazysite::Auth::LoginRate` counts in FIXED windows, `int(time()/300)`, so the
counter restarted at the boundary and the sixth guess was the second of a new
window. It passed on rerun and was not caused by the branches under test.

# What shipped

`t/lib/RateWindow.pm` has one function, `stay_in_one_window($window, $need)`:
if fewer than `$need` seconds remain in the current fixed window it sleeps to the
start of the next, so a run of counted attempts cannot straddle a boundary. It
sleeps only in the last `$need` seconds of a window.

Used before the first counted call in:

- `t/unit/account/02-a-member-acts-only-on-their-own-account.t` (60 s, the window
  read from the module)
- `t/unit/auth/03-login-rate-limit.t`, `04-login-rate-failopen.t`,
  `25-the-rate-limiter-is-an-extension.t`: their hand-rolled 8 s guards, now the
  shared one
- `t/unit/dav/01-gates-auth.t`: the DAV limiter's seed and request
- `t/unit/manager/04-upload-rate-limit.t` and the rate block of
  `t/integration/05-files-upload-download.t`: the hourly upload budget

Looked at and left: `t/unit/manager/228` already detects an hour change and
reruns; `t/unit/manager/109` makes one counted call; `t/unit/forms/30` and the
form-handler tests use a rolling hour, not a fixed window; the CSRF-token
`int(time()/3600)` uses are not counters.

Proof: `t/unit/auth/66-a-rate-test-stays-in-one-window.t` shortens the real
limiter's window to two seconds through its package variable (no production
knob), parks the clock a quarter second before a boundary and makes six
attempts 0.1 s apart. Unguarded, the sixth is let through; with the helper all
six are counted in one window and the sixth is refused. Removing the helper call
makes it fail every time.

Noted, not changed: a fixed window lets up to 2x`LOGIN_MAX` attempts through
across a boundary; that is a candidate for a ruling, not this fix.
