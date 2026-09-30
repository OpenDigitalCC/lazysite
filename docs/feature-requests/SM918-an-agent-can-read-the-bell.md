---
id: SM918
title: "SM918: an agent can read the bell, through the same reader the manager uses"
subtitle: "The notice store's read surface shipped on the control API and had no MCP twin - t/lint/23 carried that as \"undecided - an MCP twin wants per-notice addressing (SM281 item 2) first\". That addressing shipped with SM485 on 2026-09-29, so the deferral was unblocked and the release manager ruled FULL PARITY, WITH THE CAPABILITY AS THE GATE. Built as one shared reader rather than a second copy, because a store read two ways is SM915 waiting to happen."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-09-30 on claude/n201-an-agent-can-read-the-bell. `read_notices` over MCP takes the SAME capability the control API's `notices` takes - `notifications` - so the two doors agree about who may read the bell, which is what 'the capability is the gate, not the channel' means in code. ONE READER: Lazysite::Manager::Notices, called by both CGIs; the reader moved out of lazysite-manager-api.pl because lazysite-mcp.pl cannot call into a sibling CGI, and writing a second one is exactly how SM915 got four readers of one registry with one of them right. THE MOVE CARRIED A FOUR-STATE REPAIR that was not in the brief and is the part worth reading: the old reader was `if ( open ... )` with no else, so a store that EXISTS and cannot be opened produced an empty list and unread=0 - a bell quiet because nobody looked. It now reports `store_unreadable` and logs through cannot_read, and the seen-marker write REFUSES on an unreadable marker rather than rewriting it and dropping every other operator's position. `notices-seen` is deliberately NOT twinned, and the reason is recorded in Lazysite::ControlApi::Actions rather than in t/lint/23's %API_ONLY (which may only name actions the declarative gate carries): the marker is a per-principal read cursor whose only consumer is a human's unread badge, an agent has no badge, and a cursor per partner is the first half of an inbox. Machine-to-machine messaging is SM646's XMPP connectors, not a mailbox grown on the side of this store. t/unit/lib/195, eight subtests; six sabotages, six caught - and the first attempt at one of them was a BAD sabotage that passed for a good reason, which is recorded in the script. FOUND ON THE WAY: SM917, the store-reader lint cannot see the `if ( open ... )` idiom at all - 51 such read-opens against 120 it can see. Filed with the measurement, not fixed here."
raised: 2026-09-29
raised-by: release manager ruling, after SM485 unblocked the deferral
area: mcp
---

# What the ruling settled

SM485's table ended with one row open: the notice-store read surface had shipped
its control-API half and its MCP twin was *"a RECORDED DEFERRAL, not a gap"*. The
deferral's own words in t/lint/23 named what it waited for -- per-notice
addressing, *"or every agent reads every operator notice"* -- and that addressing
shipped the day before this was built.

The ruling was full parity with the capability as the gate. In code that means
something quite specific, and it is worth stating because the alternative is
tempting and wrong:

**The MCP twin does not filter by `to`.** The control API's `notices` returns
every notice to any operator holding `notifications`, addressed or not. Building
the twin to show an agent only broadcasts plus its own addressed notices would
have invented a second, stricter policy on one channel -- two doors disagreeing
about what the same capability means, which is the defect SM652 fixed for
`read_submissions` and SM288 for group resolution. If holding `notifications` is
too much for a partner, the answer is not to grant it.

# One reader, and why that was the whole design

The reader lived in `lazysite-manager-api.pl`. `lazysite-mcp.pl` cannot call into
a sibling CGI, so an MCP twin is either a shared module or a second copy.

SM915 is the argument against a second copy, and it is a week old: one extension
registry, four readers, one of them correct, and the consequence was that XMPP
notice delivery had been silently off since SM817 on every site using the newer
spelling. A store with two readers has two answers from the day one of them is
edited, and nothing tells you which one a caller got.

So `Lazysite::Manager::Notices` holds `action_notices` and `action_notices_seen`,
both CGIs call it, and the principal is an ARGUMENT rather than a global -- the
two callers name that variable differently, and a module that reaches for one
CGI's `$auth_user` only works inside that CGI.

# The four states, which were not in the brief

The reader being moved read like this:

    if ( open my $fh, '<', _notices_path() ) {
        ...push notices...
    }

No else. Three of the four states collapse into one answer:

```datatable
columns: The store | The old answer | Now
widths: 5cm | 5.5cm | X
bold: 1
tone: medium
---
absent (new site) | `notices: []`, unread 0 | the same -- and correct, silently
holds nothing | `notices: []`, unread 0 | the same
exists, cannot open | **`notices: []`, unread 0** | `store_unreadable: 1`, logged by `cannot_read`
holds notices | the notices | the notices
```

A sysop whose notice store lost its permissions saw a bell that had nothing to
say. Over MCP it is worse: an agent has no engine log to go and read afterwards,
so the third row had to become a value in the response rather than only a log
line. It is an ADDITIVE field -- the manager ignores keys it does not know, so
nothing in the UI breaks, and a distinct rendering for the bell is a follow-on
that needs the manager's wording the way T3's did.

The seen-marker write got the same treatment from the other side. Rewriting a
marker file we could not read would have dropped every other operator's position,
so it refuses and says what it would have cost.

# Why `notices-seen` has no twin

Parity is not symmetry for its own sake. The marker is a per-principal read
cursor, and its only consumer is the unread badge in the manager header. An agent
has no badge; a cursor per partner is state that exists only to be read back by
the same partner later, which is the first half of an inbox.

That is not what notifications are for. They are simple and should stay simple --
machine-to-machine messaging is SM646's XMPP connectors, where the routing and
the anonymising are the point, not a mailbox grown quietly on the side of a bell.

`Lazysite::ControlApi::Actions` had always left `notices-seen` out of the token
map, so the code already said this; what was missing was the reason, and it is
written there now. It is NOT recorded in t/lint/23's `%API_ONLY`, and that is not
an oversight either: that map may only name actions the declarative gate carries,
and an entry for one it does not would fail the lint's own rule that a reason
recorded for something removed reads as a live decision.

# What the gates hold

  - `t/lint/23` pairs `notices` with `read_notices` by name, and refuses a
    pairing whose MCP half has gone (sabotaged; caught).
  - `Lazysite::Capabilities` lists `read_notices` under `notifications`, so
    `describe_capabilities` does not under-report what the grant gives --
    `t/lint/23` subtest 1 and `t/lint/105` both check this.
  - `t/lint/15` classifies the seen-marker write as exempt with its reason: one
    engine-named path, and the caller's principal is a JSON key, never a path
    segment. It appears there now only because moving the writer into `lib/`
    brought it into that lint's scope for the first time -- the write is not new,
    its classification is.
  - `t/unit/lib/195` pins the behaviour, including the three states the old
    reader could not express.

# Found on the way, and filed rather than folded in

`t/lint/121` -- the lint whose whole job is refusing a store reader that returns
empty in silence -- could not see the defect described above, because its matcher
requires `or` on the open line. Measured: 51 read-opens in the conditional form
across the files it scans, against 120 it can see. That is SM917, filed with the
measurement and a recommended option, and deliberately not fixed here: it is a
ceiling-and-shrink job across five files, not a line in this one.
