---
title: "SM392: a promoted visitor token masks every later classification from that source"
subtitle: "Visitor-level scanner promotion is sticky and overrides per-request user-agent classification. An AI assistant arriving from a token that previously did anything sweep-shaped is invisible as AI - and on a real site that token is a shared egress IP."
brand: plain
standard-margins: true
status: candidate
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

# Not yet decided

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
