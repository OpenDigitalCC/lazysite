---
id: SM928
title: "SM928: a submission notification names the form and withholds the submission"
subtitle: "The XMPP message for a new enquiry is `New form submission: enquiry` and a link to the plugins page. None of the submitted fields reach the notifier, so no site template can add them - the documented override exists and is powerless for the one thing an operator wants from it. Underneath is a newline strip that flattens every multi-line body on every endpoint, proved by running the same text through the strip and around it."
brand: plain
standard-margins: true
status: candidate
raised: 2026-09-30
raised-by: site agent, from the site owner's response to a working delivery (0.15.0)
area: notifications
status-note: "RULED 2026-09-30, NOT BUILT. The release manager ruled OPT-IN PER FORM: `notify: full` beside the existing `notify: on` and `notify: off`. A site that upgrades keeps the one-line notice and no enquiry text moves anywhere new until somebody asks for it; the site that requested full content sets the key. Two alternatives were declined - full-by-default-with-opt-out (every upgrading site starts broadcasting customer text into a room configured when the notice was one line long, with no re-consent), and defaulting by destination type (full to a direct JID, summary to a MUC), which is derivable from config but still needs the key as an override for a private one-member room, so it buys a rule nobody asked for. THE THREE DEFECTS BELOW ARE REPAIRS AND ARE NOT GATED ON THIS: the newline strip at Notify.pm:271 flattens multi-line bodies for every endpoint and template today, and item 4's wrong link is wrong regardless of how much content the notice carries. Build order: 1 (the strip) then 2 (pass the fields) then 3 (the multi-line default, behind `notify: full`) then 4. Lands with [[SM926]] or the added link arrives unexpanded."
---

# The ruling

**RULED 2026-09-30: opt-in per form.** `notify: full` beside the existing
`notify: on` and `notify: off`. The owner's site sets it and gets what they asked
for; every other site keeps the one-line notice until somebody chooses otherwise.

The argument that decided it is the one this filing raised rather than the one the
owner asked about: nobody re-consents to a behaviour change they did not read
about, and a room configured when the notice was one line long is not consent to
customer-written content appearing in it. The choice has to be made by a person
who can see the room.

**Declined: default by destination type** - full content to a direct JID, summary
to a MUC, on the grounds that the engine already knows which is which. It is a
real distinction and it still needs `notify: full` as an override for the site
whose MUC has one member, so it adds a rule to be learnt without removing the key
that rule was meant to replace.

**Declined: full by default with an opt-out** - simplest to build and the only
option that changes what an existing site emits without being asked.

**The three defects below are not gated on this ruling.** The newline strip at
`:271` flattens multi-line bodies for every endpoint and every template today, on
sites that never touch `notify:` at all, and item 4's link is wrong whatever the
notice contains. Only item 3 - the multi-line default body - sits behind the new
key.

# What was asked for, having received one

Delivery was proved end to end on a live site. The owner's response on seeing the
result:

> *"note that I only had notification, not the full message. test again with the
> form and full message, sender etc formatted to read well in the client, ie
> newlines between items"*

A ping that says only *that* an enquiry exists still requires opening the manager
to learn anything. The owner's stated reason for preferring XMPP over email is
that the notices are disposable - which only pays off if the notice carries the
thing being notified.

# Why a site template cannot fix this

`plugins/form-handler.pl:646` passes the form's **name** and nothing else:

```perl
Lazysite::Notify::notify( $DOCROOT, {
        type    => 'submission',
        message => "New form submission: $f",
        target  => $f,
        url     => '/manager/plugins',
} );
```

and `Lazysite::Notify:281` builds a **fixed** variable set for every type -
`message`, `type`, `target`, `url`, `to`, `site`, `base`. `%TYPES` declares no
additional variables for `submission`.

So the documented override at `lazysite/notify-templates/submission.xmpp.tt` can
restyle seven values that do not include a single submitted field. The extension
point is real, reached, and cannot express the request. **The data never crosses
the call.**

# Four defects, and the third is the one that was asked about

```datatable
columns: # | Defect | Fix
widths: 0.8cm | 6.4cm | X
text: 2*3
bold: 2
tone: medium
---
1 | `Notify.pm:271` strips every newline from the message before any template or endpoint sees it: `$rec{message} =~ s/[\r\n]+/ /g` | build `%vars` from `$n->{message}`, not from the stripped record copy
2 | No field data is passed, so no template can render it | pass the submitted fields into `notify()`
3 | The `xmpp` template is one line, by an assumption stated in its own comment - *"a chat client shows one line"* | a multi-line default, once 1 makes it possible
4 | `url => '/manager/plugins'` sends the operator to the plugins page, not to the submission | the Submissions view for that form
```

Defect 3 is what the owner asked for and the other three are in its way.

# The newline strip, which is the root of it

```perl
my %rec = ( ts => time(), type => $type, message => $n->{message}, ... );
$rec{message} =~ s/[\r\n]+/ /g;                  # :271, no comment on it
...
my %vars = ( message => $rec{message}, ... );    # :282, the stripped copy
```

Confirmed in the tree at both lines. The statement carries no comment and sits
immediately before the `notices.jsonl` append, so its evident purpose is to keep
the store one record per line. **`JSON::PP::encode_json` already escapes newlines
as `\n` inside the JSON string**, so a newline could never have broken the JSONL
format. The strip is unnecessary for the only thing it looks like it is for, and
because `%vars` is then built from the stripped copy rather than from
`$n->{message}`, it silently flattens multi-line bodies for **every endpoint and
every template** - XMPP and email alike.

A site that writes a careful multi-line `submission.xmpp.tt` today gets its
newlines back, because the template's own literal newlines survive; only the
interpolated `[% message %]` is flattened. That is the worst version: it works
until the content matters.

**Grade: measured, with a discriminating test.** The reporter first claimed the
proposed body had been verified over the live transport, then corrected it - the
message had arrived as a single line, which is how defect 1 was found. The
confirming run handed the same body straight to `_xmpp_send`, bypassing `:271`
and nothing else: *"newlines came through, reads well."* Same transport, same
client, same room, same text, one path through the strip and one around it. That
makes `:271` the cause rather than a candidate, and the self-correction is why
this is filed as measured at all.

# Details worth settling rather than discovering later

- **Labels or field names.** The form definition holds `Your name *` and
  `What do you need it to do? *`; the handler has `name` and `message`. Labels
  read far better and the handler would need the form definition to get them.
  Strip the trailing ` *`.
- **Skip the internals** - `_form`, `_page`, `_ts`, `_tk`, `_hp` - and skip empty
  optional fields rather than emitting `Telephone:` with nothing after it.
- **Cap the length.** A textarea can hold a great deal and a chat room is a poor
  place to discover that. Truncate with a marker and let the link carry the rest.
- **A file upload is a filename, not a file.** Say the name, not the bytes.
- **Do not pad labels into columns.** Most clients set chat text proportionally,
  so padded alignment arrives ragged and worse than none.

The formatting belongs in a template, not in the caller. That is precisely why the
fields have to reach the notifier as values.

# The one thing that should not be decided by default

This change puts **customer-submitted content into a chat room**. A MUC has other
members and it has history, and on the site this came from the room is shared with
a team.

That is the owner's call for their own site. But if full content becomes the
default, **every site that upgrades starts broadcasting enquiry text to whatever
room it was configured with**, on the strength of a setting made when the notice
was one line long. Nobody re-consents to a behaviour change they did not read
about.

Opt-in per form, beside the existing `notify: off`, keeps both available and makes
the choice deliberate: `notify: full` against `notify: on`. The owner has asked
for full content on their site and should get it; the argument is only about which
way round the default sits for everybody else.

**This wants a ruling before anything is built**, and it is the only item in the
2026-09-30 batch that does. The three defects above are repairs; the default is a
decision about other people's data.

# Related

[[SM231]] (per-form emission control, the neighbouring key), SM136 (the notify
path, shipped 0.6.3 - in BACKLOG.md, not a filing), [[SM926]] (the `base` variable this message's link is built from - these
two should land together or the added link arrives broken), [[SM927]] (a test
button would have shown this body before the owner had to ask),
[[feedback_no_explanatory_notes_on_screens]].
