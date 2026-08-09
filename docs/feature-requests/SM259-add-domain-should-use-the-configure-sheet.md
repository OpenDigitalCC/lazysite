---
title: "SM259 - Adding a domain is a different, clumsier form from configuring one"
subtitle: "The Configure sheet works well. Add domain is a separate inline panel with its own markup, its own field set and its own idea of the same settings - so the same job is done twice, two ways, and only one of them is good."
brand: plain
status: shipped
status-note: "IMPLEMENTED 2026-08-09. The Configure sheet gained a create mode; #add-panel, toggleAdd and addDomain are retired, and t/lint/29 keeps them retired. All three create-only behaviours survived the move (copy-settings-from, seed-a-home-page, the live site-URL derivation), and the add form better per-field help text was carried IN rather than lost - as a CREATE_HINTS overlay, because two hints read differently before the domain exists. Reported by the operator 2026-08-08 while working on a multi-domain instance: 'the edit modal works well, but the add new is still clumsy - can the modal be used for adding new?' The Configure sheet arrived in 0.9.15 (SM-era manager polish) and replaced the old per-domain Actions dropdown + inline edit panel; the ADD path was left on the pattern the edit path moved off. Not a defect - both forms work - but a UI that teaches one shape and then uses another for the closest neighbouring task."
---

# SM259 - add domain should use the Configure sheet

## Why

`starter/manager/domains.md` carries two ways to fill in a domain's settings:

- **`#cfg-sheet`** - the Configure sheet. Grouped sections, one domain, opens
  over the page, closes on backdrop click. This is the pattern 0.9.15 moved the
  edit path onto, and the operator's report is that it works well.
- **`#add-panel`** - a `display:none` block that `toggleAdd()` reveals inline
  above the table, with its own hand-rolled three-column flex layout and its own
  copies of the same fields (`f-host`, `f-croot`, `f-siteurl`, `f-sitename`,
  `f-appearance`, `f-lang`, `f-lang-group`).

They collect substantially the same information about the same object. Keeping
both means every future change to what a domain HAS lands twice, and a change
that lands once produces two forms that disagree - which is the same
one-thing-two-mechanisms shape SM255 spent a release removing from the conf
writers.

## The behaviour to keep

Add has three things Configure does not, and they are the reason it is not a
trivial swap:

- **`Copy settings from`** (`cloneFrom()`) - pre-fill from an existing domain.
  Genuinely useful when standing up a sibling site, and has no meaning when
  editing one that already exists.
- **`Seed a starter home page`** - only applies at creation.
- **Live derivation** - `onHostInput()` fills the site URL from the host until
  the operator edits it (`siteUrlEdited`). Configure has no equivalent because
  the values already exist.

So the target is one sheet with a create mode, not "delete the add panel and
reuse the edit one unchanged".

## Shipped 2026-08-09

One renderer, two modes. `domainSettingsHtml(row, isCreate)` builds both, so a new
domain key is added in ONE place and appears in both; `editField` and the token
pickers are shared, keyed on a `NEW_HOST` pseudo-host for the create sheet's ids.

The three create-only behaviours are intact - copy-settings-from, seed-a-home-page,
and the live site-URL derivation that stops once the operator types over it.
`cloneFrom` now fills the sheet rather than the retired panel, and deliberately
does NOT copy the access keys: who may manage a domain is a grant, not a
starting-point convenience.

The add form's per-field help was better than the sheet's and has been carried
in. Two hints read differently before the domain exists - a content folder is
CREATED rather than repointed, and the site URL derives from the host as you type
- so those live in a `CREATE_HINTS` overlay rather than one string compromised to
serve both modes.

`t/lint/29-domains-one-form.t` fails if `#add-panel`, `toggleAdd`, `addDomain` or
any of the old `f-*` field ids come back, and checks that each create-only
behaviour is still present - so this cannot quietly become a downgrade.

## What to do

Give the Configure sheet a create mode:

- Open it empty from `Add domain`, with the host field editable (it is fixed
  when configuring an existing domain) and the create-only controls present.
- Reuse the same section grouping, the same field ids and the same rendering
  code, so a new domain key is added in one place and appears in both modes.
- Keep the primary action's label honest per mode - `Register domain` when
  creating, whatever Configure uses when editing.
- Retire `#add-panel` and `toggleAdd()` once the sheet covers both.

Worth checking while in there: whether the add path's field help text is better
than Configure's in places. It is noticeably fuller (each field carries a
plain-language explanation), and that is worth carrying INTO the sheet rather
than losing.

## Tests

The manager pages are shipped Markdown with inline JS, so the practical checks
are the ones the repo already uses for them:

- The page contains ONE set of domain-field ids, not two.
- `t/lint` control-character and page-shape checks still pass.
- A manual pass: create a domain with a content folder + seed, create one that
  inherits everything, clone from an existing domain, then configure the result -
  confirming the two modes agree about what a domain has.

## Scope

`starter/manager/domains.md` only. No control-API or engine change: both forms
already call the same `domain-add` / `domain-set` actions underneath.

Related: SM217 (domain aliases first-class) will add another creation shape to
this page, so doing SM259 first means SM217 extends one form rather than two.
