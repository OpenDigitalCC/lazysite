---
id: SM927
title: "SM927: the XMPP config form has no test button, and its sibling has one"
subtitle: "form-smtp declares a `validate` action and the config page shows a Validate SMTP connection button. notify-xmpp declares no actions at all, so an operator who has just typed eight fields including a password has no way to learn whether any of it works until a real event fires - and if it does not fire, nothing tells them. Three separate defects filed the same day would each have been a one-click finding."
brand: plain
standard-margins: true
status: shipped
raised: 2026-09-30
raised-by: site agent, from an operator's request during a live configuration (0.15.0)
area: plugins
status-note: "SHIPPED (PENDING ref) 2026-10-01. notify-xmpp declares `actions => [{ id => 'test', label => 'Send a test notification', needs => 'jid' }]` and answers `--scan --docroot DIR`, the same shape form-smtp's validate uses; `needs` is the existing gate (git-sync's test connection uses it) so the button is never a test against nothing. THE STAGING LIVES IN Lazysite::Notify WITH THE DELIVERY IT TESTS, not in the plugin: `_xmpp_send` takes an optional steps collector and records library, jid, endpoint, connect, auth, join and send as it passes each, so what the test exercises IS the delivery path rather than a second implementation that agrees with it until the release where it stops. Six stages on the happy path, each named in the result and rendered one per line on the config page. THE THREE DEFECTS OF 2026-09-30 ARE EACH NOW ONE PRESS: X1 as a `library` stage naming libnet-xmpp-perl (it was Perl's @INC paragraph before), X2 as an `endpoint` stage that says WHERE the endpoint came from - `as configured`, `from the domain's SRV record`, or `nothing else was published` for a defaulted 5222 - and SM926 because `sent` carries the rendered body VERBATIM, through the same _template/_render path a real notice uses, so a site that overrode default.xmpp has its own template tested and a `${REQUEST_SCHEME}://${SERVER_NAME}` that cannot interpolate is visible rather than described. THE MUC JOIN IS REPORTED AS UNCONFIRMED AND THE FILING'S HOPE FOR IT IS ONLY PARTLY MET: this path sends a join presence and reads nothing back, so a room that refuses one answers nowhere this code looks - 'authenticated but the room refused the join' is separated from 'could not connect at all' as far as the protocol flow allows and no further, and the step says so in its own text rather than claiming a success. THE TEST WRITES NO BELL ROW and is not a notify() call, because the reporter's only available test was a real submission - which left a stored row only a person can delete (SM924) and only exercised this path if it escaped the quarantine (SM216). The body announces itself as a TEST and says nothing needs doing, because the recipient is often a shared room. X3's four config states now reach the OPERATOR as well as the log: `_xmpp_conf` became `_xmpp_conf_or_why`, returning the config and the reason there is none - RENAMED deliberately, because `return ( undef, $why )` in scalar context yields the reason, which is true, so an un-updated call site would have sent with it; a rename makes that a compile failure instead, and t/unit/lib/57 now pins both voices so a state cannot keep one and lose the other. ALSO FIXED HERE, FOUND WHILE BUILDING: X2's SRV lookup had made t/unit/lib/26 issue five REAL DNS queries per run from the unit suite (measured with tmp/does-t26-hit-dns.pl); the resolver is stubbed there now, which also makes 'the port defaults to 5222' a fact about this code rather than about the public DNS, and a new case asserts the SRV endpoint reaches Connect rather than only _xmpp_endpoint. The notify test set now attempts no live lookup at all - the one apparent exception, t/unit/lib/61's `invalid..example`, is refused inside Net::DNS ('empty label') before a packet leaves the host. Twelve sabotages, twelve refusals. NOT DONE, and deliberately: the filing's wider question - whether ANY plugin holding credentials for a remote endpoint should be REQUIRED to declare a test action, which would make the absence a lint - stays open, because the population has not been counted. t/lint/108's inline-style ceiling held the report container to the `hidden` attribute instead of a style attribute."
---

# Measured

From the plugin declarations:

```datatable
columns: Plugin | Actions | Config fields
widths: 3.2cm | 3.6cm | X
text: 3
bold: 1
tone: medium
---
`form-smtp` | `validate` - "Validate SMTP connection" | method, sendmail_path, host, port, tls, auth, username, password, password_file
`notify-xmpp` | **none** | jid, password, to, muc, host, port, tls, nick
```

Two delivery plugins, configured on the same page, with the same shape of failure
- a wrong host, a wrong port, a wrong TLS setting, a rejected password, a
recipient that does not exist. One can be tested from the form. The other cannot.

**Eight fields including a password with no feedback** is also the shape that
invites a second and third attempt at the same guess.

# Why it matters more on this plugin than on its sibling

The failure is silent and delayed. SMTP failing is usually noticed because
somebody expected an email. An XMPP notification that never arrives looks exactly
like a quiet site: no event to see, nothing to compare against, and the
operator's reasonable conclusion is *"nothing has happened yet"* rather than *"my
configuration is wrong"*.

The thing it notifies about is **new form submissions**. On the site this was
found on, nine enquiries accumulated over sixteen days with no delivery
configured at all - three genuine, one a production support case naming a systemd
exit status, unanswered for sixteen days. The whole value of the plugin is that
the gap does not happen.

# What this button would have caught, by the day's own record

Three defects were filed on 2026-09-30 from the same afternoon. A test at config
time would have surfaced each of them in one click:

```datatable
columns: Filing | What went wrong | What a test would have said
widths: 2.0cm | 5.0cm | X
text: 2*3
bold: 1
tone: medium
---
[[SM925]] X1 | `Net::XMPP` not installed | "could not load the XMPP client library"
[[SM925]] X2 | port 5222 asserted over an SRV record giving 47594 | "connect to project.im:5222 failed"
[[SM926]] | the message body carried `${REQUEST_SCHEME}://${SERVER_NAME}` | the operator would have SEEN the payload
```

That last one is the argument for showing the message rather than only a verdict.
SM926's defect was invisible for the whole afternoon and became obvious the
instant a human read what had been sent.

# What it would take

`form-smtp` has the pattern already: an action declared in the plugin, run from
the config page, reporting what happened. For XMPP the equivalent is connect,
authenticate, join the room if `muc` is set, send one message to `to`, and say
which of those steps succeeded.

**The step-by-step part matters more than the pass/fail.** "Authenticated but the
room refused the join" and "could not connect at all" send the operator to
different settings; a bare failure sends them back through all eight fields.

Two details worth getting right:

- **Send something a person will recognise as a test.** The room may be shared
  with a team, and a test that reads like a real alert trains people to ignore
  real alerts.
- **Show the rendered message**, not just the outcome, for the reason above.

# What the absence cost, and why a real submission is not a substitute

The reporter's test had to be a real form submission on a live site. That is a
poor substitute three ways: it leaves a stored row that only a person can delete
(submission delete is cookie-only - [[SM924]]), it only exercises the path if the
submission escapes the spam quarantine, and so it can fail for a reason entirely
unrelated to XMPP.

The operator's words, worth keeping: *"it would be good to know that it works at
the point of config."*

# Scope worth deciding rather than assuming

This filing is written about `notify-xmpp` because that is where it was found.
The general question is whether **any** plugin that holds credentials for a remote
endpoint should be required to declare a test action - which would make the
absence a lint rather than a filing, the way [[SM925]] X1's missing dependency
should have been. Not proposed here, because the population has not been counted.

# Related

[[SM925]] (the three faults this would have caught), [[SM926]] (the payload it
would have shown), [[SM928]] (what the message should contain), [[SM216]]
(quarantine, which a test submission has to get past), [[SM924]] (why the test
row could not be cleaned up),
[[feedback_a_boolean_has_four_states]] (a notification that never arrives and a
site where nothing happened look identical).
