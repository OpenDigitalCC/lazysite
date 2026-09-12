---
id: SM853
title: "SM853: the post-TT link pass rewrote Markdown syntax anywhere in the page, including inside a script, and killed the Handlers page"
subtitle: "`convert_p_links` is documented as converting links inside `<p>`, and its pattern ran over the whole rendered document. `BUILD[listId](key)` in the Handlers page's only script became an anchor, the 26KB script stopped parsing, and every panel on the release's headline page sat at Loading with every button inert - with nothing in any log and 13,893 tests green."
brand: plain
standard-margins: true
status: shipped
raised: 2026-09-12
raised-by: site agent (1313E-10, from the browser)
area: render
---

# What was found

The site agent ran the 0.13.13 edge pass and reported `/manager/handlers` as
inert: the Handlers, Forms and Schedule panels all at `Loading...` at a
12-second capture, every button dead. It was measured rather than inferred, and
the measurements ruled out the obvious causes before reaching the real one:

- a synchronous XHR to `?action=handler-list` **from that page** answered 200
  with the real data, so the session may read it;
- the page requested only `csrf-token` and `version` - it never called
  `handler-list` at all;
- `typeof load` and `typeof newHandler` were both `"undefined"`, though the
  buttons carry `onclick="load()"`;
- CSP on the page is report-only, so nothing was blocked.

Compiling the page's second inline script in the browser gave the cause:

```text
new Function(script2.textContent)
  -> SyntaxError: Unexpected identifier 'href'
```

At offset 6083: `body.innerHTML = BUILD<a href="key">listId</a>;`

# The cause

`starter/manager/handlers.md:234` reads, correctly:

```js
body.innerHTML = BUILD[listId](key);
```

`[listId](key)` is Markdown link syntax. `convert_p_links` in the processor runs
**after** TT rendering, over the whole page:

```perl
$html =~ s{\[([^\]]+)\]\(([^)]+)\)}{<a href="$2">$1</a>}g;
```

Its comment says "inside `<p>` tags"; its pattern says every byte of the
document. `convert_md` protects `<script>` and `<style>` from the Markdown pass
(SM689 added comments for the same reason), so the script survived Markdown and
was eaten afterwards by a pass nobody had asked this question of.

Because the anchor breaks the parse of the whole script, **nothing** in it is
defined - which is why a 26KB script with 40 functions produced a page that
renders its chrome and does nothing.

# How far it reached

Driven against the shipped processor, not read:

| Where `x[i](y)` sat | What the pass did |
| --- | --- |
| paragraph text | converted (its job) |
| inside `<script>` | REWRITTEN |
| inside `<style>` | REWRITTEN |
| inside inline `<code>` | REWRITTEN |
| inside a fenced `<pre><code>` block | REWRITTEN |
| inside an attribute value | REWRITTEN |

So any documentation page showing `fns[name](arg)` in a code sample has been
serving a bogus anchor, and any page with that shape in its script has been
broken the same way the Handlers page was.

# The fix

The pass converts TEXT. Script, style, pre and code spans are lifted out first,
then every remaining tag - which is what keeps attribute values out of reach -
the substitution runs on what is left, and both go back. The narrow case the
pass exists for (a Markdown link whose URL held a TT variable, which
MultiMarkdown strips before TT runs) is unchanged and asserted.

# How it is held

- `t/unit/processor/79-a-link-pass-does-not-reach-into-code.t` - the pass still
  converts a link in paragraph and list text, and leaves a script, a style,
  inline code, a fenced block, an attribute and an alt text exactly as they
  were; then the same thing through the processor, because the unit answer in
  `convert_md` was already "protected" while the page still arrived broken.
- `t/lint/136-every-manager-page-script-parses.t` - **renders every manager page
  and runs `node --check` on each inline script.** The source was correct, so a
  lint reading the source would have passed while the served page was broken:
  this one verifies what renders. It names the one page it cannot reach
  (`config`, whose script is inside `[% IF manager_caps.manage_config %]`) and
  counts what it checked, so it cannot quietly check nothing. Skipped where node
  is absent.

Both fail against the shipped processor; the lint names the Handlers script and
the line it dies on.

# What this says about the gate

The release passed 13,893 tests, a benchmark and a coverage floor, and shipped
its headline page dead. Every test asked the engine a question in Perl; none
asked a browser whether the page worked. The new lint is the cheapest possible
version of that question, and it belongs to the class SM444 and SM764 are in:
a gate that measures something other than what the user receives.

# Related

[[SM842]] (the Handlers page this broke), [[SM689]] (comments protected from the
Markdown pass for the same reason), [[SM833]] (the other defect found only by
looking at what reached the page).
