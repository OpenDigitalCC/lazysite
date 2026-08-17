---
title: "SM361 - a starter page models the pattern the briefing forbids, and does not say why it may"
subtitle: "`starter/forgot.md` ships a hand-authored `<form>` and an inline `<style>` block. The authoring briefing tells every agent never to do either. The page is right and the briefing is right; nothing anywhere says how both can be true."
brand: plain
status: candidate
status-note: "FILED 2026-08-17 from a partner agent's residual observations after the four-surface pass. Their framing was that a starter page ships the exact pattern the briefing forbids. Checking it directly narrows the finding and improves it: the form is NECESSARILY hand-authored - it posts to the auth CGI, and native forms bind to content handlers which cannot perform authentication - so the page is not wrong. What is wrong is that it is silent about being an exception, in the one place agents go to learn the conventions."
---

# What is there

`starter/forgot.md`, shipped with every site:

```html
<style> .reset-form { ... } </style>

<form method="POST" action="/cgi-bin/lazysite-auth.pl?action=forgot" class="reset-form">
  <label for="identifier">Username or email</label>
  <input type="text" name="identifier" id="identifier" required autocomplete="username">
  <button type="submit">Send reset link</button>
</form>
```

And in `starter/docs/ai-briefing-building-sites.md`, which every connected agent
is told to read first:

> **Serve through the engine.** Never drop hand-authored HTML into ...

with a checklist item to match. The MCP server instructions say the same thing
in stronger terms: forms are native, use `create_form` or a `:::form` block
bound to an operator-vetted handler, **never hand-written form HTML**.

# Why the page is not the defect

A password-reset form has to post to the auth CGI. Native forms bind to content
handlers, which store submissions and notify - they cannot perform
authentication, and making them able to would be a considerably worse idea than
this page. So the hand-authored form is the only shape available and the page is
correct.

The inline `<style>` is a weaker case but the same argument: a system page has
to render before a theme is chosen, on a fresh install with no layout activated.

# What the defect actually is

**It is silent about being an exception**, in the one place an agent looks to
learn what good looks like.

An agent reading the starter content to work out the conventions - which is
exactly what a new site agent does - finds a rule stated absolutely in the
briefing and contradicted without comment by the shipped example three files
away. The available conclusions are that the rule is soft, that the example is
stale, or that there is a distinction nobody wrote down. Two of those are wrong
and all three are reachable.

This is a teaching problem rather than a bug, and teaching problems propagate:
the pattern is copied into a real site, where none of the reasons apply.

# What would fix it

Say so in the page
: an HTML comment at the top of the form explaining that this is a SYSTEM page
  posting to the auth CGI, that native forms cannot authenticate, and that
  ordinary content must use `create_form`. It costs three lines and it lands
  where the pattern is read.

And state the boundary in the briefing
: the rule is currently absolute and has an exception, so it is not quite true
  as written. "Never hand-author form HTML for content; the system pages that
  post to the auth CGI are the exception and say so where they do it" is both
  true and still unambiguous about what an agent should do.

# What this is not

**Not a request to make native forms handle authentication.** The reason they
cannot is the reason they should not.

**Not a licence for hand-authored HTML generally.** The exception is narrow -
system pages that must reach the auth surface - and naming it narrowly is what
stops it being read as permission.

# Verification

- A starter page that departs from a briefing rule says why, where it departs.
- The briefing states the boundary rather than an absolute that its own shipped
  examples contradict.
- An agent following the briefing still cannot hand-author a content form.

# Related

`starter/docs/ai-briefing-building-sites.md` (the rule), `starter/forgot.md`
(the exception), and [[SM216]] / the native form handlers, which are what
content forms must use and what this must not be read as weakening.
