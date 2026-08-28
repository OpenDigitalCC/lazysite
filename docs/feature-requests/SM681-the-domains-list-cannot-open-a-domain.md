---
title: "SM681: the domains list has no way to open the domain"
subtitle: "Release manager, 2026-08-28: 'on domains list, add icon to click to open the site in new tab'"
brand: plain
standard-margins: true
status: candidate
---

# The link exists, in the wrong place

`previewDomain` already sets one:

    document.getElementById('domain-preview-open').href = 'https://' + ... + '/';

with the comment that the in-session render shows the site now, pre-DNS, and the
LINK opens the real domain for once it is live. So the affordance was thought
about - it just lives inside the Preview overlay, which has to be opened first.

An operator looking at a list of domains wants to go to one. Making them open a
preview to find the link is two steps and a modal for something that is one
click.

# The trap in the obvious implementation

Do NOT use the row's `site_url`. That field can carry unexpanded variables -
`install.pl` writes `site_url: ${REQUEST_SCHEME}://<domain>` - because it is
resolved at render time by the processor, which has `REQUEST_SCHEME` and
`SERVER_NAME` in its environment. The manager does not, so putting `site_url`
straight into an `href` produces a link to a literal `${REQUEST_SCHEME}` on some
rows and a working link on others, depending on how the domain was created.

`previewDomain` already avoids this by building `https://<host>/` rather than
reading `site_url`, and the icon should do the same.

# The default row

`(default)` is not a host. Its row is the primary site, whose address is
whatever the manager itself is being served from - so the icon there should
point at `/` on the current origin, or not appear at all. Rendering
`https://(default)/` is the failure this note exists to prevent.

# Shape

A small external-link icon on each row, `target="_blank"` with
`rel="noopener"`, titled so the difference from Preview is legible: Preview
renders the site as the engine would serve it NOW, before DNS; this goes to the
live address and will fail until DNS points here. Both are useful and they
answer different questions.

# Related

SM238 / `domain_preview` (the in-session render this sits beside), SM436 (the
host and `site_url` disagreeing - the same field being unreliable as an
address), [[SM678]] / [[SM679]] / [[SM680]] (the current run of "the manager
does not surface what it already has").

# Not started
