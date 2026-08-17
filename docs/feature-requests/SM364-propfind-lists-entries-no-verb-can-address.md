---
title: "SM364 - PROPFIND lists entries no verb can address"
subtitle: "A Depth 1 listing enumerates dot-prefixed entries. PROPFIND, GET and DELETE on those same entries all refuse. So a client can see them, cannot fetch them, and cannot remove them - and the refusal reports a different thing than what happened."
brand: plain
status: candidate
status-note: "FILED 2026-08-17 from the site agent's measurement on edge, unnumbered at the operator's instruction. NOT fixed in this release, deliberately: it is a change to a listing predicate on the WebDAV surface, and making one in a hurry against a fixture I could not stand up, hours before a cut, is worse than the exposure it closes. The exposure is small and the reporter says so first - access control on PROPFIND is working (/cgi-bin/ and lazysite/auth/ both 403), so this is limited to the NAMES of dot-prefixed siblings inside a collection the caller may already list, and they are engine-internal snapshot markers rather than content."
---

# What was measured

A Depth 1 `PROPFIND` on `/lazysite/layouts/lumen/themes/` enumerates
`.pristine-zz-own-theme` and three siblings. `PROPFIND`, `GET` and `DELETE`
addressed at those same entries all return 404.

The obvious explanation was tested first and ruled out: it is not a collection
needing a trailing slash, in either form.

The rule is dot-prefix, and it is enforced on write as well - `PUT
/zz-dot/.hidden-probe` is refused while `PUT /zz-dot/visible-probe` succeeds and
then lists and fetches normally. **So the policy is right.** The defect is that
the LISTING does not apply the policy the rest of the verbs do.

# The two halves, and the second is the useful one

## The listing does not filter

`do_propfind` enumerates a collection with

```perl
my @kids = sort grep { $_ ne '.' && $_ ne '..' } readdir $dh;
```

which skips exactly two names and nothing else. Every other verb goes through
the resolver and its refusal. Two surfaces answering one question differently -
the shape this register keeps recording.

The fix is to filter the listing with **the same predicate** the write path
already applies, rather than a second rule beside it that can drift. Allowing
`DELETE` instead would also be defensible; the two are not equivalent and it is a
decision rather than an implementation.

## The refusal reports something that did not happen

Same connection, seconds apart:

```datatable
columns: Request | Answer | What the client is told
widths: 6.2cm | 1.6cm | X
bold: 1
tone: medium
---
`PUT /cgi-bin/zz.pl` | 403 | Forbidden: this path is on the server blocklist (protected file type or location)
`PUT /zz-dot/.hidden-probe` | 404 | an HTML "Page Not Found" page
---
```

The first says what happened and why, and the project already writes refusals
that way. The second reports a **different thing** than what occurred - the entry
exists, the server had just listed it - and hands a WebDAV client an HTML error
page. A 403 in the existing style would have made this a one-line answer instead
of an investigation.

# What my own probing established, and what it did not

Worth recording because two of my three attempts refused for reasons that had
nothing to do with the question.

Established
: the engine's own refusals are `text/plain`, so the **HTML** error page the
  reporter received is the front end's, layered on top of ours. Anyone reading
  that transcript would reasonably have concluded lazysite emits it.

Not established
: what the engine does with a dot entry on an authenticated request. Three
  probes hit, in order, the `webdav_enabled` site gate, the plaintext-transport
  refusal, and then a 401 - each a 40x that looks like a finding and is not.
  Standing a full DAV auth fixture up is the first task of doing this properly.

# Where the residue is

The reporter cleared their test material from edge except these markers: they
refer to themes deleted long ago and no verb can remove them. Whatever is done
here should leave an operator able to clear them, which is an argument for the
`DELETE` half rather than only the listing half.

# Related

[[SM271]] (why the dot-prefix policy exists), the refusal-style precedent in the
blocklist message quoted above, and
`inbox/2026-08-17-propfind-lists-entries-no-verb-can-address.md`.
