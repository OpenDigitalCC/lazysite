---
id: SM925
title: "SM925: the XMPP notification path fails silently in three places at once"
subtitle: "An operator enabled notify-xmpp on a live site, configured eight fields including a password, and got nothing. Four rounds of debugging over an afternoon found three independent faults: the module was never installed and the enable path did not check, the port defaulted to 5222 while the account's SRV record said 47594, and the one error that named the cause was discarded by the caller. Each fault is separately fixable and each was invisible."
brand: plain
standard-margins: true
status: shipped
raised: 2026-09-30
raised-by: site agent, from an operator's live configuration on a customer site (0.15.0), four rounds
area: plugins
status-note: "SHIPPED (c32f96ed, 29c7432a) - ALL THREE FAULTS. X2 BUILT 2026-10-01 and the open question turned out not to need answering: the behaviour already existed in XMPP::Lite, this project's own library, and had been DROPPED when this flow was derived from it - notify-xmpp's header says delivery is 'based on the xmpp-lite connector' and XMPP::Lite both resolves SRV and tracks whether the port was explicit. Measured live: XMPP::Lite::_resolve_srv returns xmpp.project.im 47594 for project.im, dig agrees, and the notification hook on this host delivers through that path daily. So X2 is a REGRESSION against its own source, not a missing feature. THE RULE IMPLEMENTED IS THE OPERATOR'S AND IS STRICTER THAN XMPP::Lite's: SRV is consulted only when NEITHER host nor port is given; a conf naming either is obeyed and nothing is looked up (XMPP::Lite tracks only the port and would replace a host the operator set). A blank or non-numeric port is not a specification. Two additions XMPP::Lite lacks: a tight resolver timeout, with the lookup INSIDE the existing 15s alarm because that is the whole budget for DNS plus the connection in a CGI; and an SRV target of '.' refused per RFC 2782, which means the service is decidedly not available rather than being a hostname. The descriptor loses default => '5222' (a pre-filled port overruled the SRV record on every site whose operator left it alone) and declares Net::DNS beside Net::XMPP. THE ENDPOINT DECISION NOW HAS A NAME, _xmpp_endpoint, because the first test could only observe it by attempting a connection and reached the real server - a unit test making a live network call was a defect in the code's shape rather than the test's. Seven sabotages: six refused, and the seventh exposed a real limit in t/lint/201 (it requires SOMETHING declared and cannot know WHICH modules a plugin needs, so dropping Net::DNS left Net::XMPP and passed) - the assertion that notices sits in t/unit/lib/61 beside the code that made the dependency load-bearing. X1: notify-xmpp declares `owns => { deps => ['Net::XMPP'] }`, so the enable path refuses instead of accepting a password and delivering nothing. X3: form-handler reads `$@` from the notify eval and reports it (still falling through to the bell, because a notice must not be lost to a broken delivery path), and Notify::_xmpp_conf now distinguishes its FOUR causes - extension off (silent, a deliberate state), enabled-and-never-configured, a conf that will not open, and a conf missing a required key, which names the key. X2 ORIGINALLY WAITED ON ONE MEASUREMENT: whether Net::XMPP resolves SRV given a bare domain. If it does, the repair is to STOP OVERRIDING it rather than to add a resolver; if it does not, Net::DNS is not core, so X2's fix needs a dependency declaration of its own and must land with it rather than after it. Net::XMPP IS installed on this dev host, so absence could not be the test condition - t/lint/201 and t/unit/lib/57 use a name that cannot resolve and a conf that cannot open instead. THE AUDIT THE REPORT ASKED FOR WAS DONE AND ITS RESULT IS MOSTLY NEGATIVE, which is the useful part: 10 of 16 plugins have no `owns` block; of what the others reach for, form-smtp's Net::SMTP is required only when method=smtp (declaring it would wrongly refuse a sendmail-only site) and form-handler's DB_File is a top-level `use`, so the plugin cannot compile without it and --describe fails BEFORE any dep check can run - a hole in the mechanism, not a missing declaration, and recorded below rather than fixed here. TWO DETECTORS WERE WRONG BEFORE THE THIRD WAS RIGHT: scanning plugins/ for undeclared requires misses notify-xmpp entirely (the require is in Lazysite::Notify, the plugin is a descriptor), and flagging any Foo::Bar name in prose failed 12 of 16 on fully-qualified CALLS and on a comment this filing had just added. t/lint/201 keeps only the Debian-package signature, which is never incidental. Seven sabotages, seven refusals."
---

# The shape of it

Three faults on one path, none of which announced itself. The operator's
experience was four submissions and no chat message, with nothing on screen wrong
and nothing in a log they could reach.

```datatable
columns: # | Fault | Where | Repair
widths: 0.8cm | 5.2cm | 4.4cm | X
text: 2*3*4
bold: 2
tone: medium
---
X1 | `Net::XMPP` was never installed, and the plugin enabled cleanly without it | `plugins/notify-xmpp.pl` declares no `owns.deps` | declare the dependency the mechanism already reads
X2 | `port` defaulted to 5222 and `host` to the JID's domain, overruling the SRV record that gave `xmpp.project.im:47594` | `Lazysite::Notify:589-590`, and `default => '5222'` in the descriptor | blank defaults; resolve SRV when both are blank
X3 | The error naming X1 was generated, and thrown away by the caller | `plugins/form-handler.pl:641`, an `eval` whose `$@` is never read | report the failure; make `_xmpp_conf` say which of four causes it hit
```

All three are confirmed in the tree - see each item below. **Grade: measured on
the reporter's side (a live site, four rounds), and the code in every case reads
as reported; I confirmed each line locally rather than taking the citation.**

# X1 - the enable path has the check and this plugin opts out of it

`Lazysite::Manager::Plugins::_missing_deps` reads a plugin's own `owns.deps` (ADR
0009) and the enable path calls it. Two plugins use it and one that plainly needs
it does not:

```datatable
columns: Plugin | Declares `owns.deps` | Needs
widths: 4.4cm | 3.4cm | X
bold: 1
tone: medium
---
`login-rate-limit.pl:40` | `['DB_File']` | DB_File
`data.pl:139` | `[qw(DBI DBD::SQLite YAML::PP)]` | three modules
`notify-xmpp.pl` | **nothing** | **Net::XMPP**, named in its own header comment at line 9
```

The dependency is written down in prose three lines above where the declaration
belongs. So the fact was known; it is simply not in the field the machinery
reads. The repair is one line:

```perl
owns => { deps => ['Net::XMPP'] },
```

**Why it matters more here than for the siblings.** A missing `DBI` announces
itself the first time anybody opens the Data page. A missing `Net::XMPP`
announces itself by notifications not arriving - on the one plugin whose whole
purpose is to tell you that something happened. There is no page to open and
nothing to compare against, and the honest reading of silence is "nothing has
happened yet".

**The sweep this implies, and it is not optional.** Two descriptors declare deps,
one that needs them does not. Nobody has counted the third category. `Net::XMPP`
is not core and neither is anything else a plugin reaches for, so the question
"how many other descriptors are in notify-xmpp's position" has an answer and we
do not have it. That is a lint as much as an audit: a plugin whose source names a
non-core module in a `require`, a `use`, or a comment, and whose `owns.deps` does
not name it, is the signature.

## Done 2026-09-30, and the proposed signature above is WRONG

The sweep ran (`tmp/sm925-dep-audit.pl`). The answer is mostly negative, and the
two failed detectors are worth more than the count.

**10 of 16 plugins have no `owns` block at all**, so they never reach the dep
check. That is not itself a defect: with no `deps` and no `bins` there is nothing
to check, so an absent block and an empty one behave identically. What it means is
that nobody is forced to think about it.

Of the modules the others reach for, neither should be declared:

```datatable
columns: Plugin | Module | Why declaring it would be WRONG
widths: 3.0cm | 2.6cm | X
text: 3
bold: 1
tone: medium
---
`form-smtp` | `Net::SMTP` | `require`d inside `send_via_smtp`, reached only when `method=smtp`. A hard dep would refuse to enable the plugin on a sendmail-only site, which is most of them
`form-handler` | `DB_File` | a TOP-LEVEL `use`, so the plugin cannot compile without it - `--describe` fails, `_describe` returns nothing, `_missing_deps` returns before checking, and enable proceeds. A hole in the MECHANISM, not a missing declaration
```

That second row is a real finding and is not fixed here: **the dep check needs the
descriptor, and the descriptor cannot be read if the plugin cannot compile.** The
repair is to move such a `use` to a runtime `require` and then declare it - a
behaviour change in a core plugin, larger than X1, and not something to do while
passing.

**The signature proposed above does not work, and both versions were built before
that was clear.** Scanning plugin sources for an undeclared `require` misses
notify-xmpp entirely, because the `require Net::XMPP` is in `Lazysite::Notify:585`
and the plugin is only a descriptor - the audit's first run flagged the two rows
above and not the one the report was about. Widening it to any `Foo::Bar` name in
prose failed 12 of 16 plugins on `Cwd::abs_path`, `JSON::PP::true` and
`Digest::SHA::sha256_hex` - fully-qualified *calls* - and on a comment this filing
had just added to `form-handler.pl`. A detector that cannot tell "depends on" from
"mentions" is noise.

`t/lint/201` keeps the one signature that is never incidental: a **Debian Perl
package name**. `libnet-xmpp-perl` appears when somebody is telling an operator
what to install, which is precisely the moment the enable path should have been
told too. Two plugins carry one, and before this build one of the two declared
nothing.

# X2 - a default that contradicts a discoverable fact

```perl
my $host = length( $conf->{host} // '' ) ? $conf->{host} : $domain;
my $port = ( $conf->{port} // '' ) =~ /^\d+$/ ? $conf->{port} : 5222;
```

and in the descriptor, `{ key => 'port', ..., default => '5222' }`, so the form
**pre-fills** it. An operator who never touches the field has silently asserted a
port, and asserted it wrongly for every server that publishes something else. The
`host` note says it defaults to the JID's domain, which is the precise assumption
SRV exists to correct.

The account's own domain published the answer:

    $ dig +short SRV _xmpp-client._tcp.project.im
    10 0 47594 xmpp.project.im.

**The rule, in the operator's words:** *"that suggests that the default should
leave port blank, instead of assuming, so either let SRV do its job or specify."*
That is better than what the report had drafted and it is the whole change:

- **both blank** - resolve `_xmpp-client._tcp.<jid domain>`, use the target and
  port it returns, and fall back to `<domain>:5222` only when there is no record,
  which is what a fallback is for;
- **either set** - use exactly what was given and look nothing up;
- **remove `default => '5222'`** from the descriptor so the field is genuinely
  empty, with a note saying that blank means "use the SRV record".

A defaulted value that contradicts a discoverable fact is worse than no value: it
looks like a decision somebody made, so nobody questions it.

**One thing this fault did right, worth keeping.** Once `Net::XMPP` was present
the connect failure named the host and port it tried, and that is what let the
operator spot the mismatch. That message is doing its job and should survive the
change.

**Not yet established: what resolves SRV here.** `Net::DNS` is the obvious
answer and is not core, so X2's repair may itself add a dependency - which puts
it straight into X1's mechanism, and the declaration must land with it rather
than after it. Whether `Net::XMPP` already resolves SRV when given a bare domain
is worth checking before building anything: if it does, the repair is to stop
overriding it rather than to add a resolver.

# X3 - the error that explained everything, discarded

```perl
my $sent = eval {
    unless ( $INC{'Lazysite/Notify.pm'} ) { _locate_lib(); require Lazysite::Notify; }
    Lazysite::Notify::notify( $DOCROOT, {
            type => 'submission', message => "New form submission: $f",
            target => $f, url => '/manager/plugins',
    } );
};
return if $sent;
```

`$@` is never read. The `require` is inside the `eval`, so **X1's error -
`Can't locate Net/XMPP.pm in @INC`** - was raised here, on every submission, and
dropped. The one sentence that would have ended the afternoon in its first
minute was produced and thrown away.

`_xmpp_conf` compounds it: it returns `undef` for four distinct causes with no log
on any of them - no config file, an unreadable one, a missing required key, and a
malformed value are one answer. That is exactly the four-state shape SM906, SM907
and SM917 have been working through elsewhere in the tree, and this is the same
defect in the notification path.

**The repair has two halves.** Report the `eval`'s failure rather than only its
success - `$sent` false with `$@` set is a different state from `$sent` false
with `$@` empty, and the caller currently cannot tell them apart. And make
`_xmpp_conf` name which of the four causes it hit, via `cannot_read` where the
cause is a read and a WARN where it is a value.

**Where the reported diagnosis was wrong, in the reporter's own words.** The
filing opens *"The diagnosis in this filing was wrong and the prediction in it is
withdrawn"* - it had predicted a specific cause and the real causes were X1 and
X2. The discarded `$@` is what survived, and it survived because it is what made
the wrong diagnosis possible. That correction is the reason this item is filed as
a defect rather than as a theory.

# What ties the three together

Each fault is small. What made them cost an afternoon is that they compose: X1
broke it, X3 hid the reason, and X2 was waiting behind X1 to break it again once
X1 was fixed. Two of the four debugging rounds were spent re-establishing that
the configuration was correct, which it was.

The affordance that would have collapsed all three into one click is filed
separately as SM927 - a test button on the config form, which `form-smtp`
already has.

# The related finding that is bigger than this filing

The operator grepped Apache's `error_log` through all four submissions and found
nothing about XMPP, while the same code from a terminal printed the error
immediately. `log_event` writes to STDERR, and on that install - nginx to Apache
to `proxy_fcgi` - a FastCGI child's STDERR does not reach `error_log`. An hour of
X1's cost came from reasoning about an absence that meant nothing.

That is not a notification defect and it is filed as [[SM932]], because it
applies to every diagnostic the engine writes, including the ones 0.15.1 added.

# Related

SM136 (the notification path itself - shipped 0.6.3, recorded in BACKLOG.md with
no filing of its own, so the number is a pointer to the CHANGELOG rather than to a
document), [[SM694]] (a plugin may depend on a program,
not only a module - the same declaration), [[SM926]] (the third reader of
`site_url`, on this same path), [[SM927]] (the test button), [[SM928]] (the
message's content), [[SM932]] (whether any of these logs can be read at all),
[[feedback_absence_is_a_finding]], [[feedback_a_boolean_has_four_states]],
[[feedback_a_declaration_the_code_ignores]].
