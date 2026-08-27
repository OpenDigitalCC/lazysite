---
title: "SM656: the admin bar is controlled by who is looking, not by what the page is, so an application page offers Edit-this-Markdown as its most prominent action"
subtitle: "Site agent, 2026-08-25: taking `ui` away removes the bar and the manager UI with it, which is not a trade anyone should make to stop an Edit link appearing over a data-entry screen"
brand: plain
standard-margins: true
status: partial
status-note: "PARTIAL - the request is built; the section-level option is not. `admin_bar: none` in a page's front matter stops the engine injecting the admin bar on that page, and is documented in /docs/frontmatter beside auth and auth_groups. Display only: it changes nothing about who may read or edit the page. THE api:/raw: DEFAULT WAS DELIBERATELY NOT BUILT, and the filing half-predicted it (\"it would not have helped here\"). Measured while building: an api: page renders NO <body>, so _inject_admin_bar_live's own first guard returns before anything is injected - a default there could never fire. The two assertions that appeared to prove it passed with the code REMOVED, which is how it was caught. The test now records the measured fact instead of testing a branch that does not exist. NOT BUILT: honouring the key on a SECTION, so an application governed as a section says it once rather than on every page. That is the filing's second preference and is real work - the ACL store already governs sections, so the natural shape is to read it there rather than to invent a second section mechanism. Two sabotages, both fail. THE MARKER TOOK TWO ATTEMPTS: the chrome stylesheet is on every page, and id=\"site-bar\" is the SITE's own navigation bar, which the fallback layout gives every visitor and which has nothing to do with the admin bar - the thing under test is the /manager/edit link."
---

# The mismatch

| Page | What the bar's Edit link does |
|---|---|
| An ordinary content page | Opens the Markdown. Exactly right. |
| An application page | Opens the Markdown of a page whose body is a script |

The bar is right about the person - they are an administrator, and on most
pages Edit is what they want. It is wrong about the page, and it has no way to
ask.

# Why the existing lever cannot solve it

`ui` is the only control, and it is per-account. The operator described here
administers the site *and* uses the application, so every option is wrong:

- Keep `ui`: the bar appears over the data-entry screen, offering to open its
  source in the Markdown editor.
- Remove `ui`: the bar goes, and so does the manager UI.

Neither is a decision about the page, because there is no decision about the
page available.

# The shape, in preference order

1. **A front-matter key.** `admin_bar: none`, alongside `auth:` and
   `auth_groups:`, which are already per-page. The page author knows what kind
   of page they have written; nobody else does.
2. **Honour it on a section.** These pages are already governed as a section by
   one ACL entry. A section that is an application is an application throughout,
   and saying it once beats saying it on every page.
3. **Default it off for pages carrying `api:` or `raw:`.** Those already declare
   "this is not a document". It would not have helped the reporting case - those
   pages take a normal layout deliberately, for the nav - but it is the cheap
   version and costs nothing.

The first is the request. The third is worth doing regardless, because a page
that has declared itself not-a-document should not be offered a document
editor.

# Why not CSS

Hiding the bar from inside the page would work today and is explicitly not
what is wanted. It hides the bar from an operator on a page where they might
genuinely want Manage, and a page fighting its own platform's chrome is worse
than the chrome. The point is to let the page state what it is, and let the
platform decide what to render - not to let the page win a fight.
