---
id: SM932
title: "SM932: the engine writes its diagnostics to a sink it cannot verify, and two releases have just been spent on what it says"
subtitle: "An operator grepped Apache's error_log through four failing submissions and found nothing; the same code from a terminal printed the error immediately. `log_event` has exactly two sinks - an unconditional `print STDERR`, and a syslog copy that is off unless configured - so on a FastCGI stack where a child's STDERR does not reach error_log, the engine's entire diagnostic voice is unreachable by default. 0.15.0 and 0.15.1 were largely about making the engine say what went wrong."
brand: plain
standard-margins: true
status: partial
raised: 2026-09-30
raised-by: engine agent, verifying a related observation in the site agent's XMPP thread
area: observability
status-note: "PARTIAL - the ruling is BUILT, the deferred half is not. SHIPPED (b1556284): forward_diagnostics becomes a LEVEL whose default is WARN and above, so every install has a second sink without any configured install changing behaviour (on/true still means every level); the threshold lives in forward_line so the four plugin log_event copies inherit it; _forward_conf's silent conf read now captures $! and reports after %FWD is built behind its own latch, which is the only way it can report at all since log_event arrives through it; an unrecognised value is named rather than coerced; the log.pl descriptor loses its `default` key (the SM925 X2 trap). Tests: t/unit/lib/56 (seven states), t/unit/forms/12 gains the no-key-still-forwards case and spells its `off` case explicitly. Seven sabotages, seven refusals. Docs: FEATURES, OPERATOR, starter configuration and ai-briefing-configuration, four plugin comments. NOT BUILT and deliberately so: (1) the engine-owned diagnostic log the manager and an agent could read - DEFERRED, not refused, because syslog is the HOST operator's log and a site operator still sees nothing; OP-29's fleet measurement should decide whether it is still wanted now two sinks exist. (2) the `lazysite check` reachability probe, which is worth MORE after this change than before it - two sinks means two things that can each fail quietly, and syslog fails the quieter of the two because _forward_warn reports at most once per process. Neither is scheduled. ORIGINAL RULING TEXT: RULED 2026-09-30, NOT BUILT. The release manager ruled TURN SYSLOG FORWARDING ON BY DEFAULT and fix _forward_conf's silent failure - the smallest change that gives the engine a second sink, using a mechanism already built, tested and documented rather than adding a store. RECOMMENDED THRESHOLD, measured and offered for acceptance rather than assumed: forward WARN and above by default, leaving INFO and DEBUG to the existing forward_diagnostics key. The census says WARN is where the work lives (cannot_read logs at WARN; 804 WARN and 234 ERROR call sites against 704 INFO) and a WARN-and-above default changes no install's INFO volume. Say the word and it forwards everything. _forward_conf CANNOT take a plain cannot_read branch - log_event calls it and would recurse; the file already solves the analogous case with the $fwd_warned++ once-per-process latch in _forward_warn, and that is the pattern to use. WHAT THIS RULING DOES NOT CLOSE, and it is deliberate: a site operator who is not the host operator still cannot read syslog, so the manager still shows nothing and an agent still cannot read diagnostics. The engine-owned log (option 1) is DEFERRED, not refused. OP-29 is the measurement that says whether it is still needed."
---

# The ruling, and it is built

**RULED 2026-09-30: turn syslog forwarding on by default**, and fix
`_forward_conf`'s silent failure at the same time. **Both are built** - see the
status-note for what shipped and what is deliberately still open. The two larger
directions further down are unchanged and neither is scheduled.

One thing the build settled that the ruling did not specify: `forward_diagnostics`
had to stop being a boolean, because "on by default at WARN and above" is not a
state a boolean can hold. It is now a level - blank for the default, `off`, a
level name, or `on` for every level - and `on` keeping its old meaning of *every*
level is what makes the change invisible to any site that had already configured
it.

The reasoning is that this is the smallest change that removes the single point of
failure. `forward_diagnostics` is already built, already tested and already
documented; it is off. Flipping it means the engine has **two** sinks rather than
one unverifiable one, and "nothing reached anybody anywhere" stops being the
default outcome. No new store, and therefore no permissions, rotation or
disclosure decisions to take before anything improves.

**What it does not close, and this is deliberate.** A site operator who is not the
host operator cannot read syslog either. The manager still shows nothing, and an
agent still cannot read the engine's diagnostics - which was the actual gap in
[[SM925]]'s afternoon. The engine-owned diagnostic log is **deferred, not
refused**, and OP-29's measurement is what should decide whether it is still
needed once there are two sinks.

So this ruling buys the cheap half now and keeps the expensive half as a question
with evidence attached, rather than spending a release on a store before knowing
whether syslog was enough.

# The threshold, which is measured rather than assumed

A default change lands on every install, so the risk that decides **how** to build
this is volume: `log_event`'s default minimum level is `INFO`, so forwarding at the
default level would copy every INFO line on every install into syslog.

The call-site census:

```datatable
columns: Level | Call sites, whole tree | In the processor (per-request path)
widths: 2.4cm | 4.0cm | X
text: 2*3
bold: 1
tone: medium
---
WARN | 804 | 43
INFO | 704 | 7
ERROR | 234 | 8
DEBUG | 36 | 2
```

**Recommended: forward WARN and above by default**, leaving INFO and DEBUG to the
existing key. Two reasons, and both are in the numbers:

- **WARN is where the work lives.** `cannot_read` logs at WARN (`Util.pm:74`), so
  every repair in the 0.15.1 sweep that this filing is about is delivered by a
  WARN-and-above default. Forwarding INFO adds nothing to the problem being fixed.
- **It changes no install's INFO volume**, which is the only way a default flip can
  make somebody's day worse. The render path carries 7 INFO sites against 43 WARN,
  so the hot path is not INFO-chatty either way - but "not chatty" is a weaker
  claim than "unchanged".

This is offered for acceptance rather than taken: forwarding everything is one word
different, and if the intent was a full copy of the stream then that is the build.

**What the census does NOT establish**, said plainly because I got this wrong twice
during [[SM917]]: these are call SITES, not emitted events. A per-request count of
lines actually written is a different measurement and I have not made it. The
argument above does not need one - it rests on which levels carry the work, not on
how many lines there are - but nobody should read 704 as a rate.

# The second half of the ruling

`_forward_conf` (`Util.pm:306`) is the code that decides whether forwarding
happens, and it reads its own configuration with no else branch. Turning the
default on makes that read load-bearing rather than incidental: a site whose
`lazysite.conf` cannot be read would now silently lose a sink it is supposed to
have by default.

It **cannot** take a plain `cannot_read` branch. `log_event` calls `forward_line`
which calls `_forward_conf`, so reporting the failure through `log_event` would
recurse. The file already solves exactly this shape - `_forward_warn` guards with a
`$fwd_warned++` once-per-process latch, incremented *before* its own nested
`log_event` for that reason - and that is the pattern this call site needs.

# What was observed, and by whom

Not my finding. While debugging [[SM925]], the site agent spent an hour reasoning
from an absence:

> *"The error above was being generated and logged correctly all along -
> `log_event` writes it to STDERR. The operator's Apache error log, grepped
> repeatedly, contained no line about XMPP during any of the four submissions; the
> same code run from a terminal printed it immediately. ... I reasoned for an hour
> from 'a failure would log' and eliminated six gates on the strength of an absence
> that meant nothing."*

Their install is nginx to Apache to `proxy_fcgi`, where a FastCGI child's STDERR
does not necessarily land in Apache's `error_log`.

That is their measurement on their host, and I am not in a position to reproduce
it. **What I can check is whether the engine's design makes it possible, and it
does.**

# What I verified in the tree

`Lazysite::Util::log_event` (`:217-247`) has exactly two sinks:

```perl
print STDERR "$line\n";
my %prio = ( DEBUG => 'debug', INFO => 'info', WARN => 'warning', ERROR => 'err' );
forward_line( 'diag', $prio{$level} // 'info', $line );
```

```datatable
columns: Sink | When it is live | Who controls whether it can be read
widths: 3.4cm | 4.6cm | X
text: 3
bold: 1
tone: medium
---
`print STDERR` | **always** | the host's web-server wiring - not the engine, and not the operator through anything the engine offers
`forward_line('diag', ...)` | only when `forward_diagnostics` is on in `lazysite.conf` (or `LAZYSITE_FORWARD_DIAGNOSTICS` is set); **off by default** | the operator, if they know the key exists
```

So **by default the engine's only diagnostic sink is one it neither owns nor can
verify.** Every `log_event` in the tree - `cannot_read`'s WARN included - is
written on the assumption that somebody downstream is collecting STDERR, and
nothing anywhere establishes that.

This is not the same as "the logs are broken". On a conventional `mod_cgi` Apache
site STDERR does reach `error_log` and everything works as intended. The defect is
that the engine cannot tell the difference, and neither can the operator.

# Why this is filed now rather than noted

0.15.0 and 0.15.1 were substantially about making the engine say what went wrong.

```datatable
columns: Filing | What it added | Delivered through
widths: 2.0cm | 5.6cm | X
text: 2*3
bold: 1
tone: medium
---
[[SM906]] / [[SM907]] | an unreadable store stops reading as an empty one | a WARN naming file, error and unix user
[[SM917]] | 51 read sites triaged; `cannot_read` on every store reader that had been silently returning empty | the same WARN
[[SM918]] | the notice store reports `store_unreadable` rather than an empty bell | a return value **and** a WARN
[[SM925]] X3 | make `_xmpp_conf` say which of four causes it hit | a WARN
[[SM931]] item 2 | notice when a render multiplied protected content | a `log_event`
```

On the stack this was found on, the WARN column is unreachable. The repairs are not
worthless - most of them also changed **return values**, which is the half that
reaches the caller and the manager regardless of where STDERR goes: `cannot_read`
returns undef rather than empty, the notice store sets `store_unreadable`, the
audit trail names which of six states it is in. Those still work.

But the diagnostic half of two releases' work lands in a place the operator may not
be able to read, and every one of those filings was written on the assumption that
"it logs a WARN" was a delivered outcome. It is a delivered *attempt*.

**The honest statement of the exposure:** I have not established how many
production installs are affected. The one measured case is the customer site in
[[SM925]]. Our own edge site and the whole fleet run behind the same front-proxy
arrangement, which is the reason this is not being filed as somebody else's
configuration problem - it wants measuring, and that measurement is a row on the
next test plan rather than a claim here.

# A second finding, in the forwarding path itself

`_forward_conf` (`Util.pm:306`) is the code that would route around the STDERR
problem, and it reads its own configuration like this:

```perl
if ( defined $dir && open my $fh, '<', "$dir/lazysite.conf" ) {
```

No else. An unreadable `lazysite.conf` silently leaves `forward_diagnostics` off -
so the one mechanism that would have made the engine's voice reachable fails in
exactly the four-state way [[SM917]] spent 0.15.1 removing everywhere else.

**And it cannot simply be given a `cannot_read` branch**, which is why it is
interesting rather than just another instance. `log_event` calls `forward_line`,
which calls `_forward_conf`; reporting a failure here through `log_event` would
recurse. The file already guards the analogous case - `_forward_warn` uses a
`$fwd_warned++` once-per-process latch for exactly this reason - so the pattern
exists and this call site does not use it.

That makes it a real instance of SM917's family with a real constraint, rather than
a site my sweep should have caught and missed: lint 121 passes it because the path
is site config rather than a store, which is correct as the lint is written.

# The two larger directions, one deferred and one still worth doing

Kept as written, because the ruling above takes neither and both remain live. What
the ruling does is buy a second sink cheaply first, so that these two are decided
against measurement rather than against a fear.

**1. The engine owns a diagnostic log it can read back. DEFERRED, not refused** -
this is the one the ruling explicitly holds back, and OP-29's answer is what should
settle it. The audit trail and the
visitor log are both files under the site's tree that the engine writes and the
manager reads. Diagnostics are the one stream that is handed to somebody else and
never seen again. A file the engine owns would be readable by the manager, which
means an operator could see `cannot_read` warnings on the page where the symptom
is - and [[SM907]]'s six-state work on the audit trail is the template for getting
the unreadable-log case right rather than repeating it.

The same argument that made [[SM918]] worth building applies: an agent could then
read the diagnostics too, and the whole XMPP afternoon was an agent unable to see
what the engine was saying.

**2. `lazysite check` verifies reachability rather than assuming it. STILL WORTH
DOING, and more so after the ruling.** Write a known line at a known level, then try
to read it back from wherever the engine believes it goes. A check that says
*"diagnostics are written to STDERR and I cannot confirm anything collects it"* is
worth more than any number of correctly formatted WARNs nobody receives. This is
the [[SM285]] self-probe idea applied to the log path.

The ruling makes this **more** valuable rather than less: with two sinks there are
now two things that can each silently fail, and syslog failing is quieter than
STDERR failing because `_forward_warn` reports it at most once per process. A check
that names which sinks carried the test line is the only way an operator learns
they have none.

It is not part of the ruling and it is small enough to build with the default flip
rather than after it. Flagged rather than assumed.

# The lesson, which is the reporter's and is worth adopting

Theirs, filed on their side as *a silent log is not a silent code path*: an absence
of log lines is not evidence that a code path did not run, unless you have first
established that a line from that path would have arrived. They eliminated six
gates on the strength of one.

It generalises past logs, and the house already has the rule in another form -
[[feedback_negative_finding_needs_a_discriminating_measure]]. An absence is only
evidence when presence was possible.

# Related

[[SM925]] (where the hour was lost), [[SM906]], [[SM907]], [[SM917]], [[SM918]]
(the repairs whose diagnostic half this affects), [[SM931]] (whose proposed check
is a `log_event`), [[SM285]] (the self-probe pattern),
[[feedback_negative_finding_needs_a_discriminating_measure]],
[[feedback_absence_is_a_finding]], [[feedback_silent_means_no_output]],
[[feedback_name_the_environment_never_guess]].
