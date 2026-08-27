---
title: "SM420: twenty subs that ate their caller's $_"
subtitle: "`while (<$fh>)` assigns the GLOBAL $_, so a sub that reads a file destroys the element under test when it is called from inside a grep. SM419 hit one of them; a survey found nineteen more."
brand: plain
standard-margins: true
status: shipped
status-note: "FIXED 2026-08-20, as its own change rather than swept into the security fix that found it. SM419's summary filter dropped its first path because is_blocked_config -> upload_limits -> load_upload_limits reads with `while (<$fh>)` and never localised - so the grep element under test was destroyed mid-comparison. A survey of lib/, the root scripts and plugins/ found 20 subs of that shape in total; all now carry `local $_;`. NONE OF THE OTHER NINETEEN IS PROVEN LIVE, stated plainly - each needs a caller that reaches it from inside a grep or map, and no such caller was traced. They are fixed anyway because the difference between latent and live is one caller, the fix is one line, and it cannot break anything: localising $_ changes nothing for a sub whose caller was not using it. t/lint/66 bans the shape outright so it cannot return. WHAT MAKES THIS CLASS NASTY, and why a lint rather than a code review: upload_limits MEMOISES, so only the FIRST call in a process clobbers - the first element of the first such grep comes back empty and every subsequent one is fine. A corruption that a second run hides is one nobody debugs; they re-run it, watch it pass, and move on."
---

# The shape

```perl
sub reads_a_file { open my $fh, ...; while (<$fh>) { ... } }   # assigns $_
...
grep { predicate($_) } @list        # loses the element under test
```

Perl's `while (<$fh>)` assigns the package global `$_` unless the sub
localises it. Every caller using `$_` implicitly - `grep`, `map`, a bare `for`
- has its loop variable overwritten from underneath.

# Why a lint and not a note

::: widebox
The memoisation is what makes it undebuggable. Only the first call clobbers, so
the symptom appears once and never reproduces. The engineer re-runs, sees
green, and concludes it was a fluke.
:::

Twenty subs is not a review finding, it is a house pattern - and the fix is one
line that cannot break a caller who was not relying on `$_`.

# Verification

`t/lint/66` walks `lib/`, the root scripts and `plugins/`, and fails on any sub
whose **code** (comments stripped) reads a filehandle into `$_` without
localising - sabotage-verified by removing a single localisation. Full gate:
469 files, 8,479 tests, PASS.
