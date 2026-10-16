---
id: SM1066
title: "SM1066: one lookup finds the processor for every preview"
subtitle: "MCP preview_page looked beside lazysite-mcp.pl; preview_public_page and preview_domain read LAZYSITE_PROCESSOR or the docroot's ../cgi-bin. On an install whose cgi-bin is elsewhere the second two shelled a processor that was not there."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: SM1065 ("Not changed - two ways to find the processor")
area: manager
status-note: "SHIPPED (0.15.5): Lazysite::Paths::find_processor is the one lookup (LAZYSITE_PROCESSOR's directory, beside the running CGI, the docroot's ../cgi-bin); processor_path and MCP _processor_tool both call it. Every packaged layout that found the processor finds the same file (t/unit/lib/90). Needs the whole suite (queued overnight)."
---

# The ruling

Release manager, 2026-10-12: **"Fix, own branch".**

# The problem (SM1065)

lazysite found the content processor two ways:

| Ref | Rule | Where | Callers |
|---|---|---|---|
| R-1 | `LAZYSITE_PROCESSOR`'s directory, else `$DOCROOT/../cgi-bin`; existence not checked | `Manager::Common::processor_path` | manager `preview`, `preview-public`, `domain-preview`; MCP `preview_public_page`, `preview_domain` |
| R-2 | beside `abs_path` of lazysite-mcp.pl, else `$DOCROOT/../cgi-bin`; the first that is a file | lazysite-mcp.pl `_processor_tool` | MCP `preview_page`, the draft preview |

The nginx examples (generic `/cgi-bin/` location) and the Hestia templates
(the auth-wrapper rewrite names only the processor and the manager API) hand
`LAZYSITE_PROCESSOR` to the processor and the manager API, never to
lazysite-mcp.pl. So on an install whose cgi-bin is not the docroot's
`../cgi-bin` - install.pl's own usage example is
`--docroot /var/www/html --cgibin /usr/lib/cgi-bin`, and the nginx and Apache
vhost tools take `--cgibin` - MCP `preview_page` rendered and MCP
`preview_public_page` and `preview_domain` shelled
`/var/www/html/../cgi-bin/lazysite-processor.pl`, which is not there.

Reproduced before the fix in t/integration/227 (that layout, MCP with no
`LAZYSITE_PROCESSOR`): `preview_page` and the manager's `preview-public`
(nginx-wired) rendered; `preview_public_page` answered `render-failed`, and
`preview_domain` `render-failed` naming the missing path.

# The fix

`Lazysite::Paths::find_processor( $docroot, $script )`, one function, the
first candidate that is a readable file:

1. the directory `LAZYSITE_PROCESSOR` names (only the directory: the auth
   wrapper sets it to the requested CGI, the manager API itself during a
   preview);
2. beside the running CGI - `$script`, else `$0` - through `abs_path`, as R-2
   resolved itself, so a symlinked cgi-bin entry gives the answer it gave;
3. `$DOCROOT/../cgi-bin`.

`processor_path` returns it, or when nothing qualifies the last candidate, so
the render fails naming the path it tried, as before. `_processor_tool` returns
it, or undef ("processor not available"), as before.

## Readable, not executable

The ruling said "exists and is executable". The repository, the dev server
(tools/lazysite-server.pl runs the CGIs from the checkout) and the suite carry
the CGIs at 0644 (git mode 100644); every caller runs the processor through
`$^X`. A `-x` test turns every working preview in those into "processor not
available" - sabotage S4 below fails 107 assertions of t/unit/lib/90. Installed
copies are 0755 (install.pl `mode_for`), so on an install the two tests agree.

# Nothing changes where a preview works today

t/unit/lib/90 builds each packaged layout and runs each shipped wiring over it,
reading both from what ships so a template change moves the matrix:

| Ref | Layout | Read from |
|---|---|---|
| L-1 | `<dom>/public_html` + `<dom>/cgi-bin` | tools/lazysite-hestia-domain.pl; the nginx and Apache vhost tools' default (`dirname($docroot) . '/cgi-bin'`); the deb's `lazysite provision` |
| L-2 | `/var/www/html` + `/usr/lib/cgi-bin` | install.pl's usage example |
| L-3 | `<repo>/starter` + the CGIs at `<repo>` | tools/lazysite-server.pl |

| Ref | Wiring | Who gets `LAZYSITE_PROCESSOR` |
|---|---|---|
| W-1 | nginx vhost-cgi, vhost-fcgi | the manager API (itself); MCP none |
| W-2 | Apache vhost-cgi, vhost-fcgi | every request: the processor |
| W-3 | Hestia lazysite-cgi, -fcgi, -app (.tpl) | the manager API (itself); MCP none |
| W-4 | one-rule front door (lazysite-processor/front-door.pm) | the wrapped scripts (itself); MCP none |
| W-5 | dev server | every CGI: itself |

For each layout, wiring and CGI (manager API, MCP), it asserts: a processor is
found; where R-1 found one, the new lookup finds the same file; for MCP, where
R-2 found one, the same file, and R-1 and R-2 agreed wherever both found one.
25 cases keep their file. 3 found nothing before - MCP on L-2 under W-1 (cgi
and fcgi) and W-4 - and the test holds that those are the only ones.

"The same file" is compared by `abs_path`. On L-1 under W-1, R-1 spelled it
`<dom>/public_html/../cgi-bin/lazysite-processor.pl` for MCP's
`preview_public_page`; the lookup now spells it `<dom>/cgi-bin/...` (beside the
CGI). One file; the processor finds its lib and parts through its own
`abs_path`.

Also held: the order (each candidate wins over the next), a symlinked
lazysite-mcp.pl resolves to its target's directory as R-2 did, and no
processor anywhere gives undef / the docroot path.

Outside the packaged layouts, one case changes a path that rendered: a
lazysite-mcp.pl that is a symlink into another tree, behind the Apache wiring
(`LAZYSITE_PROCESSOR` for every request). R-2 used the processor beside the
link's target; candidate 1 now takes the cgi-bin's. install.pl refuses to
write through a symlink, so no packaged install has one.

# Found while fixing

**MCP `preview_public_page` met SM976 Q15j only in the test rig.** It answered a
non-UTF-8 page as `page-encoding-refused` only after a `render-failed`, and
t/unit/mcp/31 reached that only because its docroot had no processor to find.
A processor that runs renders such a page as a 200 of mojibake (body byte) or a
500 (front-matter byte), and `preview_public_page` answered `ok`. With the
lookup unified, t/unit/mcp/31 found the processor and failed. The wrapper now
reads the page's own bytes whatever the render answered (the excerpt
`preview_public` returns is already decoded, so it cannot be judged the way
`preview_page` judges its HTML). On an install, a non-UTF-8 page now answers
`page-encoding-refused` to `preview_public_page` as Q15j ruled; a readable page
is unaffected.

# Not changed

- **`LAZYSITE_PROCESSOR` for lazysite-mcp.pl in the nginx examples and Hestia
  templates.** Not set. Candidate 2 finds the processor beside MCP on every
  layout, so the variable would add nothing; and in the nginx generic
  `/cgi-bin/` location it would also reach lazysite-auth.pl's passthrough (a
  bare request execs `LAZYSITE_PROCESSOR`) and every plugin endpoint. No
  template is touched, so lint 135's pinned revisions stand.
- **lazysite-auth.pl's exec fallback** (`$DOCROOT/../cgi-bin`), lazysite-front.pl
  (`LAZYSITE_CGIBIN`) and plugins/payment-demo.pl: they exec a CGI the web
  server named rather than find a processor for a preview. t/lint/258 says so.
- **The /usr/lib/cgi-bin example and the engine's lib.** The CGIs find lib at
  `$bin/lib`, `$bin/../lib`, `$bin/../../lib`; install.pl puts it at
  `{DOCROOT}/../lib` (/var/www/lib in that example). t/integration/227 puts the
  modules on `PERL5LIB`. Recorded, not examined further.

# Tests

- t/integration/227 (reproducing, failed before the fix): the L-2 install with
  copied CGIs (0755); MCP `preview_page`, `preview_public_page`,
  `preview_domain` with no `LAZYSITE_PROCESSOR`, and the manager's
  `preview-public` wired as nginx wires it, each render the page.
- t/unit/lib/90: the layout matrix above, the order, the symlink, nothing
  there, readable-is-enough.
- t/lint/258: `processor_path` and `_processor_tool` both call
  `find_processor`; no library or previewing CGI builds a path to
  lazysite-processor.pl outside Lazysite::Paths.
- t/unit/mcp/31: unchanged; passes against a found processor.

Sabotage (tmp/n558-sabotage.sh, backups in tmp/sab-bak/n558/, restored by cp,
cmp clean): S1 `processor_path` back to R-1 fails 227, 90 and 258; S2 no
"beside" candidate fails 227 and 90; S3 beside before `LAZYSITE_PROCESSOR`
fails 90; S4 `-x` for `-r` fails 90 (227 installs 0755 and passes, as an install
would); S5 MCP back to its own lookup fails 258; S6 the Q15j check only after a
`render-failed` fails t/unit/mcp/31.

# Related

[[SM1065]], [[SM1064]], [[SM976]], [[SM238]], [[SM441]].
