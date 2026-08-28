---
title: "SM671: `whoami` carries the whole plugin inventory, so the answer to 'who am I' is mostly a list of plugins"
subtitle: "Site agent, 2026-08-28, driving whoami over the control API with three live tokens: 'the output's bloated by a big plugins array - so probably offer the plugin array as an additional call'"
brand: plain
standard-margins: true
status: candidate
---

# What it carries

`action_whoami` returns identity, capabilities, reachability, services, groups,
scope, layouts, optionally themes - and `plugins`, a per-plugin record of id,
name, description, version, and for some callers `_enabled`, `config_schema` and
`config_keys`.

The plugin array is unbounded: it grows with what is installed, and its
`config_schema` entries are the largest structures in the payload. On an
instance with a full plugin set it dominates a response whose question was "what
may this caller do".

# Why it is there, and why that reasoning still holds

SM589 put it there deliberately: the inventory says WHICH FEATURES EXIST, which
a partner needs before it can use one. SM565 narrowed what each caller sees of
it. Neither decision was wrong and this filing does not reopen them - a partner
that cannot discover the feature set is the problem those filings solved.

The objection is to the COUPLING, not the content. One call answers two
questions - who am I, and what is installed - and a caller that wants the first
pays for the second on every request. `whoami` is the call an agent makes most
often, including as a preflight before anything else.

# The shape

A separate call for the inventory - `plugins-list` alongside the existing
gated `plugin-list`, or an argument to `whoami` - and `whoami` keeps only what
identifies the caller. `site_capabilities` stays: it is derived, small, and
genuinely part of "what may I do here".

Open, and the reason this is a filing rather than a patch:

1. **Removing a field is a contract change.** Anything reading
   `whoami().plugins` breaks. The safe order is to add the new call, announce,
   then remove - and the sites agent's own tooling is one of the readers.
2. **Or make it opt-in rather than opt-out** - `whoami` returns it only when
   asked. Same contract break, stated the other way.
3. **Or leave the coupling and shrink the content** - drop `config_schema` from
   `whoami` and keep it only on `plugin-list`, which is the largest part of the
   bloat and the part least related to identity. Smallest change, no new call,
   and it does not answer the agent's actual point.

(3) is available now and cheap; (1) is what was asked for. They are not
exclusive - (3) first would relieve most of the weight without breaking anyone.

# Measured, not assumed

Not yet. The next step is to measure a real `whoami` payload with and without
the plugin array on an instance with a representative plugin set, so the size
claim is a number rather than an adjective. The agent reports it as bloat from
outside; how much is not established.

# Related

[[SM589]] (why the inventory is in whoami), [[SM565]] (what each caller sees of
it), [[SM525]] (whoami as where an agent checks its own reach), [[SM670]] (the
other control-API response-shape finding from the same run).

# Not started
