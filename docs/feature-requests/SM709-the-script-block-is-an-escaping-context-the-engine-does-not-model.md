---
id: SM709
title: The script block is an escaping context the engine does not model
raised: 2026-09-01
raised-by: engine (found while sizing SM708's "protect <script>" option)
area: security
status: shipped
status-note: "SHIPPED. auth_user/auth_name/auth_email/auth_groups are escaped where they enter the TT render stash - beside the identical treatment SEC-2026-07 gives page_title - and NOT at the auth boundary, which is the obvious place and would compare an escaped value against an unescaped users file (SM702's shape: fails closed as a lockout, invisible to any fixture user with nothing to escape). A LIVE UNESCAPED SINK was found doing it: _inject_admin_bar concatenated the display name straight into HTML with no template and so no filter to be wrong, on every non-manager page for a manager-level viewer - self-XSS only, since the name is the viewer's own, and NOT reached by the stash escaping because the bar reads %AUTH_CONTEXT directly. It is escaped at the sink. The two shipped pages that interpolated into <script> read from a data- attribute now, which also fixes a search for it's searching for it&amp;#39;s. docs/auth.md carries the idiom and says | html on these values is wrong. t/integration/77 proves both halves and was sabotage-verified against each; its fixture user is o'brien so a future leak into the decision path fails the suite rather than the fleet. NOT DONE, deliberately: a | js filter (option 2) - a filter an author must remember is the mechanism that already failed. SM708 stays open and separate."
---

# The short version

Page bodies are TT-processed, `<script>` blocks included. Two families of
variable reach that stash with **different safety properties and nothing saying
so**, and the only filter authors are pointed at is the wrong one for the
context. This is not a live hole today; it is a footgun that an ordinary surname
sets off and that self-registration would turn into an injection.

# The two families

`query.*` is escaped **at parse time**, in `parse_query_string`
(`lazysite-processor.pl:1938-1942`), with five entities - `& < > " '`. The
single quote is included. A query value is therefore safe interpolated into
either quote style.

`auth_user`, `auth_name` and `auth_groups` are read straight from the
`X-Remote-*` environment (`lazysite-processor.pl:509-512`) and reach the stash
**unescaped**. `apply_trust_gate` stops a client setting those headers directly,
so the provenance is the users file or a trusted proxy - but no escaping happens
anywhere on the path.

Both families sit in the same stash, are documented in the same list
(`starter/docs/reference.md`, `starter/docs/auth.md`), and look identical to an
author.

# The filter is wrong for the context

Inside `<script>`, HTML entities are not decoded by the JS parser. So `| html`:

- does **not** escape `'`, which is the delimiter in the idiom both shipped
  pages use; and
- does escape `"` to `&quot;`, which inside a JS string is six literal
  characters rather than a quote - so it corrupts the value it protects.

Measured against the real `Template` module, one template, three display names:

| Value | Rendered into `'...'` | Result |
| --- | --- | --- |
| `O'Brien` | `var me = 'O'Brien';` | JS syntax error; the whole block dies |
| `Ada "A" Lovelace` | `'Ada &quot;A&quot; Lovelace'` | Entities rendered literally |
| `x'); alert(1); ('` | `var me = 'x'); alert(1); ('';` | Executes |

**TT ships no filter that is correct here.** `html`, `html_entity` and `uri` are
the candidates and none of them is a JS string escaper.

`display_name` permits quotes, and must: `cmd_user_settings_set`
(`tools/lazysite-users.pl:1715-1718`) strips `\r\n\t`, trims and caps at 64
characters, and an apostrophe in a surname is not something to refuse. So row 1
is reachable today by an honest operator called O'Brien.

# Why the CSP does not backstop it

`_inline_script_hashes` hashes the **rendered** body, so anything injected into
an inline script is hashed along with it and permitted. Hash-based CSP stops an
attacker ADDING a script element; it does nothing about injection INTO one it
has just hashed. Worth stating because the SM380 work might otherwise be read as
covering this.

# What is actually exposed today

Nothing demonstrated. Reaching row 3 needs an attacker-controlled display name,
and display names are operator-set. **SM673 changes that** - a visitor asking
for an account, with a display name they propose, moves this from footgun to
vector. That filing should not land before this one is answered.

The two shipped pages that interpolate into `<script>`
(`starter/manager/edit.md`, `starter/search-results.md`) use `query.*` only, so
both are safe from breakout - but both also write `| html` over a value that was
already escaped at parse time, so a search for `it's` searches for
`it&amp;#39;s`. That double-escaping is a separate small correctness bug and is
visible to any user with an apostrophe in their query.

# Options

1. **Escape `auth_*` at the stash, like `query.*` already is.** Makes the two
   families consistent and closes rows 1 and 3. Costs: a page interpolating
   `auth_name` into ordinary HTML content would double-escape unless the
   existing `| html` uses are revisited, exactly as the query family already
   does.
2. **A JS-context filter** (`| js`) plus documentation that `| html` is wrong
   inside `<script>`. Correct, and puts the burden on authors getting the filter
   right - which is the thing that failed here.
3. **The `data-` attribute idiom**: put the value in an attribute and read it
   from JS, so HTML escaping - the escaping the engine actually does - is the
   correct escaping. No new mechanism, and it is what the two shipped pages
   should arguably do anyway.

Related: SM708 (a literal `[%` in script blanks the page) is the same boundary
seen from the authoring side. Protecting `<script>` from TT wholesale would
answer both, and is refused separately there: the layout catalogue has zero
interpolations inside `<script>`, but the starter tree has two, and one of them
is the manager's own editor, which would stop knowing which file it is editing.

# Decided (release manager, 2026-09-01)

**Escape at the stash, AND document the `data-` attribute idiom.** Both, not
either. The stash escaping removes the failure mode where a page is wrong by
omission - the `query.*` precedent, which has held. The idiom is what makes
script context actually correct rather than merely non-fatal, because escaping
alone converts `O'Brien` from a syntax error into the corrupted literal
`O&#39;Brien`. The two shipped pages are fixed to match.

Accepted cost: a page that correctly writes `| html` on `auth_name` will
double-escape, exactly the wart `query.*` already carries. A display bug, not a
security one. An idempotent `| html` filter was considered and rejected - it
would fix both families at once, but every page's `| html` would then behave
non-standardly for the next reader.

**Scope: all four `auth_*` uniformly.** `auth_user` and `auth_groups` are
already constrained at creation (`[a-zA-Z0-9_.-]` and `[A-Za-z0-9_-]`), so it is
a no-op for them, and one rule is cheaper to hold than a per-variable exception
table. It also covers the case the creation-time constraint never sees: a
trusted proxy supplying these headers directly.

**SM673 is gated on this.** A visitor proposing their own display name is what
makes `auth_name` attacker-controlled. The dependency is invisible from SM673's
side and must not be left to a future reviewer to rediscover.

# THE IMPLEMENTATION CONSTRAINT, and it is the whole risk here

**`auth_*` is not `query.*`.** A query value is only ever rendered. `auth_user`
and `auth_groups` are ALSO the inputs to access control:

| Site | What it decides |
| --- | --- |
| `lazysite-processor.pl:1018-1019` | the ACL identity and its groups |
| `:1226-1231` | `_is_manager` - whether the manager UI opens |
| `:2007` | the manager request gate |
| `:6389` | the editor flag in the render context |

So the escaping **must be applied where the TT render vars are assembled**
(beside `query => $query`), and **not** where the auth result is constructed
(`:509-512`, `:520-523`, `:551-554`). Escaping at the auth boundary would make
an ACL comparison test an escaped value against an unescaped users file.

That failure is SM702's shape exactly - it fails CLOSED, so it presents as a
lockout rather than a leak, and every test whose fixture user has no character
needing escaping would pass. **The regression test therefore needs a user whose
name or group contains a character the escaper touches**, proving authorization
still resolves for them while the rendered value is escaped.
