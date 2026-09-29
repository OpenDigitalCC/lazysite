---
title: "SM276 - Localise the engine's own chrome"
subtitle: "SM179 gave content a language. The pages the engine generates itself - login, validation errors, 404 - are still English on every site, whatever language the content is in."
brand: plain
status: candidate
status-note: "SPLIT from SM179 on 2026-08-11. SM179 phases 1-7 delivered multilingual content (language sets, hreflang alternates, per-domain lang, content-root-relative resolution) and went out in 0.7.27. P8 was deferred BY DESIGN at the time, not abandoned - but it sat inside a shipped filing where nobody would find it. Not started."
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
