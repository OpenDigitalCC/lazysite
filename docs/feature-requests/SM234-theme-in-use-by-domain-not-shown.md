---
title: "SM234 - A theme in use by a sub-domain looks deletable until you press Delete"
subtitle: "The Appearance list marks only the site-wide active theme. A theme pinned by a registered domain gets a Delete button, and the operator learns it is protected only from the error that follows."
brand: plain
status: shipped
status-note: "IMPLEMENTED in the 0.10.2 edge line (2026-08-08, commit 0b47a07). Reported by the operator 2026-08-07 for the next release. The SM177 delete protection is correct and unchanged - the gap is that the same knowledge is absent from the list, so the UI offers an action it will then refuse. The identical gap exists for layouts, and the helper that answers it is already in the codebase."
---

# SM234 - theme usage by a sub-domain is invisible until refusal

## Why

`action_theme_delete` protects a theme that a registered domain depends on. It
resolves effective per-host values, so an alias inheriting the active layout but
pinning its own theme is caught, and it names the domains in the refusal:

> Theme 'X' is in use by a.example, b.example. Repoint or remove those domains
> first.

That protection is right. The problem is that it is the **first** the operator
hears of it. The Appearance panel offers a Delete button on that theme, they
press it, and only then discover the theme is load-bearing for a domain they may
not have had in mind.

An interface that offers an action it will refuse teaches operators to click
things to find out what they do. The information exists, is already computed by
the same module, and is simply absent from the list.

## What is true today

**Listing knows only the site-wide active pair.** `action_theme_list` and
`action_themes_list_all` in `lib/Lazysite/Manager/Themes.pm` derive `active` from
`_read_active_layout_and_theme`, which reads the `layout:` and `theme:` keys from
`lazysite.conf`. Per-domain overrides are never consulted.

**Deleting knows about domains.** `action_theme_delete` calls
`Lazysite::Manager::Domains::domains_using( theme => ..., layout => ... )`, which
walks the base config plus every registered host's overrides and returns the
hosts that resolve to that theme.

**The UI renders from the first and is corrected by the second.** In
`starter/manager/appearance.md`, `isActiveT` is `isActiveL && t === ACTIVE_THEME`.
When that is false the row gets a Delete button; when true it shows an `active`
badge and "active - cannot delete". There is no third state for "some domain
depends on this".

**Layouts have the identical gap.** `isActiveL` is likewise a comparison against
the single site-wide layout, and a layout used only by a sub-domain gets a Delete
button too. `domains_using` already answers a layout-only query - the branch
exists - so the fix is the same shape and should be done in the same pass.

## What to change

### Carry usage in the list responses

`action_theme_list` and `action_themes_list_all` should return, per theme, the
domains that resolve to it - and the same for layouts in the layout listing.

Build the usage map **once**. `domains_using` calls `_parse()` on every
invocation, so calling it per theme re-reads and re-parses the domain
configuration for each row. A single pass that inverts the mapping - host to
effective layout and theme, then grouped by theme - gives every row its answer
for one parse.

### Distinguish two states rather than overloading one

"Active" currently means the site-wide default. A theme a sub-domain pins is not
active in that sense and is equally undeletable. Two signals, not one stretched
over both:

```
default18   [active]                       active - cannot delete
clientbrand [in use: a.example, b.example]  in use by 2 domains - cannot delete
sandbox                                     [Delete]
```

Name the domains where there are few and count them where there are many, with
the full list available on hover or expansion. The operator's next question after
"why can I not delete this" is always "which domain", so answer it in the same
breath.

### Suppress the action rather than refusing it

Where a theme or layout is in use, show the reason in place of the Delete button,
matching how the active theme already behaves. The server-side guard stays
exactly as it is - it is the authority, and the UI must not become the thing that
enforces it.

## Verification

- A theme used only by a registered sub-domain shows an in-use marker naming that
  domain, and offers no Delete button.
- The same holds for a layout used only by a sub-domain.
- An alias host that inherits the active layout but pins its own theme marks that
  theme in use, matching what the delete guard already catches.
- A theme used by nothing still offers Delete and still deletes.
- The domain configuration is parsed once per listing, not once per theme.
- `action_theme_delete`'s behaviour and its tests are untouched.

## Not in scope

- Any change to the delete protection itself. SM177's guard is correct.
- Any change to how per-domain overrides resolve.
- Offering a "repoint these domains and then delete" action. Naming the blockers
  is the ask; doing the repointing is a larger and more dangerous feature that
  should be requested separately if it is wanted.
