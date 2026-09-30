---
id: SM932
title: "SM932: the engine writes its diagnostics to a sink it cannot verify, and two releases have just been spent on what it says"
subtitle: "An operator grepped Apache's error_log through four failing submissions and found nothing; the same code from a terminal printed the error immediately. `log_event` has exactly two sinks - an unconditional `print STDERR`, and a syslog copy that is off unless configured - so on a FastCGI stack where a child's STDERR does not reach error_log, the engine's entire diagnostic voice is unreachable by default. 0.15.0 and 0.15.1 were largely about making the engine say what went wrong."
brand: plain
standard-margins: true
status: candidate
raised: 2026-09-30
raised-by: engine agent, verifying a related observation in the site agent's XMPP thread
area: observability
---

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

# What would fix it

Two directions, and the first is the one that matches how the engine already works
everywhere else.

**1. The engine owns a diagnostic log it can read back.** The audit trail and the
visitor log are both files under the site's tree that the engine writes and the
manager reads. Diagnostics are the one stream that is handed to somebody else and
never seen again. A file the engine owns would be readable by the manager, which
means an operator could see `cannot_read` warnings on the page where the symptom
is - and [[SM907]]'s six-state work on the audit trail is the template for getting
the unreadable-log case right rather than repeating it.

The same argument that made [[SM918]] worth building applies: an agent could then
read the diagnostics too, and the whole XMPP afternoon was an agent unable to see
what the engine was saying.

**2. `lazysite check` verifies reachability rather than assuming it.** Write a
known line at a known level, then try to read it back from wherever the engine
believes it goes. A check that says *"diagnostics are written to STDERR and I
cannot confirm anything collects it"* is worth more than any number of correctly
formatted WARNs nobody receives. This is the [[SM285]] self-probe idea applied to
the log path.

Neither is a small change and neither should be started on my judgement - (1) adds
a store, which has a permissions, rotation and disclosure surface, and the whole
point of this filing is that the reasoning behind "it logs a WARN" was not
examined. What wants deciding is whether the engine's diagnostics are its own
responsibility or the host's.

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
