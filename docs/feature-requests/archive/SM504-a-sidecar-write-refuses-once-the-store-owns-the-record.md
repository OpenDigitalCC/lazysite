---
title: "SM504: a sidecar write refuses once the store owns the record"
subtitle: "The operator's instruction after SM245: on a site whose briefs plugin is enabled, a .brief write fails with the replacement named - never lands as an inert file. Gated per site, never per version; a half-migrated estate is the normal state."
brand: plain
standard-margins: true
status: shipped
status-note: "OPERATOR'S INSTRUCTION 2026-08-24, relayed by the field agent with the argument that decided it, kept verbatim: a brief is the record of WHY something was done, often the channel between two agents who never speak, so its failure mode is not a broken page anyone notices - it is a note nobody reads, found months later by someone looking for a decision that was, as far as its author knew, written down. Every signal the writer gets says it worked: 201, file on disk, reads back byte-identical. None is wrong on its own terms, which is what makes the combination misleading - and unlike the acl-set shape it resembles, a sidecar cannot be checked from outside at all, because reading it back returns exactly what you wrote. BUILT to the filing's four points: B1 refused on every write channel (one guard in action_save covers manager and MCP, which route through it; WebDAV PUT enforces the same in lazysite-dav.pl, path-based, before the body is read - the SM189 wiring exactly); B2 the refusal names the replacement (append_brief / brief-append, {path, entry}) - SM228's shape; B3 GATED ON THE PLUGIN BEING ENABLED ON THAT SITE, never the version: migration is per site as each is revisited, nothing is deleted, no estate sweep, no deadline - a site on sidecars keeps working indefinitely and the test holds that with a second unmigrated site; B4 reads untouched - an existing sidecar stays readable so an agent can see what is there before migrating. SCALE DATAPOINT from the reporting agent: 22 sidecar files across their trees, twelve a complete set for one site, none urgent - one agent's working set, which is how long the interim lasts. Practice guidance (theirs, correct): probe whether the brief tools answer on THIS site; if yes append_brief, if no the file is still right."
---

# The instruction

Once the contract plugin is enabled on a site, a `.brief` write FAILS -
with the replacement named - rather than landing as an inert file no
listing shows and no migration imports.

# Why refusal beats inert (the agent's argument, kept)

A brief's failure mode is a note nobody reads. Every signal the writer
gets says it worked, and the one check that catches other silent failures
- reading it back - returns exactly what you wrote. SM189 is the
precedent: a file shaped like a record that is not a record is refused at
write time, on every channel.

# The four points, as built

B1 every write channel; B2 the replacement named; B3 gated on the plugin
per site, never the version - the half-migrated estate is normal and
indefinite; B4 reads untouched.
