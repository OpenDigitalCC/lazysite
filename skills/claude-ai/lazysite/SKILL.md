---
name: lazysite
description: Check lazysite page content by actually running it - install the bundled engine, validate the source, and render it against the site's own layout and theme - before answering an editor about a page, component, layout or theme. Use when the work involves lazysite content and being right matters more than being quick.
---

# Check it before you answer

You have the lazysite engine in this conversation. Run the page rather than
reasoning about it.

This is **additional to the MCP connector, and independent of it**. MCP writes
to the site; this decides whether what is about to be written will work. Either
works without the other.

## Workflow

1. **`bash setup.sh`** - installs the bundled engine and creates a local site.
   Prints the version it installed and one PASS/FAIL line. Run it once per
   conversation; a second run is a no-op.

2. **Validate the source.** Fastest check, no server needed:

   ```
   lazysite validate --docroot "$LAZYSITE_SITE" /path/to/page.md
   ```

   Exit 1 means an ISSUE - the page is wrong. Warnings alone exit 0 and are
   judgement calls. `reference/validating.md` says what each kind means.

3. **Pull the editor's own layout and theme** when their connector is attached,
   so what you render is what they will get. `reference/site-context.md` is the
   exact set of calls - and says what it CANNOT reach.

4. **Render it.** `bash serve.sh start`, then fetch the page and read the HTML:

   ```
   perl fetch.pl http://127.0.0.1:8080/the-page
   ```

5. **Say what you checked.** Every answer that used this ends with one line:

   - `Checked: validated, and rendered against <site>'s own layout and theme.`
   - `Checked: validated, and rendered against the STARTER theme - this site's
     own theme was not available, so theme-specific rendering is unverified.`
   - `Not checked: <why>.`

   The honesty line is not decoration. An editor told "validated" who then
   finds the theme wrong stops believing the next one.

## What this can and cannot tell you

| Can | Cannot |
| --- | --- |
| Front matter, Markdown, component fences, Template Toolkit parse errors, form field rules | How it LOOKS - there is no browser and no screenshots here |
| Whether a page renders against a given layout and theme, and what HTML comes out | Whether the live site is in the state you think - ask MCP |
| Whether a `db:` binding or a named form would deliver, given a site | Anything about the editor's live data - none of it is here |

## Pointers

- `reference/site-context.md` - pulling the site's layout, theme and nav
- `reference/validating.md` - the checks, the message kinds, the exit codes
- `README.md` - how an editor installs and updates this skill
