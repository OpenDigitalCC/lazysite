---
id: SM859
title: "SM859: a partner's brief listed two capabilities where the grant held four, and said nothing about the difference"
subtitle: "The brief derives its capability list from the same keys whoami answers from - and then deletes ui, api and mcp as channels rather than authority (SM086), while leaving webdav in. Silently. A partner comparing its brief with whoami finds a difference and no explanation, and the obvious reading is that capabilities were added since the brief was minted."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-09-12 for 0.13.14. The brief now carries a `channels:` block naming ui, api and mcp with the value the grant actually has, beside the authority list, and says that whoami is the live answer and wins. The SM086 split is unchanged - this states it rather than relitigating it. t/tools/73 drives the real brief for a grant holding webdav+api+mcp+manage_content and for one holding neither channel; it failed on the first run."
raised: 2026-09-12
raised-by: site agent (1313E-02 follow-up, from its own re-paired account)
area: partner
---

# What was found

The site agent, re-paired after the release manager minted a fresh key, compared
its brief with `whoami`:

> "the brief's capability snapshot listed six, and `whoami` reports eight - it
> does not mention `api` or `mcp`, the two channel capabilities, though the
> brief's own YAML `capabilities:` block does list `webdav`. The brief says
> `whoami` is the authority and it is right, but a reader comparing the two
> lists would think two capabilities had been added since it was written."

Reproduced here on a grant holding `webdav`, `api`, `mcp` and `manage_content`:

```yaml
capabilities:
  - manage_content
  - webdav
```

Two of four. `mcp` appeared nowhere in the brief at all.

# Why it happened, and why it is not what it looks like

The omission is deliberate and commented in the source: `ui`, `api` and `mcp`
are CHANNELS rather than authority (SM086), described elsewhere in the brief by
name where the partner is told how to connect. The list is derived from the same
key list `whoami` answers from precisely so the two cannot drift (SM662) - and
then three keys are deleted from it without a word.

`webdav` is what makes it read as a defect rather than a design: it stays in the
list, and it gates a surface exactly as `api` and `mcp` do. So the brief looks
like a complete list that is missing two entries.

# The fix

Not to relitigate SM086. The split is reasonable; the silence was not. The brief
now carries a `channels:` block beside the capability list, naming `ui`, `api`
and `mcp` with the value the grant actually holds, saying why they sit apart -
including why `webdav` does not - and naming `whoami` as the live answer that
wins wherever the two differ.

A brief is a snapshot taken when it was minted. Saying so, next to the numbers a
reader would otherwise compare, is the whole fix.

# Held by

`t/tools/73-the-brief-accounts-for-every-capability-held.t` generates the real
brief through the CLI for a grant holding both channels and for one holding
neither, and asserts the block names each with the right value, that a channel
is never smuggled into the capability list, and that `whoami` is named as
authoritative. It failed on the first run.

# Related

SM086 (channels are not authority - the split this states), SM662 (one key list
behind every capability answer), [[SM821]] (whoami's own shape, which is what a
reader compares the brief against).
