# Rendering against the editor's own site

The local site starts as a copy of the starter. That validates a page's
*structure*, and it does not tell you how the page will look on the site the
editor actually has. To answer that, pull their layout and theme into the local
tree before rendering.

This needs their MCP connector attached. Without one, say so in the answer -
the starter fallback is honest, a silent substitution is not.

## What to pull, and where to put it

Let `$SITE` be the local site (`/root/lazysite-local/site` by default).

| Ref | Call | Write it to |
| --- | --- | --- |
| C1 | `list_themes` | nothing - it tells you `active_layout` and the active theme name, which every later call needs |
| C2 | `list_files` on `lazysite/layouts/<active_layout>` (and each directory it returns) | - |
| C3 | `read_file` on every file C2 found | `$SITE/lazysite/layouts/<active_layout>/<same relative path>` |
| C4 | `read_nav` | `$SITE/lazysite/nav.conf` - see the format note below |
| C5 | `theme_tokens` | only if you need the token VALUES; the theme.json pulled by C3 already carries them |

The layout directory is the whole of it: `layout.tt`, `layout.json`,
`components/*.tt` (the layout `INCLUDE`s these - a layout without them renders
nothing), and `themes/<theme>/` - `theme.json` and the theme's `assets/`
(`main.css`, `fonts.css` and the like, which `serve.sh start` publishes).

## The nav.conf format

`read_nav` answers a structured list (`items`, each with `label`, `url` and
`children`); the engine reads a text file. Write one line per item - the
item's `label | url`, or the bare label when `url` is empty - and each child
under it indented by two spaces. That is the file `set_nav` writes on the
site:

```
# lazysite navigation
Home | /
About | /about
Docs | /docs
  Install | /docs/install
  Configure | /docs/configure
Resources
  Blog | /blog
```

What the engine's parser (`parse_nav` in `lazysite-processor/sources.pm`)
accepts:

- **`Label | /url`**, split at the FIRST `|`; spaces around either part are
  trimmed. A line with no `|` is an item with an empty url - a section heading,
  like `Resources` above.
- **A line that starts with whitespace is a child** of the nearest top-level
  line above it. Any amount of whitespace counts, and there is ONE level only:
  a line indented further is still a child of that top-level item, never a
  grandchild.
- An indented line with no top-level line above it becomes a top-level item.
- **`#` as the first non-blank character makes a comment.** A `#` later in the
  line is part of the label or url. Blank lines are skipped.
- A line with no label (`| /x`) is dropped.
- The file is read as UTF-8.

Write it to `$SITE/lazysite/nav.conf` even when `read_nav` reports another
`nav_file`: the reconstructed conf below sets no `nav_file`, so the engine
reads `lazysite/nav.conf`.

## What you CANNOT pull, and what to do instead

**`lazysite/lazysite.conf` is refused.** It is inside the reserved `lazysite/`
tree, and layouts, themes, nav and form submissions are carve-outs from that
refusal - the site config is not one. Measured, not assumed; the refusal says
so in as many words.

So the local config is RECONSTRUCTED, and only from things a partner may read:

```
site_name: <from describe_capabilities, or the editor>
layout: <active_layout from C1>
theme: <active theme from C1>
```

Write that to `$SITE/lazysite/lazysite.conf`, keeping any keys already there
that you have no better value for.

What this means for the answer: **anything driven by a config key you could not
read is unverified.** Language sets, plugin enablement, `site_url`, custom page
variables - a page that depends on one of those may render differently on the
real site. If the page you are checking uses one, say which.

## Then render

```
bash serve.sh start
perl fetch.pl http://127.0.0.1:8080/the-page
```

`serve.sh start` first runs `perl mirror.pl`, which publishes the theme assets
to `$SITE/lazysite-assets/<layout>/<theme>/` - run `start` again after every
pull, even with the server already up. On a real site that directory is written
when a theme is activated; nothing activates one here, so without it every
stylesheet link 404s and the page is unstyled. `mirror.pl` calls the engine's
own mirror step, so the result matches the site's: `assets/` copied,
`theme-tokens.css` written beside them (the page then links it, as the live
site does, where an unmirrored tree carried the tokens as an inline `<style>`),
and the `.fingerprint` that `[% theme_version %]` reads. Each theme it mirrors
prints one line; `NOT mirrored` gives the engine's reason - usually a theme
whose CSS sits beside `theme.json` rather than in `assets/`, which the live
site renders unstyled too.

`/.well-known/lazysite-instance.json` answers here too, and is the cheapest way
to see the server is up. **Its `version` is empty in this container** and that
is correct rather than broken: it reports what an INSTALLER wrote into the
site, and nothing provisioned this one. The version that matters here is the
engine's, which `setup.sh` prints.

Read the HTML. The things worth checking, in the order they usually go wrong:

1. the page's own content is in the output at all (a component fence that never
   closed leaves `::: name` as literal text);
2. the layout's chrome is around it (nav, footer) - if not, the layout did not
   load and you are looking at a fallback;
3. the theme's stylesheet link points where you expect -
   `/lazysite-assets/<layout>/<theme>/...` - and that URL answers 200 here
   (`perl fetch.pl http://127.0.0.1:8080/lazysite-assets/<layout>/<theme>/main.css`);
   a 404 means the mirror did not run or reported `NOT mirrored`;
4. any `[% ... %]` left in the output - a variable the page used and the layout
   does not supply renders as nothing, or as itself.

## If the render is wrong

Check the server log before concluding the page is at fault:
`/root/lazysite-local/server.log`. The engine logs a WARN for an unbalanced
fence, a component that failed to render, and a form block with no `form:` key -
each of which shows up on the page as something subtler than an error.
