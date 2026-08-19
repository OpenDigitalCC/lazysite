---
title: "SM392: a promoted visitor token masks every later classification from that source"
subtitle: "Visitor-level scanner promotion is sticky and overrides per-request user-agent classification. An AI assistant arriving from a token that previously did anything sweep-shaped is invisible as AI - and on a real site that token is a shared egress IP."
brand: plain
standard-margins: true
status: shipped
status-note: "FIXED 2026-08-19. The two identities separate: counting stays on the visitor token hmac(ymd|ip), and the sweep accumulator and promotion key on token+user-agent. A scanner and a browser behind one address promote independently. NO engine change and no new retained data - the plugin already holds both fields and the token is anonymised at write. Measured: a sweep, Googlebot and a person behind one address give scanner 6 / bot 1 / human 1, where the shipped behaviour gave scanner 8 / bot 0 / human 0. Two wrong designs are asserted against: weakening the promotion, and putting the user-agent in the COUNTING token, which would make one person with two browsers into two visitors."
---

# What was measured

A partner agent tried to test whether the `ai` class detects AI
assistants, by requesting real pages as GPTBot, ChatGPT-User,
ClaudeBot, Claude-User, PerplexityBot, CCBot, Google-Extended,
Bytespider, meta-externalagent and Googlebot as a control.

**All eleven came back `scanner`** - including Googlebot on a 200.

Their own reading was that the test was invalid, because all eleven
carried a token already promoted by their earlier probing. That is
right, and the invalidity is the finding.

# Why it matters beyond a spoiled test

[[SM213]] classifies per VISITOR rather than per request, deliberately:
a scanner's homepage hit should not count as a human visit just because
that one request looks ordinary. The promotion is sticky for the window,
which is what makes it work.

::: widebox
**The same stickiness means a token that once looked sweep-shaped
classifies everything from that source as scanner afterwards** -
whatever the user-agent says, and whatever the request is. An AI
assistant fetching a page for a person is then invisible as AI, for the
rest of the window.
:::

On a real site that token is derived from the visitor, so this is any
**shared egress**: a corporate NAT, a cloud region, an assistant's
fetcher pool. One sweep from behind a NAT and every genuine visitor
behind it is a scanner until the window rolls.

# What this is not

It is not an argument against visitor-level classification, which
answers a question per-request classification cannot. It is an argument
that **a strong per-request signal should be able to outrank a stale
per-visitor one** - a named AI user-agent on a 200 for a real page is
not a sweep, whatever the token did earlier.

# The fix

Counting stays on `hmac(ymd|ip)`. The sweep accumulator and the
promotion key on **token + user-agent**.

```datatable
columns: Behind one shared address | Shipped | Fixed
widths: 6.0cm | 2.4cm | X
bold: 1
tone: medium
---
a scanner sweeping six missing paths | scanner 8 | scanner 6
Googlebot on a real page | (scanner) | **bot 1**
a person browsing | (scanner) | **human 1**
---
```

No engine change and nothing new retained: the plugin already holds both
fields, and the token is anonymised at write.

::: widebox
**Two fixes that would have been worse, both asserted against.** Weakening
the promotion - SM213's visitor-level marking and SM332's reach-back are
correct, and the reach-back is what pulls a sweep's homepage hits out of
the journey metric. And putting the user-agent into the COUNTING token,
which would make one person with two browsers into two visitors and break
the number the feature exists to produce.
:::

# Still open



Whether the answer is precedence (a named AI/browser UA on a successful
content fetch escapes the promotion), decay (promotion ages out faster
than the window), or per-source separation (the token is not the only
identity). Each has a failure mode worth thinking about before choosing
- the first is the one a spoofing scanner would aim at.

# Also open, and related

There is currently **no way to ask the classifier directly**. Testing
the `ai` class from outside needs a clean token, and an agent that has
done any probing cannot get one. A `--classify UA PATH STATUS` mode
would make the classifier testable without generating traffic, and would
have made the eleven-agent test valid.

# Related

[[SM213]] (visitor-level classification), [[SM332]] (the promotion that
sticks), [[SM391]] (the rules this decides between).
