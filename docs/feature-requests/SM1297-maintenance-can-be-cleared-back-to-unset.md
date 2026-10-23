---
id: SM1297
title: "SM1297: the maintenance switch can be cleared back to unset"
subtitle: "Switched on and off through config-set, lazysite.conf read maintenance: off where it had been empty, and config-set refused the empty value. Empty is now accepted, meaning off, through config-set and the Config page's switch."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-23
raised-by: "edge walk of 0.16.1, observation O-1"
area: manager
status-note: "SHIPPED (PENDING) on n736: config-set takes an empty maintenance (unset, the same as off); the Config page's switch sends it when turned off. t/unit/manager/411, 385."
---

# What happened

The edge walk of 0.16.1 (O-1): after maintenance was switched on and then off through
config-set, the key read `maintenance: off` where it had been empty, and config-set
refused an empty value ("maintenance must be 'on' or 'off'"). [[SM1118]] gave the switch
two values and listed it with the keys that need one, so a site could never again read
like one that was never switched. The Domains page's copy of the switch (domain-set)
already took empty, clearing the domain's line.

# What shipped

- config-set accepts an empty (or blank) `maintenance` and writes the key empty. It means
  what an absent key means, off: the engine reads anything but `on` as off, and
  `lazysite check` treats empty as off and says nothing. `on` still needs the
  maintenance_access capability; anything else is still refused, and the refusal now
  says "'on', 'off' or empty (unset, the same as off)".
- The Config page's switch sends the empty value when it is off (its off value is `''`),
  so turning maintenance off on the page clears the key. A toggle may now name `''` as
  its off value: the page read `f.off || 'disabled'`, which took `''` for no value. A
  site whose conf reads `off` shows the switch off, and the next Save clears it, which
  changes nothing about the site.
- config-read answers `''` for the cleared key, as for a site that never set it.

# Tests

t/unit/manager/411 (new): on, off, then empty through config-set (the conf line is empty
again, config-read says so, blank is empty, anything else refused); with the key empty a
page is served and `lazysite check` is quiet; the Config page's form, rendered under node,
sends `''` for unset, `off` and switched-off `on`. With the old Config.pm or the old
config.md the test fails. t/unit/manager/385 no longer lists empty among the refused
values.
