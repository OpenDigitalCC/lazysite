# Code quality

## Language and runtime

- **Perl 5.10 or later.** The codebase uses `//` (defined-or), `say`,
  and closure state.
- **Functional style throughout.** No object-oriented Perl. No
  `bless`, no Moose. Each sub takes arguments and returns values.
- **`use strict; use warnings;`** in every script.
- **No shared modules** between scripts. Each script in the repo is
  self-contained and runs standalone.

The self-contained-script policy is deliberate:

- **Deployment simplicity.** Each script can be dropped into
  `cgi-bin/` and works. No `@INC` path configuration, no
  `lib/` directory to install.
- **Independence.** A script can be copied out of the repo and used
  on its own. This matters for operators who want to swap a handler
  or run just the form handler.
- **Trade-off.** Some code is duplicated - `log_event`, constant-time
  comparison helpers, CSPRNG helpers, CSRF HMAC helpers. The
  duplication is kept in sync by convention and audited in the
  quality pass.

## Script inventory

```
lazysite-processor.pl       Core page processor and renderer
lazysite-auth.pl            Cookie authentication wrapper
plugins/form-handler.pl    Form submission dispatcher
plugins/form-smtp.pl       SMTP delivery handler
lazysite-manager-api.pl     Manager web UI API
lazysite-dav.pl             WebDAV (class 1+2) publishing endpoint
plugins/payment-demo.pl    x402 payment demo handler
plugins/log.pl             Plugin descriptor for logging
tools/lazysite-server.pl    Development HTTP server
plugins/audit.pl     Link audit tool
tools/lazysite-users.pl     User management CLI / JSON API
```

`lazysite-dav.pl` (SM070) follows the self-contained policy and so
duplicates, by convention: `log_event` / `_json_str`, `const_eq`,
`verify_password`, a CSPRNG helper, a settings reader, the
blocked-path check, the `.md`→`.html` cache invalidation, and the
lock-record read/write. The lock-record format is shared with
`lazysite-manager-api.pl` (both read JSON lock files and the legacy
single-line form); that is a deliberate cross-script data contract,
not accidental duplication.

## Perl::Critic policy

Enforced by `t/lint/02-perlcritic.t` against the project profile
`.perlcriticrc` at **severity 4** (the serious set), so the gate passes with
zero violations; tightening to severity 3 is future work. The profile disables
the policies below for documented reasons (deliberate project conventions); a
genuine one-off (the dev-server module probe) carries an inline
`## no critic` so the policy stays active for production code. Intentional
deviations:

| Policy | Deviation | Reason |
|---|---|---|
| `RegularExpressions::RequireExtendedFormatting` (~485 hits) | `/x` not used on simple one-line patterns | `/x` adds clutter to short patterns with no clarity win. Used where patterns are genuinely multi-line (the `convert_fenced_*` family). |
| `InputOutput::RequireEncodingWithUTF8Layer` (~90 hits) | `:utf8` used instead of `:encoding(UTF-8)` | `:utf8` is the looser mode. The strict variant would raise a decoding error on latin1 content, turning a legacy file into a 500 rather than rendering it with replacement chars. Looser mode chosen so operator-supplied content does not need to be re-encoded on upgrade. |
| `InputOutput::ProhibitInteractiveTest` in `tools/lazysite-server.pl` | `-t STDOUT` for TTY detection | Single line, single check. Adding `IO::Interactive` as a dependency for one call would be over-engineering. |
| `Subroutines::RequireFinalReturn` (~119 hits) | Subs end on their last expression | Self-contained CGIs use the last-expression return throughout; the 119 sites agree on this shape. |
| `Subroutines::ProhibitExplicitReturnUndef` (~53 hits) | `return undef`, not bare `return` | **Decision:** keep `return undef`. It is the project idiom for "no value" as a *scalar*; none of these returns is consumed in list context (where `return undef` and `return` differ), so the list-context footgun the policy guards against does not apply. Rewriting 53 sites would be churn with no behavioural gain. |
| `TestingAndDebugging::ProhibitNoWarnings` (2 hits) | Narrow `no warnings 'category'` | Used deliberately - `'once'` around a `DB_File` tie and `'uninitialized'` around a log join. A *bare* `no warnings` would still want review. |
| `BuiltinFunctions::ProhibitStringyEval` in `tools/lazysite-server.pl` | `eval "require $mod"` for module probing | Inline `## no critic` (policy stays active elsewhere). `$mod` is from a hard-coded list; no injection surface; dev server only. |

The profile passes at severity 4 with zero violations; the one real cleanup
from the 2026 review (a comma-operator statement in `lazysite-auth.pl`) was
fixed rather than excluded.

## Naming conventions

Terminology is settled:

| Use | Not |
|---|---|
| `view.tt` | `layout.tt` |
| `lazysite.conf` | `layout.vars`, `config.yml` |
| `lazysite/themes/` | `templates/`, `skins/` |
| `/manager` | `/admin`, `/editor` |
| `lazysite-manager-api.pl` | `lazysite-editor-api.pl` |
| `lazysite_auth` (cookie name) | `lazysite_session` |
| manager pages under `starter/manager/*.md` | embedded HTML per feature |

Button labels in the manager UI follow a fixed vocabulary:

- `Save` for persisting form or config changes.
- `Add` for creating new items.
- `Update` for saving edits to an existing item.
- `Delete` for removing items (never `Remove`).

## Code conventions

**Logging.** All scripts emit events via an identically-shaped
`log_event(level, context, message, %extra)` function with a
`$LOG_COMPONENT` constant scoped to the script. Level is gated by
`$ENV{LAZYSITE_LOG_LEVEL}` (default `INFO`). Output format is `text`
by default; setting `$ENV{LAZYSITE_LOG_FORMAT}` (or `log_format:` in
`lazysite.conf`) to `json` emits newline-delimited JSON. Both vars
can come from `lazysite.conf` via `log_level:` and `log_format:`.

**Error handling.** Functions return `undef` or an empty list on
failure. Callers check return values. User-facing CGI responses are
HTTP status codes with sanitised error messages; internal detail goes
to the log, not the response body.

**File I/O.** Text files open with `:utf8`. Binary files (secrets,
random bytes, theme zip payloads, POST bodies) open without an
encoding layer. Cache writes use `tempfile + rename` for atomicity.
File permissions use the `0o` octal prefix.

**Path safety.** Every path derived from request input passes through
`Cwd::realpath()` and is verified to start with `$DOCROOT` before any
file operation. Applied consistently at:

- `lazysite-processor.pl` - `process_md`, `process_url`,
  `_resolve_include`, `resolve_scan`, `write_html`.
- `lazysite-manager-api.pl` - every file-reading and file-writing
  action (`action_list`, `action_read`, `action_save`, `action_delete`,
  theme operations).

**Plugin protocol.** Any CGI script may advertise capabilities by
responding to `--describe` with a JSON descriptor containing an `id`,
`name`, `description`, `config_schema`, `config_keys`, and optional
`actions`. The manager's Plugins page (and the implicit Configuration
page) uses this for auto-discovery and configuration UI generation.
Scripts without `--describe` are ignored.

## Non-core dependencies

| Module | Purpose | Alternatives considered |
|---|---|---|
| `Template` (TT) | Layout rendering | None reasonable. TT is the de facto standard for this shape. |
| `LWP::UserAgent` | Remote URL fetching for `.url` pages, `:::include`, remote themes | Could use `IO::Socket::SSL` directly, but LWP handles redirects, compressed responses, and TLS certificate verification correctly out of the box. Deferred to `require` so its cost is paid only on paths that touch it. |
| `Text::MultiMarkdown` | Markdown to HTML conversion | `Text::Markdown` lacks fenced divs, tables, and ID-on-heading extensions. `CommonMark` (XS) is not universally available on shared hosts. |
| `Archive::Zip` | Safe theme zip extraction with per-entry path validation | `system("unzip", ...)` lacks per-entry validation and relies on the host unzip's behaviour. Archive::Zip lets the code inspect each member before any bytes hit disk. |
| `DB_File` | Form submission and login rate limiting | Core on Debian; provides a persistent key-value store without running a database daemon. Backed by Berkeley DB. |
| `JSON::PP` | JSON encode/decode | Core. The XS variant (`JSON::XS`) would be faster; `JSON::PP` is chosen to keep the dependency list minimal. |

Core modules used without comment: `Digest::SHA`, `File::Path`,
`File::Basename`, `File::Find`, `File::Temp`, `Fcntl`, `POSIX`, `Cwd`,
`Encode`, `IO::Socket::INET`, `IPC::Open2`.

## Known complexity

- `main()` in `lazysite-processor.pl` has a high cyclomatic complexity
  score (Perl::Critic flags ~69). It is a single large dispatch
  function that handles: URI sanitisation, query-param parsing,
  trust-gating of `HTTP_X_REMOTE_*` headers, manager-path enforcement,
  auth and payment peek+check, cache lookup, `.md` and `.url`
  rendering branches, and 404 / 403 fallbacks. The test suite
  exercises every branch; the complexity is a refactor candidate for
  a future cycle, not a correctness problem.
- The main dispatch block of `lazysite-manager-api.pl` has the same
  shape (an `if/elsif` chain per action). Same note applies.
- Both are flagged in the quality audit as "notable", not "defective".
