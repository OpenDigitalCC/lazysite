---
title: "SM276 - Localise the engine's own chrome"
subtitle: "SM179 gave content a language. The pages the engine generates itself - login, validation errors, 404 - are still English on every site, whatever language the content is in."
brand: plain
status: candidate
status-note: "RULED 2026-09-29: ENGLISH ONLY. The engine ships one set of defaults and does not own a translation set. The reason is the one this filing deferred for in the first place: owning translations means owning their staleness and the question of what happens to a language nobody has translated, which is a standing obligation on every future change to visitor-facing wording. The per-site override makes it unnecessary - a French site supplies its own, and for the five system PAGES it can already do so today by dropping its own login.md into its content root, with no code at all. So the extraction produces an English default set plus the lookup, and nothing else. PREVIOUSLY: DOOR SETTLED 2026-09-29, and NOTHING BUILT YET - status stays candidate. The ruling left one thing to the build: lazysite/templates/system/ is protected, so a site's own translation file needs either a validating action or somewhere else to live. MEASURED, three ways, from a running engine. (1) The protected tree really is closed: lazysite-dav.pl refuses with \"only lazysite/layouts/ is writable over WebDAV; the rest of lazysite/ is protected\". (2) Somewhere else already works - _system_page_md resolves a system page content root, then docroot, then engine default, and driven through the real request path with all three present, ALL THREE TIERS FIRE: a content-rooted French host gets its own copy. So a language site already overrides a system page by writing ordinary content, with no action and no door. (3) A .conf in content space is writable but never servable - conf is on SM797's static denylist. CONCLUSION: the site file is <content root>/lazysite-strings.<lang>.conf and the engine default is <lazysite>/templates/system/strings.<lang>.conf - one mechanism, shared with the pages. AND THE SCOPE IS SMALLER THAN FILED in the half that matters: the five system PAGES (login, claim, 402, 403, 404) are ALREADY localisable today by that tier-1 override, so they need documentation and a decision about whether the engine ships translated defaults, not code. The extraction is about the strings compiled into Perl: at least 38, a floor - 15 in plugins/form-handler.pl, 12 in lazysite-processor.pl, 11 in lazysite-auth.pl. THE MEASUREMENT TOOK THREE ATTEMPTS and each wrong one returned a UNIFORM answer, which is indistinguishable from \"no difference\": the fixture ships its own 404.md so tier 2 always won, the rendered 404.html is cached so a rewritten source was not re-read, and an alias content root only applies when the host is in alias_hosts: - which t/unit/processor/41's own header warns about. SEQUENCING, so the first commit does not fight two things at once: two of the 38 shipped today in SM579's closed banner map, which t/lint/156 pins equal to a second copy in the processor because ADR 0001 keeps the render path module-free. Start with lazysite-auth.pl's eleven login and claim messages - the filing names them first and nothing pins them - and fold SM579's pair in once the processor has its own reader. PREVIOUSLY: SPLIT from SM179 on 2026-08-11. SM179 phases 1-7 delivered multilingual content (language sets, hreflang alternates, per-domain lang, content-root-relative resolution) and went out in 0.7.27. P8 was deferred BY DESIGN at the time, not abandoned - but it sat inside a shipped filing where nobody would find it. Not started."
---

# SM276 - engine-chrome localisation

## The gap

SM179 made *content* multilingual: a site declares its language, pages
carry hreflang alternates, a language set links counterparts, and a
content-rooted domain resolves includes relative to its own root. That
works and is deployed.

The pages lazysite generates itself did not follow. A visitor to a French
site who hits a protected page gets an English login form; a failed form
validation answers in English; the 404 is English. The site is
multilingual and the engine speaking through it is not.

## Why it was deferred, and why that was right

Content localisation is the operator's own words in their own files -
lazysite carries them. Engine chrome is *lazysite's* words, so localising
it means shipping translations, which means owning a translation set, a
fallback chain, and the question of what happens to a language nobody has
translated. That is a different kind of commitment from rendering the
operator's Markdown, and bundling it into SM179 would have delayed
something complete for something open-ended.

## What it needs

**The string set.** Every string the engine emits to a visitor: the login
page, claim, 402/403/404, form validation messages. These now live in the
protected `lazysite/templates/system/` tree (SM201), which is the right
place for them to become localisable.

**A fallback chain, stated.** Requested language, then site language, then
English. A missing translation must degrade to a readable page, never to a
blank or a key name.

**A decision on who supplies translations.** Bundled with the engine and
maintained by the project, or overridable per site so an operator can
supply their own? The second is cheaper for the project and better for
sites with house style - and it is the model already used for layouts and
themes.

## The decision this waits on, named (2026-09-28)

Taken off the overnight list and stopped here. Of the three things "What it
needs" lists, two are work and one is a ruling - **who supplies
translations** - and it has to come first, because it decides where the
strings live and therefore what the extraction produces.

**RULED 2026-09-29: per-site overridable, with the engine shipping the
defaults** - the second option, and the model layouts and themes already
use. So the fallback chain is: the site's own file for the requested
language, then the engine's, then the site language, then English.

**And the consequence named below is now work rather than a question.**
`lazysite/templates/system/` is protected, so a site's own translation file
cannot be written by a general channel: it needs the door the table
descriptors got - an action that validates the file before storing it - or
it lives somewhere else. That is the first thing to settle when this is
built, because it decides what the extraction produces.

# THE DOOR, SETTLED 2026-09-29 - it lives somewhere else, and that somewhere already works

Three measurements, each from a running engine rather than from reading.

**1. The protected tree really is closed to a general channel.**
`lazysite-dav.pl` refuses with, in its own words, *"only `lazysite/layouts/` is
writable over WebDAV; the rest of `lazysite/` is protected"*. So nothing under
`lazysite/` outside `layouts/` can hold a site's own file without a new
validating action - the ruling's first option, and it would cost an action and
its registration points.

**2. "Somewhere else" is content space, and it is already proven for the pages.**
`_system_page_md` resolves a system page in three tiers: the domain's content
root, the primary docroot, then the protected engine default. Driven through the
real request path with all three present (`tmp/sm276-door.pl`):

| | `example.com` | `fr.example.com` (own content root) |
| --- | --- | --- |
| engine default only | tier 3 | tier 3 |
| plus a docroot copy | tier 2 | tier 2 |
| plus the French root's own copy | tier 2 | **tier 1** |

All three tiers fire. **A language site already overrides a system page by
writing ordinary content into its own content root** - no protected tree, no
action, no new door. It took three attempts to measure: the fixture ships its own
`404.md` (so tier 2 always won), the rendered `404.html` is cached (so a rewritten
source was not re-read), and an alias content root only applies when the host is
declared in `alias_hosts:`. Each wrong version returned a uniform answer, which
is indistinguishable from "no difference" - `t/unit/processor/41`'s header warns
about exactly the third one.

**3. A `.conf` in content space is writable but never servable.** `conf` is on
SM797's static denylist, with `ini env pem key`. So a strings file can sit beside
the content it belongs to, be written by any channel that writes content, and
still never be handed to a visitor.

**So: the site's file is `<content root>/lazysite-strings.<lang>.conf`, and the
engine's default is `<lazysite>/templates/system/strings.<lang>.conf`.** One
mechanism, shared with the pages, and no second answer to "where does this site's
wording live".

# AND THE SCOPE IS SMALLER THAN FILED, in the half that matters

The filing lists "every string the engine emits to a visitor: the login page,
claim, 402/403/404, form validation messages". Measured, those are two different
problems and only one is unbuilt:

- **The five system PAGES** - `login`, `claim`, `402`, `403`, `404` - are
  **already localisable today**, by the tier-1 override above. Nothing needs
  building for them. What they need is *documentation* saying so, and a decision
  about whether the engine ships translated defaults or only English.
- **The strings compiled into Perl** are the actual extraction.
  `tmp/sm276-inventory.pl` counts them on the surfaces a visitor meets:

| File | Visitor-facing prose strings |
| --- | --- |
| `plugins/form-handler.pl` | 15 |
| `lazysite-processor.pl` | 12 |
| `lazysite-auth.pl` | 11 |

At least **38**, and that is a floor - the pattern is deliberately narrow.

# ONE SEQUENCING NOTE BEFORE THE EXTRACTION STARTS

Two of those 38 shipped on 2026-09-29, in SM579's closed `token => sentence`
banner map. That map is the right shape for a string set, and `t/lint/156` now
pins it equal to a second copy in the processor, because ADR 0001 keeps the render
path module-free. So converting the form handler's sentences first would put the
extraction straight through that lint.

The cheaper order is to take a surface that is **not** entangled with it -
`lazysite-auth.pl`'s eleven login and claim messages, which the filing names
first and which nothing else pins - prove the mechanism end to end there, and
fold SM579's pair in when the processor's own reader exists. Otherwise the first
commit has to solve the render path's module-free constraint and the extraction at
the same time.

The reasoning, as it stood before the ruling: the filing's own
recommendation is the second option (overridable per site,
the model layouts and themes already use) and it is the right one, but it is
not only cheaper - it changes the shape:

- **Bundled** means one file per language in the engine tree, upgraded with
  the engine, and a site that wants different wording cannot have it.
- **Per-site overridable** means a lookup with the fallback chain the filing
  states (requested language, site language, English) reaching a site file
  first - and an upgrade must not overwrite a site's own wording, which is
  the rule `lazysite/templates/system/` already has to keep for the system
  pages themselves.

There is a second question the filing does not raise, and it matters for the
same reason: **`lazysite/templates/system/` is protected, so a site's own
translation file cannot be written by a general channel.** It needs the door
the descriptors got (an action that validates and stores) or it needs to live
somewhere else. That is a design consequence of the ruling, not a separate
piece of work.

## Not in scope

The manager UI. It is operator-facing rather than visitor-facing, its
audience is far smaller, and it is a much larger string set. If it follows
it should be its own filing.

## Related

SM179 (content multilingualism, shipped 0.7.27), SM201 (the protected
system-page tree these strings live in), SM110/SM151 (per-domain config).
