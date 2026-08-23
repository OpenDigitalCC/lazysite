---
title: "SM442: regenerate reports what it considered, not what it cleared - and sitemap.xml cannot be written over WebDAV"
subtitle: "cleared_roots is built from the root list rather than from the unlinks, so four files and none look identical. Separately, a PUT of sitemap.xml into a content root returns 201 and the file never exists - which makes SM433's shadow warning unreachable for the one registry it was written about."
brand: plain
standard-margins: true
status: shipped
status-note: "PARTIALLY SHIPPED (PENDING): the REPORTING half only. cleared_files and cleared_count now come from the actual unlinks, and MCP routes through the shared action so it gains shadowed_by_files too - it had never had it. THE MECHANISM HALVES MOVED TO SM483 rather than left hanging here: the frozen dhcf registry, the empty-from-birth xisl registry, and sitemap.xml being accepted-and-discarded over WebDAV are all still unexplained, and they are a different subject from this filing's fix. This one made regenerate say what it cleared; those three are field conditions nobody has reproduced, so carrying them as an open note on a shipped fix meant a filing that could never be closed and a gap nobody owned. What this change buys is that the next occurrence is diagnosable from the first response instead of from ninety minutes of probing. ORIGINAL FILING FOLLOWS. FILED 2026-08-20 from the field, and the two halves have very different evidence standards - stated up front because one is confirmed and one is not. CONFIRMED, CHEAP, AND WORTH FIXING ON ITS OWN: action_regenerate_registries builds cleared_roots from _registry_roots() and NOT from what _invalidate_registries actually unlinked, so the response is identical whether four files were removed or none existed. 'I regenerated and nothing changed' is precisely the report SM433 was written to explain, and the field has now produced it again against a call that may have done nothing. _invalidate_registries already returns @shadowed; returning what it unlinked too is a few lines and makes the answer honest. NOT CONFIRMED AS THE CAUSE, THOUGH THE DIVERGENCE IS REAL: the reporter's code-level explanation is that the processor takes its cache base from $ENV{LAZYSITE_CACHE_DIR} || \"$LAZYSITE_DIR/cache\" while _invalidate_registries hardcodes _lz().\"/cache/registries\" with no env override. That divergence EXISTS - I read both - and should be closed. But LAZYSITE_CACHE_DIR is documented as the dev server's --auto-index relocation and is unset in production and tests, where both sides resolve to the same directory. So it is a latent defect waiting for any install that sets the variable, and on an ordinary host it does not explain the symptom. The reporter flagged it as unconfirmed themselves, being unable to read that host's environment. A MUCH SIMPLER EXPLANATION IS ALREADY IN EVIDENCE, and it is the confound that has caught this thread twice: registries are served public, max-age=14400, and $REGISTRY_TTL is 14400 - the same four hours. Earlier the same day, on the same host, /sitemap.xml served stale while /sitemap.xml?cb=1 returned the correct content from origin. If 'the artefact does not change' was measured on the PLAIN URL then generation and clearing may both be working and the reading is an HTTP cache hit. That question - was it busted? - should be answered before anyone opens the invalidation code. SECOND FINDING, MECHANISM NOT FOUND: a PUT of sitemap.xml into a content root returns 201 and the file never appears - not over GET, not in PROPFIND, still absent after 60s (so not SM438's visibility window). Same directory, same bytes, same session: probe-sitemap-test.xml and llms.txt both 201 then 200. So it is neither the extension nor a general 'registry names are protected' rule; sitemap.xml alone is accepted and discarded. I RULED OUT what I could read: lazysite-dav.pl contains no reference to sitemap at all, so there is no special case in the DAV layer, and _invalidate_registries explicitly no longer deletes content-root copies (SM293 made that path supported operator content, and it now REPORTS a shadowing file rather than removing it). I could not find the mechanism and am not guessing at one. THE CONSEQUENCE STANDS REGARDLESS, and it lands on my own SM433 change: if sitemap.xml cannot be made to exist at a content root over WebDAV, then shadowed_by_files can never fire for sitemap.xml through that route - the warning is only reachable for a file placed by other means, and sitemap.xml is the registry it was written about. DISCLOSURE FROM THE REPORTER, recorded because they volunteered it: while establishing the asymmetry they briefly wrote test content to that site's llms.txt, shadowing the real one for about a minute; removed and verified. It is the only probe today that degraded a live site."
---

# Confirmed: the report cannot distinguish success from nothing

```perl
my @roots    = _registry_roots();
my @shadowed = _invalidate_registries();
my @rel      = map { ... } @roots;
return { ok => 1, cleared_roots => \@rel, ... };
```

`cleared_roots` is the list of roots CONSIDERED. Nothing in the response comes
from the unlinks.

::: widebox
So a call that removed four files and a call that found nothing to remove
return the same thing. "I regenerated and nothing changed" is the exact report
SM433 exists to explain, and the response is built so that it cannot help.
:::

`_invalidate_registries` already returns `@shadowed`; returning what it
unlinked as well is a few lines, and makes `regenerate-registries` answerable.

# Real divergence, probably not this symptom

The processor:

```perl
my $CACHE_BASE = $ENV{LAZYSITE_CACHE_DIR} || "$LAZYSITE_DIR/cache";
```

`_invalidate_registries`:

```perl
my $cache = _lz() . "/cache/registries";
```

The invalidator cannot follow the override. That should be closed on its own
account - but `LAZYSITE_CACHE_DIR` is the dev server's `--auto-index`
relocation and is unset in production and tests, where both resolve to the same
directory. **Latent, not the explanation** on an ordinary host.

# The explanation already in evidence

Registries serve `public, max-age=14400`, and `$REGISTRY_TTL` is `14400` - the
same four hours. Earlier the same day, same host: `/sitemap.xml` stale,
`/sitemap.xml?cb=1` correct from origin.

**One question settles the whole first half: was "the artefact does not change"
measured on the plain URL?** If so, generation and clearing may both be working
and the reading is a cache hit. Worth answering before anyone opens the
invalidation code - this thread has now been confounded by an unbusted URL
twice.

# Second finding: sitemap.xml is accepted and discarded

```datatable
columns: PUT into the same content root | Result
widths: 7cm | X
bold: 1
tone: medium
---
`sitemap.xml` | **201, then 404, never in PROPFIND, still absent at +60s**
`probe-sitemap-test.xml` | 201, then 200
`llms.txt` | 201, then 200
```

Not the extension, and not a blanket rule about registry names - `llms.txt` is
a registry name and writes fine.

**Ruled out by reading:** `lazysite-dav.pl` contains no reference to `sitemap`,
so there is no special case in the DAV layer; and `_invalidate_registries` no
longer deletes content-root copies at all - SM293 made that a supported
location for operator content, and it now reports a shadowing file rather than
removing it.

**Mechanism not found.** No guess offered.

# What it costs SM433

If `sitemap.xml` cannot be made to exist at a content root over WebDAV, then
SM433's `shadowed_by_files` can never fire for `sitemap.xml` by that route. The
warning remains reachable only for a file placed by other means - and
`sitemap.xml` is the registry the warning was written about.

That is worth knowing about a change that shipped this week, and it does not
depend on the mechanism being understood.

# A listing that is not a list of files

`/sitemap.xml` and `/llms.txt` appear in a PROPFIND of the docroot while a DAV
`GET` of `/sitemap.xml` returns 404. Those entries are GENERATED registries,
not files. A PROPFIND listing is therefore a misleading guide to what exists on
disk, and the reporter drew a wrong conclusion from one earlier the same day.
Worth a line in the WebDAV documentation whatever happens to the rest of this.

# The cache hypothesis is RULED OUT

I proposed that the first half was an unbusted-URL artefact. It was not, and
the check was done against the reporter's own commands rather than from memory.

Every fetch in that thread carried a distinct, previously unused key -
`?rebuild=1`, `?cb=after2`, `?cb=fresh1`, `?t=1`, `?v=static`, `?final=1`,
`?v=late` - six or seven separate keys across roughly ninety minutes, each a
fresh origin fetch on a path already proven to reach origin when busted. A
further run at 17:23Z with `?k=answer1` returned 21 locs including `/blog/` and
both posts.

::: widebox
The plain URL now returns 21 as well, so the two AGREE - the divergence that
started this thread is absent. What remains is not a caching artefact: the
artefact itself is stale, and clearing does not change it.
:::

So the first half stands on its own evidence, and my simpler explanation was
wrong. Recorded here rather than quietly dropped, because it was used to argue
against opening the invalidation code.

# It generated once, then froze

The narrowing the reporter added is the most useful fact in the filing: the
artefact's content corresponds to a build made AFTER the site's content moved
into `sites/dhcf` and BEFORE the blog was deleted.

So this is not "never generated". It generated at least once during the
session, and then stopped responding to clears.

# The discriminator, and it is already built

`action_regenerate_registries` returns `shadowed_by_files` when a file sits at
the pre-SM293 in-docroot location - and SM433 made that path deliberately
NON-deleting, reporting the shadowing file rather than removing it.

A file at `sites/dhcf/sitemap.xml` would therefore produce exactly this
behaviour: served in preference to the generated registry, never cleared by
`regenerate-registries` because clearing it is deliberately not done, and
unaffected by `$REGISTRY_TTL`, which governs regeneration of the cache copy and
not a file shadowing it. Generated once, then frozen.

**Next step, no shell required: capture the FULL JSON from
`regenerate-registries` and look for `shadowed_by_files`.**

```datatable
columns: If the response | Then
widths: 7cm | X
bold: 1
tone: medium
---
names a sitemap path | the mechanism is SM433's deliberate non-deletion; the remedy is removing that file, and the lesson is that the warning was present and unread
omits it | something else holds the artefact, and this filing stays open
```

One caveat against the tidy version: the reporter's `sitemap.xml` PUT returned
**201**, and `do_put` returns 201 only when the target did NOT exist at the
resolved path. That argues against a leftover file at that exact path, or means
the resolved path differs from where the engine wrote. It is a reason to run
the check rather than to assume the answer.

# A falsifiable prediction on the TTL

The last build was around 16:45-17:00Z, so a four-hour TTL should expire about
20:45-21:00Z. If the artefact is still stale after that, TTL expiry is not
rescuing it either, and it is **pinned rather than merely uncleared** - which
would rule out every "it will refresh eventually" reading.

The reporter is not watching for it. Worth someone doing.

# The shadowing story is ruled out too - by evidence already captured

`shadowed_by_files` is **ABSENT** from the response, taken at the point the
artefact was demonstrably stale:

```json
{"cleared_roots": ["/", "/sites/xisl", "/sites/sjm", "/sites/dhcf",
                   "/sites/jpm-stock", "/sites/learning", "/sites/mg"],
 "note": "The registries are cleared and rebuild on the next request...",
 "ok": true}
```

Captured a second time immediately after deliberately PUTting a static
`sitemap.xml` to `sites/dhcf/`, printing the key specifically: still absent -
consistent with that PUT being discarded, since the file the warning looks for
never came into existence.

The 201 caveat was the right instinct. There is no leftover file, and the
mechanism stays open.

::: widebox
**The two findings interlock more tightly than either was first put.** SM433's
warning fires on a file at that path; the DAV layer will not let a file exist at
that path; so on a content-root site the warning is unreachable by the route an
operator would use, AND the condition it warns about cannot be created in order
to test it.
:::

# A candidate that fits every observation: the early return

`_invalidate_registries` begins:

```perl
my $rdir = _lz() . "/templates/registries";
return () unless -d $rdir;
```

If that directory is not present under the manager's `_lz()`, the function
returns immediately having unlinked nothing and having run no shadow check -
and the caller still reports all seven `cleared_roots` and omits
`shadowed_by_files`, because both of those are true of a no-op.

That accounts for every measurement in this filing at once: clears that report
success, an artefact that never changes, no shadow warning, and a registry that
generated once (by the processor, on its own path) and then froze.

**Not established.** Two checks settle it, both needing filesystem access:

```datatable
columns: Check | Meaning
widths: 7cm | X
bold: 1
tone: medium
---
`<docroot>/lazysite/templates/registries/*.tt` exists? | absent = the early return fires and the clear is a no-op
`<docroot>/lazysite/cache/registries/` subdirectory names | expect `sites_dhcf`; anything else means the KEY differs between processes
```

The key derivation itself is byte-identical on both sides - I compared
`_registry_cache_path` in the processor with `_invalidate_registries`, and the
strip, the substitution and the `_root` default all match. What can still
differ is `$DOCROOT` itself between the manager process and the processor
process (symlinked versus resolved path, or a trailing slash), which would
leave the strip un-applied and produce a different key. The second check above
shows that directly.

# Why the confirmed half would have found this

Had `regenerate-registries` reported what it UNLINKED rather than which roots it
considered, an early return would have shown as zero files cleared against seven
roots - visible in the first response, without ninety minutes of probing.

That is the argument for fixing the reporting even if the underlying mechanism
turns out to be something else entirely: the report is what turned a diagnosable
condition into an afternoon.

# A second, cleaner reproduction: never rebuilt, rather than stale

A newly created site on the same instance generates `sitemap.xml` and
`llms.txt` **empty** - header, no entries - while 21 of its pages carry
`register: sitemap.xml`. `regenerate-registries` reports success and changes
nothing, cache-busted.

The registry was first built when the content root was EMPTY, and has never
contained anything since the content arrived.

::: widebox
So "stale" is the wrong word for this filing, and the first case should be
re-read in its light. The artefact is not holding an OLD build. **It is not
rebuilding at all** - the first build is the only build, and whatever the first
request happened to see is what the site serves indefinitely.
:::

# Where generation is gated

`update_registries` runs per REQUEST and takes its content root from the
resolved site vars:

```perl
my %sv = resolve_site_vars();
my $root = $DOCROOT; my $has_root = 0;
if ( defined $sv{content_root} && length $sv{content_root} ) {
    my $c = confine_content_root( $DOCROOT, $sv{content_root} );
    if ( defined $c ) { $root = $c; $has_root = 1; }
}
return if $sv{alias_host} && !$has_root;
```

Two things follow, both worth checking against the failing site:

- `$sv{content_root}` comes from the ALIAS OVERLAY, which applies only when the
  request's Host matched a declared alias host. A host that does not match
  generates nothing for that domain - the SM436 family again.
- An alias host whose content root fails to confine returns early and generates
  nothing at all, silently.

Neither is established as the cause here. They are the two places where "no
registry was generated for this domain" is a normal, unreported outcome, and
they are cheap to distinguish: request a PAGE under the failing host and see
whether the registry changes.

# What the two cases share

An empty-at-birth registry and a frozen-at-one-build registry are the same
symptom if nothing ever removes the cached output: the first request writes it,
and no later event replaces it. That points back at the early-return candidate
above rather than away from it - `_invalidate_registries` returning without
unlinking would leave every first build permanent.

The check is unchanged and still needs a shell:
`<docroot>/lazysite/templates/registries/*.tt`, and the subdirectory names under
`<docroot>/lazysite/cache/registries/`.

# The `has_root` early return is RULED OUT for the failing host

The reporter offered "the xisl site has had plenty of page requests and its
registry is still empty" as weak evidence, because they had not watched before
and after. One fetch makes it decisive, and the marker is the overlay's own
output:

```datatable
columns: Probe | Result
widths: 7cm | X
bold: 1
tone: medium
---
`GET xisl.sites.lazysite.io/` | 200, title **"... - Xi Software"**
`GET .../sitemap.xml?k=verify1` (fresh key) | 200, **154 bytes, 0 `<loc>` entries**
```

`Xi Software` is that domain's `site_name`, which reaches the page ONLY through
the alias overlay. So for this host the overlay applies, `$sv{content_root}`
resolves, and `$has_root` is true - which means

```perl
return if $sv{alias_host} && !$has_root;
```

cannot be firing. Generation is REACHABLE for the host whose registry is empty.

::: widebox
That narrows the remaining question to two, and they are distinguishable:
**does generation run and produce nothing, or does it not run because the
existing output is never removed?** The empty registry is independently
confirmed here with a fresh cache key, so the emptiness is not a reading
artefact.
:::

A third possibility now deserves equal billing, because it fits the empty case
better than the cache theory does: generation RUNS, and scans a root that holds
no registerable pages, producing an empty registry every time. If so, clearing
would work perfectly and change nothing visible - because the rebuild is also
empty. That would explain why `regenerate-registries` appears inert on this site
without any cache being involved.

Note the two sites differ and should not be merged: dhcf's registry has 21
entries and is frozen at an old build; xisl's has none and always has. A single
mechanism must explain both, or there are two.

# Watched before/after is the test

The reporter's discriminator is the right one and needs one addition - it must
be WATCHED:

1. Record the registry bytes.
2. Request a PAGE under the failing host.
3. Record the registry bytes again.

Unchanged means generation is not running or is producing the same empty
output; changed means it runs and the earlier readings were the stale artefact.
Neither outcome needs a shell.
