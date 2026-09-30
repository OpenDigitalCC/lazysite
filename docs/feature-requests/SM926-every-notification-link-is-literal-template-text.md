---
id: SM926
title: "SM926: every notification link is literal template text, because Notify is the third reader of `site_url`"
subtitle: "The first XMPP message to arrive on a live site carried the URL `${REQUEST_SCHEME}://${SERVER_NAME}/manager/plugins`. Three pieces of the engine read `site_url`: the processor interpolates it against a reviewed allowlist, a tool hand-rolls the same interpolation with a comment explaining why it must, and Lazysite::Notify has its own seven-line reader that returns the raw line. The RM has already ruled that `base_url` is not the fix."
brand: plain
standard-margins: true
status: partial
raised: 2026-09-30
raised-by: site agent, from a live site (0.15.0), after the delivery path was proved end to end
area: notifications
status-note: "PARTIAL - the defect is FIXED (PENDING ref); the consolidation of the THIRD reader is deliberately not done. SHIPPED: the allowlist moves to Lazysite::Util, Notify interpolates through it, and t/lint/202 pins the processor's own copy identical variable-for-variable (the render path is module-free per ADR 0001, so it keeps a copy - the arrangement lint 198 makes for _cannot_read). A case neither other reader has: NO REQUEST CONTEXT AT ALL - a cron- or CLI-driven notice has no SERVER_NAME, interpolation would correctly yield `://`, and emitting that is worse than emitting nothing because it looks like a link; so an incomplete expansion yields EMPTY and the template's `[% base %]/path` degrades to an absolute path. Also fixed: _conf_value no longer collapses an absent lazysite.conf and one that will not open into ''. NOT DONE, and this is the interesting half: tools/lazysite-users.pl::_site_base_url still hand-rolls its own two variables. THIS FILING'S OWN OPEN QUESTION WAS ADVANCED AND IS WORSE THAN IT SUPPOSED. Half settled: _claim_url IS reachable from a CGI-invoked `--api` action (account-approve; users_tool_api uses open2 and inherits %ENV), so a claim URL can be built with CGI env present. The other half: the processor's comment excludes HTTP_HOST as 'request-supplied and untrusted' and directs callers to SERVER_NAME - but Apache's UseCanonicalName defaults to OFF, under which SERVER_NAME is TAKEN FROM THE HOST HEADER, and none of the four shipped vhost examples (installers/apache/vhost*.conf.example) sets it On. So on a default install the exclusion buys nothing, and consolidating the third reader would bake that assumption in harder. Needs a ruling - a vhost default, or a policy about which host variable the engine trusts - before _site_base_url moves. Recorded in t/lint/202 beside the assertion so it is read by whoever changes it. Seven sabotages, seven refusals."
---

# What arrived

Delivery was proved on a live site. This is the message body as received:

    - Xi Software: manual notify test after SRV fix ->
      ${REQUEST_SCHEME}://${SERVER_NAME}/manager/plugins

The notification works. **The link in it is unusable** - not a wrong host and not
a stale path, but the raw template text of the config value.

# Three readers of one key, three behaviours

`Lazysite::Notify:288` builds the template variable as
`base => ( $conf->{base_url} // _site_url($docroot) )`, and `_site_url` is
`_conf_value( $docroot, 'site_url' )` - a private reader at `:538` that returns
the matched line verbatim.

```datatable
columns: Reader | Interpolates `${...}` | Notes
widths: 5.6cm | 3.0cm | X
text: 3
bold: 1
tone: medium
---
`lazysite-processor.pl` | **yes** | `%ENV_ALLOWLIST` of eight CGI variables, with `HTTP_HOST` deliberately excluded as request-supplied and untrusted
`tools/lazysite-users.pl::_site_base_url` | **yes, by hand** | Two of the eight plus a `$host_fallback`. Its comment states the problem exactly: *"site_url routinely holds `${REQUEST_SCHEME}://${SERVER_NAME}`, which only the CGI environment can expand."*
`lib/Lazysite/Notify.pm::_conf_value` | **no** | The raw line. Also returns `''` for an absent file and an absent key alike
```

`site_url` on this site - and on every site `install.pl` and `TestHelper` create
- is `${REQUEST_SCHEME}://${SERVER_NAME}`. So the fact that this value needs
expanding is **already known and already written down twice**, once as a
security-reviewed allowlist and once as a helper with a careful comment. The
notification path is the third reader and got neither.

**Confirmed in the tree.** `_conf_value` is seven lines, `or return ''`, one
regex, no substitution anywhere on the path between it and the rendered template.

## Not an artefact of running it from a terminal

The manual test ran outside CGI, where there is genuinely nothing to expand
against, so the output could be dismissed as a harness effect. It cannot:
nothing between `_conf_value` and the template performs any substitution under
CGI either. `form-handler.pl` runs with `SERVER_NAME` and `REQUEST_SCHEME` in
`%ENV` and produces the same string, because no code on that path looks at them.

**Grade: code reading, not measurement.** The reporter says so explicitly and
names the confirming test as not yet run. The live-submission check that would
close it is a row on the next test plan, not a blocker on the repair - the
absence of any interpolation code is not a thing a measurement would overturn.

# Ruled already: `base_url` is not the fix

`base_url` in `notify.conf` overrides all of this and was offered to the affected
site as a one-line workaround. The owner declined it:

> *"i dont want a static file to hold it - only one source of truth, holding this
> here will bite us later when url changes to something."*

So **this cannot be closed by documenting `base_url` better.** It is a second
place to write the site's own address, in a file nobody revisits, that goes stale
silently the day the site moves - the same failure mode as a hand-written keyword
standing in for a rule the engine could derive, which is [[SM930]] filed the same
day.

`site_url` is the single source of truth and already holds the right answer. The
defect is that one of its three readers does not resolve it. `base_url` stays as
the deliberate override for the case it was built for - a site whose
notifications must point somewhere other than itself.

# The fix

Give `Notify` the expansion the other two readers have, **by reusing the
processor's allowlist rather than copying it a third time**. That is the whole
point of the filing: the third hand-rolled copy is how this defect happened, and
a fourth would be the same mistake with a different symptom.

The case Notify actually has and the other two do not is **no request context at
all**: a cron-driven or CLI-driven notification has no `SERVER_NAME` to borrow.
`_site_base_url`'s `$host_fallback` argument is the right shape for that, and the
honest answer when there is no context and no fallback is a relative path rather
than a URL with an unexpanded variable in it.

Two smaller things in the same function while it is open:

- `_conf_value` collapses "no `lazysite.conf`" and "no `site_url` key" into `''` -
  the shape [[SM906]] and [[SM907]] addressed elsewhere, and [[SM917]] swept for
  in 0.15.1. It carries `# not a store - site config` on the open line, so lint
  121 passes it by design; the four-state question is about the key, not the file.
- `base_url` is documented in the header comment and nowhere a configuring
  operator would look.

# Answered 2026-09-30, and the answer is worse than the question

Both halves were established while building the fix, and together they are the
reason `_site_base_url` was **left alone** rather than consolidated.

**Is `_claim_url` reachable with a CGI environment? YES.** `cmd_account_approve`
calls it, `account-approve` is an `--api` action, and `users_tool_api` invokes the
tool with `open2`, which inherits `%ENV`. So a claim URL can be built inside a
request, with the request's variables present.

**But the variable to worry about is not `HTTP_HOST`.** The fallback chain reaches
`HTTP_HOST` only when `SERVER_NAME` is falsy, and under CGI Apache always sets
`SERVER_NAME` - so that branch is close to dead. What matters is what `SERVER_NAME`
*is*: **Apache's `UseCanonicalName` defaults to `Off`, under which `SERVER_NAME` is
taken from the Host header**, and none of the four shipped vhost examples
(`installers/apache/vhost*.conf.example`) sets it `On`.

So the processor's comment - *"HTTP_HOST is intentionally excluded - it is
request-supplied and untrusted. Use SERVER_NAME for host-based URL
construction"* - rests on a premise the engine's own vhosts do not establish. On a
default install, excluding one and permitting the other buys nothing.

**That is a ruling rather than a repair**, which is why nothing was changed: the
options are to ship `UseCanonicalName On` in the vhost templates (an operator-
visible change that lands on regeneration), to stop trusting `SERVER_NAME` in the
allowlist, or to accept it and say so where the comment currently claims safety.
Consolidating the three readers first would bake the unexamined assumption in
harder, so `_site_base_url` keeps its own copy until this is decided. The reasoning
is recorded in `t/lint/202` beside the assertion, so whoever changes the allowlist
reads it there rather than here.

# The original question, kept for the record

`_site_base_url` falls back
`$ENV{SERVER_NAME} || $ENV{HTTP_HOST} || $host_fallback`, and it builds
password-claim URLs. `lazysite-auth.pl` locates and runs `tools/lazysite-users.pl`
as a child process, so those URLs can be built with the CGI's environment
inherited - including `HTTP_HOST`, the variable the processor's allowlist excludes
by name and with a stated reason.

Whether that is reachable depends on Apache's `UseCanonicalName` and on whether
the forgot-password path is one of the two `_claim_url` callers. The reporter
established neither and neither have I, so this is a pointer rather than a
finding: **two readers of the same value disagree about whether `HTTP_HOST` is
trustworthy, and one of them emits URLs into email.** It wants reading before the
repair above consolidates the three readers, because consolidation will have to
pick one of the two answers.

# How it was found

Only by a message finally arriving. Four rounds of debugging established that
nothing was sent; the moment something was, the payload turned out to have been
wrong all along and invisibly so.

# Related

[[SM925]] (the three faults that stopped anything arriving at all), [[SM927]] (a
config-time test would have shown the operator this payload in the first minute),
[[SM928]] (the same message's missing content - these two should land together or
the added link arrives broken), [[SM906]], [[SM907]], [[SM915]] (the multiple-reader
family this belongs to), [[SM917]],
[[feedback_absence_is_a_finding]], [[feedback_a_boolean_has_four_states]].
