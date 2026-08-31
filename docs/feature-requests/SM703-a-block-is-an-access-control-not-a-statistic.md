---
id: SM703
title: A blocked address is refused the site, so its list does not belong on a statistics page
raised: 2026-08-31
raised-by: release manager
area: manager-ui
status: shipped
status-note: "SHIPPED (unreleased; lands in 0.11.9). The blocked-address list and its per-address unblock sat on Visitor Statistics. MEASURED, because the placement implied the opposite: lazysite-auth.pl's _bad_url_guard calls _bad_url_deny, which answers 403 Forbidden and exits before anything is served - a blocked address is REFUSED THE SITE, not merely omitted from the numbers. On a page of statistics that reads as a reporting filter, which is the wrong mental model for an access control. The list moved to Plugin Config, onto the bad-url-blocker card that owns the behaviour, and the panel now says plainly what a block does. Visitor Statistics keeps a card pointing at it, because moving a control without leaving a pointer strands the operator who knew where it was. The plugin's own description said 'Blocked IPs and unblock are on the Visitor Statistics page' and now says otherwise."
---

# The question that settled it

> Are blocked IP's prevented from seeing the site, or excluded from stats?

**Prevented from seeing the site.** `lazysite-auth.pl`:

    require Lazysite::BadUrl;
    _bad_url_deny() if Lazysite::BadUrl::is_blocked( $DOCROOT, $ip );

    sub _bad_url_deny {
        print "Status: 403 Forbidden\r\n";
        ...
        exit 0;
    }

The request is refused and the process exits. Nothing is rendered, nothing is
served, and the address is not "hidden from the numbers" - it never gets a page
to be counted for.

# Why the placement mattered

A control's location is a claim about what it does. On a page of visitor
statistics, a list of addresses with an Unblock button reads as a reporting
filter - something that changes what you are shown. It is the opposite: it
changes what the world is shown.

An operator who unblocks an address from a statistics page could reasonably
believe they were adding it back to a chart. They are re-admitting it to the
site.

# What moved

- The list, and per-address unblock, are on **Plugin Config**, on the
  `bad-url-blocker` card - the plugin that does the blocking.
- The panel opens with a sentence saying what a block is: refused the site,
  403, served nothing, and unblocking takes effect on the next request.
- **Visitor Statistics keeps a card** naming where the list went and why.
  Moving a control without leaving a pointer strands the operator who knew
  where it used to be.
- The plugin's own description no longer sends the reader to the statistics
  page.

# Note on the test that moved with it

`t/unit/plugins/28` protected "a card nobody opens costs no request", written
around the blocked-address card. That property is real and still tested - the
journeys card exercises the same deferred-fetch machinery - so the test now
asserts it there, and additionally asserts that the blocked list is NOT on the
statistics page and that a pointer to its new home is.

# Related

SM128 (the auto-blocker), [[SM424]] (the deferred-fetch card machinery whose
test this rearranged).
