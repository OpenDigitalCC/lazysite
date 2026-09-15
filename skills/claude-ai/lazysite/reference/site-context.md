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
nothing), and `themes/<theme>/theme.json`.

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
bash serve.sh start          # or restart, if it was already running
perl fetch.pl http://127.0.0.1:8080/the-page
```

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
3. the theme's stylesheet link points where you expect;
4. any `[% ... %]` left in the output - a variable the page used and the layout
   does not supply renders as nothing, or as itself.

## If the render is wrong

Check the server log before concluding the page is at fault:
`/root/lazysite-local/server.log`. The engine logs a WARN for an unbalanced
fence, a component that failed to render, and a form block with no `form:` key -
each of which shows up on the page as something subtler than an error.
