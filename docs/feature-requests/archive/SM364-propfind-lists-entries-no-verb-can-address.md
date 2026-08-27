---
title: "SM364 - PROPFIND lists entries no verb can address"
subtitle: "A Depth 1 listing enumerates dot-prefixed entries. PROPFIND, GET and DELETE on those same entries all refuse. So a client can see them, cannot fetch them, and cannot remove them - and the refusal reports a different thing than what happened."
brand: plain
status: superseded
status-note: "REPRODUCED AND DISPROVED 2026-08-18, at the fourth attempt. The state the report describes was finally reached - and in it, the dot-prefixed entry is LISTED, READ (200) and DELETED (204). The engine has no dot-prefix policy in this subtree, its verbs allow the entry, and the listing agrees with them. So there is no engine defect of the shape filed, and the obvious fix - filter dot entries from the listing - would have HIDDEN something fully addressable. WHAT REACHES THE STATE, and why three attempts missed it: HTTPS=on, or the transport gate refuses everything with 'HTTPS required'; and manage_themes + manage_layouts, or authorise_layout refuses the whole subtree before any path logic runs. Neither is exotic and both are invisible behind a 403, which is exactly how three fixtures in a row measured something other than what they meant to. WHAT THE REPORTER ACTUALLY SAW is therefore a FRONT END refusing dot-prefixed paths while the engine's PROPFIND - which runs through the CGI - lists them. That is consistent with everything else measured on that instance: the 404 body was already established as their front end's own error page, not ours, and the shipped Apache template denies only .brief. So this is two systems disagreeing, with the engine on the correct side, and it is SM286's territory inverted - a front end making a decision the engine did not ask for. THE RESIDUE IS REMOVABLE at the engine; if it is not removable through their front end, that is where to look. Superseded rather than shipped: nothing in the engine changed, and t/integration/58 now pins the state and the behaviour so the one-line 'fix' cannot be added later without deleting a subtest that says why it would be wrong. FILED 2026-08-17 from the site agent's measurement on edge, unnumbered at the operator's instruction. NOT fixed in this release, deliberately: it is a change to a listing predicate on the WebDAV surface, and making one in a hurry against a fixture I could not stand up, hours before a cut, is worse than the exposure it closes. The exposure is small and the reporter says so first - access control on PROPFIND is working (/cgi-bin/ and lazysite/auth/ both 403), so this is limited to the NAMES of dot-prefixed siblings inside a collection the caller may already list, and they are engine-internal snapshot markers rather than content."
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

**Confirmed from outside afterwards**, which pins it harder than the inside
check needed to:

```datatable
columns: Response | Bytes | Title | Generator tag
widths: 5.4cm | 2cm | X | 3.2cm
bold: 1
tone: medium
---
the DAV 404 | 2,898 | "Page Not Found" | absent
the site's own 404 | 3,126 | "Page not found - EDGE" | present
---
```

Two different documents, and the one a WebDAV client receives carries no
lazysite branding at all. So **no engine change will stop that page appearing** -
the remedy is split across two systems, and only the status code is ours to fix.

That the status code IS ours is what survives, and 404 is still the wrong one:
the entry exists and the server had just listed it.

## The trap, recorded because this filing is about it

Both of us accepted a status code at face value while investigating a status code
that reports something other than what happened. The reporter read "I received
HTML" as "the engine sent HTML"; I read three unrelated 40x refusals as answers
to the question I was asking. Neither is careless - it is the specific failure
this defect is made of, met while looking straight at it.

# Measured 2026-08-18, and it moves the fix

I built a fixture to write the listing filter against, and it disproved the
premise I was about to build on.

**A dot-prefixed file under `/content/` is freely readable over WebDAV.** A
`GET` on `/content/zz-dot/.pristine-marker` returns 200. So there is no general
dot-prefix rule: the refusals the reporter measured are specific to the
`lazysite/layouts/` subtree, where `authorise_layout` applies its own rules and a
dot-prefixed name parses as a theme name.

That changes the fix and rules one out:

filtering dot-prefixed entries from every listing
: **wrong.** It would hide files a caller CAN address, which is the same defect
  pointing the other way - a listing that omits what a verb will serve.

filtering the listing by the authorisation the VERBS apply
: right, and it is what the reporter proposed - the same predicate rather than a
  second rule beside it. It means asking `authorise()` per child rather than
  matching a pattern, so wherever a verb refuses, the listing is quiet, and
  wherever a verb serves, the listing says so.

Still not built, and now for a better reason than "not before a cut": the
meaningful fixture is in the layouts subtree, not the content tree, and two
premises have now failed under me in this area - the reporter's HTML 404 turned
out to be their front end, and the dot rule turns out to be local to one subtree.
A third guess is not what this needs.

# Confirmed from outside, by the cleanest possible discriminator

The site agent tested the front-end hypothesis and it holds:

```datatable
columns: Surface | Call | Result
widths: 2.6cm | X | 3.4cm
bold: 1
tone: medium
---
WebDAV | `DELETE /lazysite/.../.pristine-zz-own-theme` | **404**
MCP | `delete_file {"path": ".../.pristine-zz-own-theme"}` | **ok, file gone**
---
```

Same engine, same path, same credentials, opposite outcome. The only difference
is that the MCP path travels **in a JSON body** to `/cgi-bin/lazysite-mcp.pl`,
so the dot never appears in the request URI and a front-end
`location ~ /\.` deny has nothing to match.

All four markers that were the reporter's are now cleared through MCP.

## And the general fact that falls out of it

**A front-end path rule does not reach the MCP channel**, because MCP paths are
not in the URI. That is not a hole - [[SM286]] is precisely the argument that
the engine must enforce its own access rules and not rely on the front end, and
it does: MCP applies the same ACLs, capabilities and blocklist the other
surfaces apply.

But it means an operator who believes a path-based deny in their proxy is
protecting something is mistaken about the shape of that protection. It
protects the URI-bearing surfaces and nothing else. Worth stating once, because
the reasoning "I denied it in nginx, therefore it is denied" is exactly the
reasoning this repository has spent three releases dismantling in the other
direction.

# What would settle it

A fixture that stages `lazysite/layouts/<layout>/themes/` with a `.pristine-*`
marker, established first to refuse `GET` and `DELETE`, and only then used to
assert that the listing agrees. Establishing the refusal FIRST is the part I
skipped, and it is why this filing has been rewritten twice.

# Where the residue is

The reporter cleared their test material from edge except these markers: they
refer to themes deleted long ago and no verb can remove them. Whatever is done
here should leave an operator able to clear them, which is an argument for the
`DELETE` half rather than only the listing half.

# Related

[[SM271]] (why the dot-prefix policy exists), the refusal-style precedent in the
blocklist message quoted above, and
`inbox/2026-08-17-propfind-lists-entries-no-verb-can-address.md`.
