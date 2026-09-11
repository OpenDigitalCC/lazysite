---
title: "SM837: a remote page that cannot be fetched names its upstream to whoever asked"
subtitle: "Found while testing SM797, 2026-09-11: a .url page whose fetch fails, with no cached copy, renders 'Could not fetch remote content from <code>URL</code>' - to an anonymous visitor, unescaped, and as a 200"
brand: plain
standard-margins: true
status: candidate
---

# What happens

`lazysite-processor.pl`, the `.url` render path (line ~3417 at the time of
filing):

```perl
return render_template(
    { title => 'Content Unavailable' },
    qq(<div class="errorbox">\n<p>Could not fetch remote content from <code>$url</code>.</p>\n</div>\n)
);
```

when `fetch_url` returns undef and no stale cache exists. Reproduced on a minimal
site: `/upstream` for a `.url` pointing at an unreachable host renders the full
upstream address inside the page body.

# Three things, in order of weight

1. **The upstream address reaches an anonymous visitor.** A `.url` source can
   name an internal host, a private API, or a URL carrying a token or basic-auth
   credentials in it. The operator chose to publish the *content*, never the
   address - which is the same distinction SM797 rests on, where `.url.url`
   revealing an upstream was named as a disclosure. This is that disclosure on
   the plain URL, whenever the upstream is down.
2. **It is interpolated unescaped.** `$url` goes into HTML as-is. The `.url`
   file is authored by someone who can already write pages, so this is not an
   escalation today - but it is an unescaped sink, and the escape-at-the-sink
   rule SM786 applied to db values holds here for the same reason.
3. **It answers 200.** A page whose content could not be produced is not a
   success; caches, monitors and crawlers all read the status.

# The shape

The visitor is told the content is unavailable and nothing about where it comes
from; the address goes to the **log**, where an operator can reach it (with
[[SM835]]'s caveat about who can read the log). A 502 or 503 rather than 200.
Escape whatever does remain in the page.

# How it was found

While testing SM797: `/upstream.url.url` had to be compared with `/upstream`
to prove the doubled extension now renders the page rather than serving source.
Both responses contained the upstream - the collapse was working, and the plain
URL was the one disclosing it.

# Related

[[SM797]] (the doubled-extension disclosure this sits beside), [[SM786]]
(escape at the sink), [[SM835]] (the log has no remote reader).
