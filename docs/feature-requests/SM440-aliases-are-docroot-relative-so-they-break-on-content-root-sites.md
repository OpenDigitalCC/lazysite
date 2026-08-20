---
title: "SM440: aliases redirect to a URL that includes the content root, and 404"
subtitle: "An alias on a page under a domain's content_root sends the visitor to the docroot-relative path. Declaring the alias is worse than leaving it off - a redirect to a 404 instead of a plain one - and it defeats the standing rule that every retired URL gets an alias on its successor."
brand: plain
standard-margins: true
status: candidate
status-note: "FILED 2026-08-20 from the field, cause CONFIRMED IN THE SOURCE rather than inferred from behaviour. THE SYMPTOM: a page at sites/dhcf/publications/thesis.md declaring `aliases: /thesis`, on host dhcf.sites.lazysite.io whose content_root is sites/dhcf. The alias fires and 301s the visitor to /sites/dhcf/publications/thesis, which 404s - the content root appears in the target, and the vhost has already stripped it at request time. THE CAUSE: Aliases::index_page takes $rel relative to the DOCROOT and passes it straight to canonical_url_for, which only strips .md and index and prefixes a slash - it has no knowledge of content roots and is not the thing at fault. The callers hand it a docroot-relative path: lazysite-dav.pl's PUT does ($arel = $r->{abs}) =~ s{^\\Q$DOCROOT\\E/?}{} before calling index_page. On a single-site instance the docroot and the content root coincide, so this has always looked correct, and a single-site test passes either way - which is presumably how it survived. deindex_page shares the derivation, so stale entries may fail to clear on the same paths; that follows from the code and was not tested. A SECOND DEFECT WITH THE SAME ROOT CAUSE, found while confirming the first: alias_map_path is \"$docroot/lazysite/aliases.json\" - ONE MAP FOR THE WHOLE INSTANCE. So on a multi-domain instance an alias declared by one domain's page answers on EVERY domain, and index_page's 'alias claimed by two pages' warning is instance-wide rather than per-site. Two domains cannot both alias /about. That is the same docroot-relative assumption showing up in the storage rather than in the derivation, and SM151 exists precisely to serve many sites from one instance. WHY IT MATTERS MORE THAN THE PAGE COUNT SUGGESTS: the standing conversion rule is that every retired URL gets an alias on its successor. Every site converted onto a content root has therefore been given aliases that redirect into a 404 - and declaring one is WORSE than declaring nothing, because a plain 404 at least tells the truth. SCOPE: every domain with a non-empty content_root; six on the reporting host. INVISIBLE BY CONSTRUCTION: the domain record, the render, the alias map and the 301 itself all look correct - only following the redirect shows it. The reporter left the alias declared on the affected site deliberately, because that site moves to its own domain shortly where the content root is empty and it will resolve correctly, and recorded it as a staging-only breakage in the site's README."
---

# The shape

```datatable
columns: Thing | Value
widths: 6cm | X
bold: 1
tone: medium
---
Page | `sites/dhcf/publications/thesis.md`
Declared | `aliases: /thesis`
Host | `dhcf.sites.lazysite.io`, `content_root: sites/dhcf`
Alias target stored | `/sites/dhcf/publications/thesis`
What the visitor gets | **301, then 404**
```

::: widebox
A page with no alias returns a plain 404 for `/thesis`. A page WITH the alias
returns a redirect to a 404. Declaring it makes the outcome worse, which is the
opposite of what the feature is for.
:::

# The cause, from the source

`canonical_url_for` is not at fault - it strips `.md`, collapses `index`, and
prefixes a slash:

```perl
sub canonical_url_for {
    my ($rel) = @_;
    $rel =~ s{^/+}{};
    $rel =~ s{\.md\z}{};
    $rel =~ s{(?:^|/)index\z}{};
    my $url = "/$rel";
```

What reaches it is wrong. `index_page( $docroot, $rel, $content )` is called
with a DOCROOT-relative path - the DAV PUT derives it as

```perl
( my $arel = $r->{abs} ) =~ s{^\Q$DOCROOT\E/?}{};
Lazysite::Aliases::index_page( $DOCROOT, $arel, $body );
```

On a single-site instance the docroot IS the content root, so the derived URL
is right and always has been. On a content-root site the prefix the vhost
strips at request time is baked into the target.

# The same assumption, in the storage

```perl
sub alias_map_path { return "$_[0]/lazysite/aliases.json" }
```

One map per INSTANCE, not per site. So on a multi-domain instance:

- an alias declared by one domain's page answers on every other domain;
- two domains cannot both claim `/about`;
- the "alias claimed by two pages" warning fires across sites that have nothing
  to do with each other.

Found while confirming the first defect, and recorded here rather than
separately because it is the same docroot-relative assumption - once in the
derivation, once in where the answer is kept.

# Why it is worse than the page count

The standing conversion rule is that every retired URL gets an alias on its
successor. Every site converted onto a content root has therefore been handed a
set of aliases that redirect into 404s - the exact URLs an inbound link or a
search result is most likely to use.

Nothing reports it. The domain record, the render, the alias map and the 301
are all individually correct-looking, and only following the redirect reveals
it. A single-site test passes either way.

# Remedy sketch, not a decision

Derive the canonical URL relative to the page's CONTENT ROOT rather than the
docroot, and key the map per domain - or store the host alongside each entry so
one file can serve several sites without them colliding. Both halves want
deciding together, since fixing the derivation while leaving one shared map
would make `/about` resolve correctly for whichever domain wrote it last.

Worth a test that a single-site instance cannot pass: a content-root domain
whose alias target must NOT contain the content root.

# Field confirmation: it serves ANOTHER SITE'S PAGE under the neighbour's domain

Tested against a neighbouring site on the same instance rather than reasoned
about:

```datatable
columns: Request | Result
widths: 7cm | X
bold: 1
tone: medium
---
`dhcf.sites.lazysite.io/thesis` (own site) | 301 to `/sites/dhcf/publications/thesis`, **404**
`sites.lazysite.io/thesis` (**the DEFAULT host, an unrelated site**) | 301 to the same path, **200 - it SERVES**
```

::: widebox
The default host's content root IS the docroot, so the leaked path resolves
there. **One site's alias silently serves that site's page under a neighbour's
domain**, at a URL the neighbour never defined. The two defects do not merely
want deciding together - they COMPOUND. Fix the derivation alone and one site
can still claim a path on every other. Fix the map alone and every content-root
site still redirects into its own 404.
:::

# What it can and cannot do

Bounded by reading the consumer, because the difference matters for how urgent
this is:

`_alias_lookup` is called from `not_found` - it is the **404 path only**. So an
alias can claim a path the neighbour does NOT already serve, and cannot
override one it does. There is no hijack of an existing URL; a neighbour's real
`/contact` stays theirs.

What remains is still serious on a multi-domain instance: any site can occupy
any unused path on every other site, and on any host whose content root is the
docroot it will answer 200 with the wrong site's content. That is the SM248
class - the visitor is told whose site this is, incorrectly - except SM248 was
a favicon and this is a whole page under someone else's domain.

# The judgement that was reversed, and why it is recorded

The reporter had originally left the alias declared, on the reasoning that it
was harmless on their own site and would resolve correctly at cutover when the
content root goes empty. That reasoning was sound on its premise. The premise
was wrong: the cost was not landing on their site, it was landing on a
neighbour's, **and a staging neighbour cannot consent to that**.

The alias is now removed. Both hosts 404 on `/thesis`,
`/publications/thesis` serves normally, and the site's README carries an
explicit instruction to re-add it at cutover, when the content root is empty
and there are no neighbours to leak into.

Recorded because the reversal is the useful part: "harmless on my own site" is
not the test on a shared instance, and the alias feature gives every site on it
the ability to write into every other site's URL space.
