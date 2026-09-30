---
id: SM926
title: "SM926: every notification link is literal template text, because Notify is the third reader of `site_url`"
subtitle: "The first XMPP message to arrive on a live site carried the URL `${REQUEST_SCHEME}://${SERVER_NAME}/manager/plugins`. Three pieces of the engine read `site_url`: the processor interpolates it against a reviewed allowlist, a tool hand-rolls the same interpolation with a comment explaining why it must, and Lazysite::Notify has its own seven-line reader that returns the raw line. The RM has already ruled that `base_url` is not the fix."
brand: plain
standard-margins: true
status: candidate
raised: 2026-09-30
raised-by: site agent, from a live site (0.15.0), after the delivery path was proved end to end
area: notifications
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

# A question about the second reader, not a claim

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
