---
id: SM1078
title: "SM1078: every CGI finds the engine's lib wherever the cgi-bin is"
subtitle: "install.pl puts the Lazysite:: modules at {DOCROOT}/../lib; the CGIs looked only beside themselves. On install.pl's own usage example (/var/www/html with /usr/lib/cgi-bin) every CGI but the linked form handler died \"Can't locate Lazysite/Util.pm\"."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-13
raised-by: SM1066 ("Not changed - the /usr/lib/cgi-bin example and the engine's lib"), probed by n575
area: installers
status-note: "SHIPPED (0.15.5): every script a cgi-bin runs, and the processor's _lazy_lib, find lib by one rule - beside the script's real directory, its parent, its grandparent, then the docroot's ../lib (DOCUMENT_ROOT, else REDIRECT_DOCUMENT_ROOT). Every layout that worked resolves to the same directory (t/unit/lib/97)."
---

# The problem

SM1066 recorded it and left it: the CGIs find the `Lazysite::` tree at
`$bin/lib`, `$bin/../lib` and `$bin/../../lib` (lazysite-data.pl and
lazysite-odoo.pl only the first two), where `$bin` is the real directory of the
script. install.pl puts the tree at `{DOCROOT}/../lib`
(dist/config/classification.json) and the CGIs at `{CGIBIN}`. The two agree only
when the cgi-bin's parent or grandparent is the docroot's parent.

install.pl's own usage example is `--docroot /var/www/html --cgibin
/usr/lib/cgi-bin`. The modules land at `/var/www/lib`; the CGIs look in
`/usr/lib/cgi-bin/lib`, `/usr/lib/lib` and `/usr/lib`. t/integration/227 met it
and supplied the modules through `PERL5LIB`.

# How every layout was probed

Each layout was laid out by the shipped installer into a temporary prefix.
install.pl takes absolute `--docroot` and `--cgibin`, so the prefix is the path
(`<P>/var/www/html`, `<P>/usr/lib/cgi-bin`); `lazysite provision` (the deb's
CLI, run from the tree as `perl tools/lazysite-cli.pl provision --installdir`)
does the same through install.pl. Nothing was installed outside the prefix; the
registry write to /etc/lazysite/sites.d was refused and reported, as on any host
where it is not writable.

Each CGI then ran once, as its installed 0755 file, with `PERL5LIB` empty and
the environment its web-server example gives it:

| Ref | Wiring | What the CGI is handed |
|---|---|---|
| W-n | nginx vhost-cgi (fcgiwrap) | the processor and the manager API through lazysite-auth.pl with `LAZYSITE_PROCESSOR` naming them; the rest bare |
| W-a | Apache vhost-cgi, Hestia lazysite-cgi.tpl | as nginx, and `LAZYSITE_PROCESSOR` = the processor on every request |
| W-f | one-rule front door | lazysite-front.pl with `LAZYSITE_CGIBIN`; it execs the target |
| W-d | dev server, `lazysite demo`, deb pool | the CGIs run from the payload root, `LAZYSITE_PROCESSOR` = the target |

A probe module loaded through `PERL5OPT` recorded, at each script's exit, the
directory it loaded `Lazysite::` from, whether the processor's lazy lookup
(`_lazy_lib`) loads a module, the processor `Lazysite::Paths::find_processor`
finds, and whether `lazysite.conf` is where `Lazysite::Paths` looks. Scripts in
tmp/n575/ (probe-layouts.pl, LzsProbe.pm, compare.sh); not shipped.

## The layouts

| Ref | Layout | docroot + cgi-bin | Produced by |
|---|---|---|---|
| L-1 | provision | `<dom>/public_html` + `<dom>/cgi-bin` | `lazysite provision` (deb), `--installdir`, lazysite-hestia-domain.pl, the vhost tools' default `--cgibin` |
| L-2 | install.pl example | `/var/www/html` + `/usr/lib/cgi-bin` | install.pl usage; any `--cgibin` away from the docroot's parent |
| L-3 | payload | the site's docroot + the CGIs at the payload root | tools/lazysite-server.pl, `lazysite demo`, the deb pool (tools/lazysite-pool.pl execs the payload's processor) |
| L-4 | cgi-bin inside the docroot | `<docroot>` + `<docroot>/cgi-bin` | doc only (docs/OPERATOR.md "Layout on disk") |

## Before

Each cell is every CGI in that wiring; "ok" means the modules loaded from
`{DOCROOT}/../lib` (or the payload's lib on L-3), `lazysite.conf` was found and,
for the manager API and MCP, the processor was the cgi-bin's.

| Layout | processor | manager API | auth | MCP | DAV | data | form handler | OAuth | Odoo |
|---|---|---|---|---|---|---|---|---|---|
| L-1, W-n W-a W-f | ok | ok | ok | ok | ok | ok | ok | ok | ok |
| L-2, W-n W-a | `Can't locate Lazysite/Util.pm` (in the auth wrapper) | `Can't locate Lazysite/Util.pm` | `Can't locate Lazysite/Util.pm` | `Can't locate Lazysite/Util.pm` | `Can't locate Lazysite/Util.pm` | `Can't locate Lazysite/Manager/Plugins.pm` | ok (the cgi-bin entry is a link into `{DOCROOT}/../plugins`) | `Can't locate Lazysite/Util.pm` | `Can't locate Lazysite/Manager/Plugins.pm` |
| L-2, W-f | `Can't locate Lazysite/FrontDoor.pm` (lazysite-front.pl itself) | same | same | same | same | same | same | same | same |
| L-3, W-d | ok | ok | ok | ok | ok | ok | ok | ok | ok |
| L-4, W-n W-a W-f | ok | ok | ok | ok | ok | `Can't locate Lazysite/Manager/Plugins.pm` | ok | ok | `Can't locate Lazysite/Manager/Plugins.pm` |

On L-2 the processor run directly (no wrapper, as the pool or a hand-run CGI
runs it) rendered `/`, because its render path loads no module (ADR 0001); its
lazy lookup failed, so the features that load one - the chrome strings of its
403 and built-in 404, `db:` page variables (zero rows, logged), remote
`fetch` - did not work (t/integration/259 asserts it). install.pl's health
check, run at the end of the install, reported only ownership on both L-1 and
L-2: it does not ask whether the CGIs load.

## After

Every cell of every layout is ok: 90 of 90 runs. The 59 runs that were ok
before are byte-identical rows after (same status, same lib directory, prefix
normalised - tmp/n575/compare.sh); 31 were fixed (27 on L-2, 4 on L-4).

# The fix

One rule in every script a cgi-bin runs - the nine `lazysite-*.pl` CGIs, the
plugins install.pl links or copies into the cgi-bin (form-handler,
payment-demo), and the processor's `_lazy_lib`:

```perl
my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
my $doc = $ENV{DOCUMENT_ROOT} || $ENV{REDIRECT_DOCUMENT_ROOT} || '';
for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib", ( length $doc ? "$doc/../lib" : () ) ) {
    if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
}
```

The docroot's `../lib` is LAST, so a script that found a lib before finds the
same one: the candidates before it are unchanged, and a new candidate is reached
only where all of them failed. lazysite-data.pl and lazysite-odoo.pl gain
`$bin/../../lib` for the same reason (it is reached only where their two
candidates failed - L-4). The rule cannot live in a module (it is what finds the
modules), so it is one text carried by each script and held to that text by
t/lint/263; t/unit/lib/97 evaluates each script's own copy.

`$DOCUMENT_ROOT/../lib` is the same fallback the CGIs already use for the site's
tools and plugins (`$DOCROOT/../tools/lazysite-users.pl`,
`$DOCROOT/../plugins/stats.pl`, `Lazysite::Handlers`). DOCUMENT_ROOT is set by
the web server, never by the client.

The processor's copy is in a sub, so it reads `$DOCROOT`, the processor's own
file-scope capture of the same two variables (`our $DOCROOT =
$ENV{DOCUMENT_ROOT} || $ENV{REDIRECT_DOCUMENT_ROOT}`), not `%ENV`: under the
pool, FCGI replaces `%ENV` with each request's parameters, and the pool's own
DOCUMENT_ROOT is gone by then (t/lint/43, which the first draft of this fix
failed). t/lint/263 holds that line too.

# Nothing changes where a CGI worked

t/unit/lib/97 builds each packaged layout - read from classification.json,
install.pl, lazysite-hestia-domain.pl, the vhost tools and lazysite-cli.pl - and
evaluates each script's rule there, against the rule before SM1078 kept verbatim
in the test:

- every case that found a lib before finds the same directory (abs_path);
- the cases that found nothing before are exactly every CGI on L-2 (and, with
  the plugins copied rather than linked, those too) and lazysite-data.pl and
  lazysite-odoo.pl on L-4;
- every CGI in a layout uses one lib;
- with no docroot in the environment (the tools, the CLI) the rule is the old
  rule;
- a lib beside the script wins over the docroot's: `lazysite demo` provisions a
  site with its own lib and runs the payload's CGIs, which keep the payload's.

One layout outside the packaged ones could now resolve where it did not: a host
with the `Lazysite::` tree on the system `@INC` and none beside the CGIs, whose
docroot also has a `../lib`. Nothing packages the tree onto the system `@INC`
(the deb ships it at /usr/share/lazysite/lib), so no install has it.

# Documentation

The documentation describes these layouts beyond the ones above:

| Ref | Where | Layout | Disposition |
|---|---|---|---|
| D-1 | starter/docs/install.md "Manual Apache installation" | `/var/www/example.com/{public_html,cgi-bin}`, copying only lazysite-processor.pl by hand: no lib, plugins, tools, manager, auth, MCP, DAV or forms | Replaced by `lazysite provision` plus `lazysite-apache-vhost add` / `lazysite-nginx-vhost add`, and a paragraph saying where provision puts each part; a hand-copied processor is stated as unsupported |
| D-2 | docs/OPERATOR.md "Layout on disk" | the cgi-bin inside the docroot (L-4) | No tool produces it. The block now shows the cgi-bin as provision's `--cgibin` and the lib, plugins and tools beside the docroot. L-4 itself works (above) |
| D-3 | README.md "Docker: see installers/docker/" | a Docker image | installers/docker/ holds only `.gitkeep`. The line now says there is no Docker image yet |
| D-4 | docs/architecture/code-quality.md "`use lib` is wired by the installer" | none (inaccurate) | Now states the rule |
| D-5 | starter/docs/development.md, nocache.md, conf-path-override.md | relative `perl cgi-bin/lazysite-processor.pl` from the site directory | The provision layout (L-1) run by hand; unchanged |
| D-6 | starter/docs/features/configuration/conf-path-override.md | `DOCUMENT_ROOT=/var/www/html` with a relative `cgi-bin/` | Works on either layout now; unchanged |

# Not changed

- **t/integration/227's `PERL5LIB`.** Its rig copies the CGIs into a cgi-bin
  away from a docroot that has no `../lib` (the modules are the repository's), so
  it still needs it. t/integration/259 is the install.pl install without it.
- **The health check.** It does not ask whether the CGIs load their modules; it
  passed L-2 on ownership alone. Recorded, not changed here.
- **tools/*.pl.** They run from `{DOCROOT}/../tools` or the payload's `tools/`,
  where `$bin/../lib` always holds; no web server runs them.

# Tests

- t/integration/259 (reproducing; failed before the fix): install.pl provisions
  L-2 and L-1 into a temporary prefix; each CGI runs once with `PERL5LIB` empty,
  nginx-wired; the modules load from `{DOCROOT}/../lib`, the processor's lazy
  lookup finds one, lazysite.conf is found, the manager API and MCP find the
  cgi-bin's processor.
- t/unit/lib/97 (failed before the fix): the layout matrix above.
- t/lint/263 (failed before the fix): every script a cgi-bin runs, and
  `_lazy_lib`, carry the rule's two lines.

Sabotage (tmp/n575-sabotage.sh, backups in tmp/sab-bak/n575/, restored by cp,
cmp clean): S1 no docroot candidate in lazysite-auth.pl fails 263, 97, 259; S2
the docroot first in lazysite-mcp.pl fails 263, 97; S3 `_lazy_lib` back to the
old rule fails 263, 97, 259; S4 lazysite-data.pl without `$bin/../../lib` fails
263; S5 lazysite-dav.pl without `REDIRECT_DOCUMENT_ROOT` fails 263; S6
lazysite-dav.pl back to the old rule fails 263, 97, 259; S7 `_lazy_lib` reading
`%ENV` in the sub fails 263 and t/lint/43.

# Related

[[SM1066]], [[SM1065]], [[SM079]], [[SM944]].
