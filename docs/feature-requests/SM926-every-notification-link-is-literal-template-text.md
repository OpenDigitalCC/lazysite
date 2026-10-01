---
id: SM926
title: "SM926: every notification link is literal template text, because Notify is the third reader of `site_url`"
subtitle: "The first XMPP message to arrive on a live site carried the URL `${REQUEST_SCHEME}://${SERVER_NAME}/manager/plugins`. Three pieces of the engine read `site_url`: the processor interpolates it against a reviewed allowlist, a tool hand-rolls the same interpolation with a comment explaining why it must, and Lazysite::Notify has its own seven-line reader that returns the raw line. The RM has already ruled that `base_url` is not the fix."
brand: plain
standard-margins: true
status: shipped
raised: 2026-09-30
raised-by: site agent, from a live site (0.15.0), after the delivery path was proved end to end
area: notifications
status-note: "PARTIAL - the defect is FIXED (924c520b); the consolidation of the THIRD reader is deliberately not done. SHIPPED: the allowlist moves to Lazysite::Util, Notify interpolates through it, and t/lint/202 pins the processor's own copy identical variable-for-variable (the render path is module-free per ADR 0001, so it keeps a copy - the arrangement lint 198 makes for _cannot_read). A case neither other reader has: NO REQUEST CONTEXT AT ALL - a cron- or CLI-driven notice has no SERVER_NAME, interpolation would correctly yield `://`, and emitting that is worse than emitting nothing because it looks like a link; so an incomplete expansion yields EMPTY and the template's `[% base %]/path` degrades to an absolute path. Also fixed: _conf_value no longer collapses an absent lazysite.conf and one that will not open into ''. THIS FILING'S OWN OPEN QUESTION WAS ADVANCED AND IS WORSE THAN IT SUPPOSED. Half settled: _claim_url IS reachable from a CGI-invoked `--api` action (account-approve; users_tool_api uses open2 and inherits %ENV), so a claim URL can be built with CGI env present. The other half: the processor's comment excludes HTTP_HOST as 'request-supplied and untrusted' and directs callers to SERVER_NAME - but Apache's UseCanonicalName defaults to OFF, under which SERVER_NAME is TAKEN FROM THE HOST HEADER, and none of the four shipped vhost examples (installers/apache/vhost*.conf.example) sets it On. So on a default install the exclusion buys nothing, and consolidating the third reader would bake that assumption in harder. RULED 2026-10-01: THE PRESENTED HOST IS THE HOST. Not a trust level but a division of responsibility - the engine uses the hostname it was given, restricting what may be presented is the front end's job, and a site that wants it fixed pins it. CONSEQUENCES: (a) ONE definition of the request host - interpolation must use the same host _request_host() already routes alias config on, which also makes the answer independent of UseCanonicalName instead of quietly conditional on a vhost setting none of the four shipped examples sets; (b) the PIN ALREADY EXISTS and needs no key - a literal site_url is untouched by interpolation, which t/unit/lib/58 already asserts; what does not exist is pinning the HOST while leaving the scheme dynamic, a smaller question not assumed here; (c) UseCanonicalName On is NOT shipped - it was the only option that would have made the old comment true and is the wrong direction, because it would fix SERVER_NAME to the primary ServerName and an alias host not overriding site_url would put the PRIMARY host in its own links, breaking the multi-host and language-set sites the alias mechanism exists for; (d) SM110's whitelist is unchanged - a security-relevant key still may not vary per host. The comment that treated SERVER_NAME-vs-HTTP_HOST as a boundary the engine maintains is wrong in its reasoning as well as its facts, and _request_host() reading HTTP_HOST to pick an alias host has said so on the main render path all along. Recorded in t/lint/202 beside the assertion so it is read by whoever changes it; seven sabotages, seven refusals on the defect fix. CONSEQUENCE (a) BUILT 2026-10-01 (a43cab2d): both copies resolve SERVER_NAME through the request host; env_interpolation_complete moved to the SAME resolver, which this change would otherwise have broken - with a Host header and no SERVER_NAME it would have called the expansion unresolvable and emitted a relative path where the absolute one was available; validation stays because the value reaches the per-host cache's FILENAMES, and t/unit/lib/60 drives five malformed hosts including a traversal through it; t/lint/203 pins the two copies equivalent BODY FOR BODY, not merely clause by clause. NO NEW CONFIG KEY - the pin already existed as a literal site_url, which t/unit/lib/58 asserted before the ruling was taken. STILL NOT CONSOLIDATED: tools/lazysite-users.pl::_site_base_url keeps its own hand-rolled copy; it is now unblocked, because the contested premise is settled, but it is not in this change. Eight sabotages, eight refusals on the one-definition change."
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

# RULED 2026-10-01: the presented host is the host

The three options I put up were all framed as "which host variable do we trust",
and the release manager rejected the framing rather than picking one. In their
words:

> *"What I want is that the hostname provided to Lazysite is the one that is used
> which then prevents any pre-configuration. Subdomains require a matching name,
> but anything presented will run. Therefore its up to the user to have a proxy or
> webserver to ensure that it behaves as desired. It may be useful to have a site
> config feature that allows the servername to be set, based on what is dynamic, so
> that it can be pinned if user reqiests it, and that may be useful in some
> situations, but default is that it is variable. then for the forms etc that rely
> on the variable, it is populated with whatever was used at the request, unless it
> is pinned."*

So the position is not a trust level, it is a **division of responsibility**. The
engine uses the host it was given; restricting what may be presented is the front
end's job, not the engine's. A site that wants the host fixed pins it; the default
is that it varies with the request.

That makes the processor's comment wrong in its reasoning as well as its facts. It
treats the choice between `SERVER_NAME` and `HTTP_HOST` as a security boundary the
engine maintains. The engine does not maintain one there - and `_request_host()`,
which reads `HTTP_HOST` and decides which alias host's config a request gets, has
said so on the main render path all along. SM110's comment already states the real
rule: the Host header may select **presentation-only** keys, and the safety is in
limiting *what* it may select. `site_url` is presentation.

## What follows, and what does not

**ONE definition of "the host this request is for".** Today there are two -
`_request_host()` for alias selection, and whatever `SERVER_NAME` happens to hold
for interpolation - and they can disagree depending on `UseCanonicalName`, a vhost
setting none of the four shipped examples sets. Under the ruling they must be the
same thing, which also makes the answer independent of that setting instead of
quietly conditional on it.

**THE PIN ALREADY EXISTS and does not need building.** A literal `site_url` -
`site_url: https://example.com` - is pinned, today, with no new key: interpolation
leaves a value with no `${...}` in it untouched, which
`t/unit/lib/58`'s "a literal site_url still works without any CGI environment"
subtest already asserts. The templated form
`${REQUEST_SCHEME}://${SERVER_NAME}` is the variable default the ruling describes.
What does NOT exist is pinning the HOST while leaving the scheme dynamic; whether
that case is worth a key of its own is a smaller question than the ruling and is
not assumed here.

**`UseCanonicalName On` is not shipped.** It was the only option that would have
made the old comment true, and it is the wrong direction under this ruling: it
would fix `SERVER_NAME` to the primary `ServerName`, so an alias host that does not
override `site_url` would put the PRIMARY host into its own links, sitemap and
notices - breaking exactly the multi-host and language-set sites the alias
mechanism exists for.

**What is unchanged:** SM110's whitelist. A security-relevant key still may not vary
per host. The ruling widens nothing there - it says only that the host itself is
taken as presented, which the alias path already did.

# The question as it was put, kept for the record

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
