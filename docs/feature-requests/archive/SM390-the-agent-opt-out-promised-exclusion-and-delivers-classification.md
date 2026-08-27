---
title: "SM390: the agent opt-out promises exclusion and delivers classification"
subtitle: "The MCP instruction tells a partner that setting lazysite-agent/<partner-id> keeps their hits out of the visitor analytics. It keeps them out of the HUMAN class. They are still counted, as bot - which is a reasonable design and not what the sentence says."
brand: plain
standard-margins: true
status: shipped
status-note: "SENTENCE CORRECTED 2026-08-19; the behaviour is unchanged and is right. Reported from the field by a partner agent that followed the instruction, found its own traffic in the export, and concluded the opt-out was broken. It is not: classify() returns 'bot' for the agent UA before any other rule. Recording bot traffic rather than dropping it is the better design - an operator can see what their own tooling did - so the fix is to say so."
---

# What was promised, and what happens

The MCP connector tells every partner agent:

> set your User-Agent to `lazysite-agent/<partner-id>` so your hits stay
> out of the visitor analytics.

What the engine does is classify the request as **`bot`**, before the
AI-assistant and generic-bot rules. So the traffic is kept out of the
`human` counts and is still present in the export, under a class an
operator can see and filter.

::: widebox
**The behaviour is better than the promise.** Dropping agent traffic
entirely would leave an operator unable to see what their own tooling
did to their site - and unable to tell "my agent fetched this 400 times"
from "nobody visited". Recording it in its own class is the right
choice. The sentence was simply describing a different one.
:::

# How it was found

A partner agent followed the instruction, measured its own traffic in
the export, found it present, and reported the opt-out as not working.
That is the correct conclusion from the sentence they were given.

The same report raised a second symptom - some agent-UA requests
appearing in the `human` class - which is **not explained by this** and
is not fixed here. See the open note below.

# Still open, and deliberately not claimed as solved

The field also reported agent-UA requests classified `human`, and a
scanner sweep that did not promote. Neither reproduces here:

- `classify()` returns `bot` on the agent UA before any other rule, so a
  request carrying it cannot reach `human` through that function.
- The SM332 sweep promotes correctly in a clean fixture on **both**
  ingest paths - 17 distinct 404s from one token inside 13 seconds gives
  `human 0, scanner 21` through the server log and through the
  first-party log alike.

So the trigger logic is not the defect, and the remaining variable is
state carried between export runs, which cannot be diagnosed from here
without the instance's own export cache. **Not claimed as understood** -
the last time a plausible story fitted every symptom it was still the
wrong story ([[SM381]]).

# Related

[[SM213]] (visitor-level classification), [[SM332]] (the behavioural
sweep), [[SM381]] (the reason this filing stops short of a cause).
