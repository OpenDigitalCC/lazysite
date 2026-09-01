---
id: SM709
title: The script block is an escaping context the engine does not model
raised: 2026-09-01
raised-by: engine (found while sizing SM708's "protect <script>" option)
area: security
status: candidate
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
