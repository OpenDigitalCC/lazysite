---
id: SM887
title: "SM887: a local lazysite so claude.ai can check an answer before giving it"
subtitle: "A skill that installs the current release into the claude.ai container, runs the dev server, renders the editor's content against the live site's own theme, and only then answers. Additional to MCP and not required by it: MCP writes to the site, this decides whether what is about to be written is right."
brand: plain
standard-margins: true
status: partial
status-note: "REAL SESSION 2026-10-12 (release manager): A5 and E2 CONFIRMED - edge rendered as edge locally, nothing written; only archive.ubuntu.com needed. E5 partly: the server survived across tool calls; past the conversation unobservable. E7 NOT confirmed: a Claude Code cloud container, skill mounts writable. Closes on one run in the plain claude.ai chat sandbox (E2, E7). The release manager decides."
---

# What it is for

An editor working in claude.ai asks for a page, a component, a theme edit. The
model has the documentation in context but nothing to run, so it answers from
reading. The answers are *nearly* right, and the editor finds the fault by
deploying to the live site.

This gives that instance a working lazysite: install the current release, start
the dev server, pull the editor's own layout, theme, nav and config down through
their MCP connector, render the proposed content against them, and only then
answer — with a line saying what was and was not checked.

**It is additional to MCP, not a replacement and not a dependency.** MCP is how
content reaches the site. This is how the editor finds out, before that, whether
it will work. Either works without the other.

# The install source: the skill carries the engine

The briefing asks the skill to resolve the newest release asset from
`api.github.com`. That cannot work: this project has **no published GitHub
repository**. No remote grants push, and every tag to date is local and
unpushed. A skill written to that instruction fails on its first call in a way
that looks like a network problem.

**My first answer to that was also wrong, and worth recording because it is the
tempting one.** I proposed fetching from lazysite.io, on the grounds that
`*.lazysite.io` appears in the allowlist the briefing recorded. It does — *in
the container that briefing was written in*. An allowlist is per editor, and
nothing entitles us to assume another editor's carries a host this project
happens to own. A skill that works for the person who specified it and fails
for everyone else is worse than one that never worked, because the failure
arrives as a support question rather than a test result.

So the engine must arrive **without any host this project controls being
reachable at all**.

It can, and the briefing already contains the mechanism without noticing it:
*"a zip of the folder attached to each release, so editors always have a version
that matches the deb."*

**Put the debs in the zip.**

| | |
| --- | --- |
| Fetched from a host we control | nothing |
| Network the install needs | `archive.ubuntu.com` only, for Perl dependencies — present on every container's allowlist because the base image itself needs it |
| Version match | by construction; the zip **is** the release |
| Size | `common` + `nginx` ≈ 2.4 MB |
| Install | `apt-get install ./lazysite-common_*.deb ./lazysite-nginx_*.deb`, which the briefing confirms resolves Debian dependencies |

This is better than any fetch, not merely a workaround for a missing one: there
is no version-resolution step to get wrong, no digest to verify, no allowlist to
depend on, and no failure mode where the editor's container reaches a *different*
release than the skill was written for.

**It also removes [[SM884]] as a prerequisite.** Nothing downloads the tarball,
so the 60-second budget is an `apt-get` against the Ubuntu archive rather than a
34 MB transfer. SM884 remains worth doing; it is no longer load-bearing here.

## The one thing this costs

The editor re-uploads the skill to pick up a new release. The briefing already
accepts that shape — the zip is attached per release and uploaded to the account
— so this makes an existing property load-bearing rather than adding a new
burden. `SKILL.md` should print the bundled version on every run, so an editor
on an old skill can see it.

## If a published repository ever exists

Then `api.github.com` becomes available as the briefing originally intended, and
the skill could resolve the newest release instead of using its bundled one.
That is a **decision about publishing this project**, not a packaging detail,
and it is the operator's. Recorded here so the option is not rediscovered as a
blocker: the bundled zip does not depend on it either way.

# The environment, as verified

Stated in the briefing from the container on 2026-09-15, and these are
constraints rather than preferences:

| Ref | Fact | What it forces |
| --- | --- | --- |
| E1 | Ubuntu 24.04, Perl 5.38.2, runs as root, `apt-get install ./file.deb` works | Debian dependencies only — CPAN is unreachable, which the deb already satisfies |
| E2 | Network allowlist, **which is per editor**. The briefing's container listed github.com and friends, Ubuntu archives, PyPI/npm/crates — and `*.lazysite.io`, which was particular to that editor and must not be assumed anywhere else | Fetch nothing from a host this project owns. `archive.ubuntu.com` is the only one safe to rely on, because the base image needs it |
| E3 | No inbound network | The dev server is reachable only from inside the container; the editor cannot open it, so every result must be text |
| E4 | The filesystem resets between conversations | Install from scratch every time, under 60 seconds, in one or two tool calls |
| E5 | Background processes live only for the conversation | The dev server is started per conversation and discarded |
| E6 | No display, no browser, no screenshots | Validation is exit codes, rendered HTML and log lines |
| E7 | Skills are mounted **read-only** at `/mnt/skills/user/<name>/` | Scripts run in place or copy themselves somewhere writable; they cannot write beside themselves |

E7 and the dev server interact: the dev server **writes its state into the
docroot**, so the local site tree must be created somewhere writable and never
under the mounted skill.

# Deliverables

| Ref | Deliverable |
| --- | --- |
| D1 | `skills/claude-ai/lazysite/` in this repo: `SKILL.md`, `setup.sh`, a dev-server start script, the reference files, and a `README.md` telling an editor how to upload it |
| D2 | A zip of that folder attached to each release, **carrying that release's `common` and front-end debs** — the skill is the distribution channel, which is what makes it work on any editor's allowlist |
| D3 | A short note in the lazysite.io docs pointing editors to it |

`SKILL.md` stays short — trigger, workflow, pointers. Detail belongs in the
supporting files, because the trigger description is read for *every* task and
the body only when it matches.

# The two modes

**Site-faithful.** The editor's connector is attached, so the skill pulls the
active layout, theme, nav and `lazysite.conf` into the local tree before
rendering. This is the mode that makes the answer trustworthy, and the exact
file set is an open decision below.

**Starter.** No connector: fall back to the bundled starter site, and say so in
the answer — page-level validation still holds (front matter, Markdown,
includes, TT variables), theme-specific rendering is unverified.

The honesty line is not decoration. An editor who is told "validated" and then
finds the theme wrong stops believing the next one.

# Open decisions

Mine, and I will take them when building:

| Ref | Decision |
| --- | --- |
| Q1 | Dev server invocation, port and health endpoint |
| Q2 | Exactly which files constitute "site context" for the site-faithful mode |
| Q3 | Whether the starter site is an adequate fallback or a smaller dedicated validation site is better |
| Q4 | Which validation entry points exist today, and what each one's output actually says |

**Q5 is deliberately NOT folded in.** The briefing asks whether a processor
`--validate` mode — structured messages, non-zero exit — would make the skill
markedly simpler, and says to raise it separately rather than absorb it. It
would, and it is filed as its own item rather than smuggled into a skill's
scripts, because a validation contract the engine owns is worth more than a
skill that greps for error text and breaks when the wording changes.

**RULED 2026-09-15: build it as an ENGINE CAPABILITY, not as a dependency of
this skill.** Validation becomes something the engine offers to anything that
asks — this skill, CI, a pre-commit hook, the manager, MCP — and the skill is
one consumer rather than the reason it exists. It lands before F1, and F1 is
built against it.

The narrower option (shape it around what the skill needs) was refused for the
reason worth keeping: a second consumer would want it reshaped, and reshaping
something already shipped is a breaking change to a contract.

## F2 BUILT 2026-09-15, and it answers Q4 on the way

The survey Q4 asked for found one real content validator in the tree, and it
was **inside `lazysite-mcp.pl`** - eight checks reachable only by an
authenticated MCP partner posting to a live site over HTTP. Nothing else could
ask: not the manager editor, not the control API, not CI, not a pre-commit
hook, not a person with a file. And **nothing anywhere exited non-zero because
a page was bad** - every surface answered `ok:1` and exit 0 - so A4 could not
have been satisfied by anything that existed.

| | |
| --- | --- |
| `lib/Lazysite/Validate.pm` | the checks, MOVED out of the MCP script rather than copied. Verified sub by sub against the originals: the only differences are the two docroot parameters and the third states below. |
| `tools/lazysite-validate.pl`, `lazysite validate` | the shell's way of asking. **Exit 1 on an issue** - which is A4, and is what lets `lazysite validate page.md && publish` be written at all. Exit 2 for bad usage, so a typo does not read as a content failure. `--json` for a caller that parses, `--strict` when warnings should count. |
| MCP `validate_page` | now a CONSUMER. Its return shape is unchanged - `issues`, `warnings`, `valid` - because partners parse it; each message gained `severity` and `file`, which is additive. |

**Warnings do not fail it, and that is a decision rather than an omission.** A
warning is a judgement the author may have made on purpose; a gate that fails
on those is a gate people learn to bypass, which costs more than it saves.

**The two checks that need a site now say so.** `db:` bindings need the table
descriptors, and a named form needs its binding conf. Called without a docroot
they report `db-binding-unchecked` / `form-binding-unchecked` rather than
nothing - because a check that skips silently is a check that always passes,
and the skill's whole first call is against a file with no site behind it yet.

Q1-Q3 remain F1's to answer, and F1 is now built against this rather than
around it.

# Acceptance, and the dependency it carries

The briefing is right that this must be tested on a fresh instance rather than a
familiar box — a familiar box hides exactly the assumptions this will trip on.

| Ref | Check |
| --- | --- |
| A1 | Clean Ubuntu 24.04 container, outbound restricted to the allowlist |
| A2 | `setup.sh` cold: completes under 60 seconds, prints the installed version and one pass/fail line |
| A3 | Dev server starts, renders a starter page |
| A4 | A deliberately broken page exits non-zero |
| A5 | A layout and theme copied from a real site render as that site's |
| A6 | `setup.sh` run a second time in the same container is a no-op |

## RUN 2026-09-15, in a real cold `ubuntu:24.04` container

The .deb was built from the branch (`debian/changelog` is bumped at cut time,
so it identifies itself as 0.10.8 — the payload is this tree), copied into a
read-only mount at `/mnt/skills/user/lazysite`, and the container was root, as
E1 says.

| Ref | Result |
| --- | --- |
| A1 | Ubuntu 24.04.4, root, skill mount read-only |
| A2 | **8 seconds cold**, against a 60-second budget; prints the version and one PASS line |
| A3 | Homepage 200, 4,631 bytes of HTML; the instance endpoint answers |
| A4 | **exit 1** on a page whose front matter never closes — the criterion nothing in the tree could meet before F2 |
| A5 | **claude.ai's.** A real site's layout can be pulled — proven against a live site's `layout.tt` over MCP — but whether it RENDERS as that site's needs the editor's own connector and their own site |
| A6 | Second run: 1 second, "engine already installed", "reusing the local site" |

**TWO THINGS THE RUN FOUND THAT NO AMOUNT OF READING WOULD HAVE.**

**`ubuntu:24.04` has no `curl`.** Every probe in the first draft reached for it,
so the render check failed and reported that the dev server had not started —
in a container the editor cannot inspect, about a tool rather than their page.
The skill now carries `fetch.pl`, forty lines of core Perl over
`IO::Socket::INET`. Perl is the one interpreter guaranteed to be there, because
the engine depends on it.

**The dev server refused to start over a module nothing loads.** Its preflight
demanded `LWP::UserAgent`; `lazysite-common` lists libwww-perl under
*Recommends*, so an install carrying everything the engine *depends* on still
would not come up — and the message told the operator to install a package they
did not need. The processor requires LWP lazily, inside `fetch_url` /
`fetch_oembed`, for remote includes only, and the dev server never mentions it
again. Removed, with `t/unit/tools/04` asserting the rule rather than the one
module: a preflight that demands more than the code uses turns an optional
feature into an install blocker.

A third, smaller: **a zip does not reliably carry the execute bit**, and the
mount is read-only so `chmod` is not available as a repair. `sh serve.sh`,
never `./serve.sh` — the first cold run failed with "Permission denied", which
reads as a sandbox problem rather than a file mode.

**SETTLED 2026-09-15, and in two layers rather than one.**

I raised the container as a blocking dependency and hedged about whether docker
was usable here. It is: pulling `ubuntu:24.04` and running a throwaway container
works, entirely at container level, and the daemon is never restarted — within
the standing rule. The image is **Ubuntu 24.04.4 with Perl 5.38.2**, which is
the environment E1 describes.

**But the container is not the acceptance test, and should not pretend to be.**
The release manager will run the skill **in a real claude.ai conversation** —
the intended environment — and report what breaks. That is the same offer the
briefing's author made, and it is worth more than any local approximation,
because three of the constraints in E1-E7 cannot be reproduced in a container at
all:

| Ref | What only the real environment has |
| --- | --- |
| E2 | The actual per-editor network allowlist, rather than a local guess at it |
| E5 | The conversation lifecycle — processes living only as long as the conversation |
| E7 | The read-only `/mnt/skills/user/<name>/` mount |

So: **docker for my own loop** — does `setup.sh` run cold, does it finish in
time, is it idempotent, does a broken page exit non-zero — and **claude.ai for
acceptance**. A1-A6 below are split accordingly when the work is done, and any
criterion the container cannot reach is marked as claude.ai's rather than
quietly ticked.

# Real-session test, 2026-10-12

**The release manager's measurement**, run in a real session with the skill and
reported to the developer agent. Recorded as reported; the grades are theirs.
The developer did not observe the session.

| Ref | Result, as reported |
| --- | --- |
| Install | `setup.sh` installed lazysite-common 0.15.4-1 from the bundled .deb in 14 s, copied the starter and started the dev server. Edge reports engine 0.15.4, matching |
| A5 | **CONFIRMED.** Pulled edge's `layout.tt`, `layout.json`, six components, `themes/lumen/theme.json`, `main.css`, `fonts.css` and `read_nav` over MCP; reconstructed `lazysite.conf` (`site_name`, `layout`, `theme`); validated and rendered a proposed `/contact.md` edit: 0 issues, HTTP 200, and HTML unmistakably edge's - `lumen-nav`, the title, the theme tokens inline, stylesheet links to `/lazysite-assets/lumen/lumen/{fonts,main}.css`, a native form with five fields, no leaked `:::` or `[% %]`. Nothing was written to edge |
| E2 | **CONFIRMED.** Only `archive.ubuntu.com` was needed, and it was reachable; lazysite.io was refused from the shell (curl 000). The bundled-.deb design is right |
| E5 | **PARTLY.** The dev server started fresh, survived across tool calls, and `serve.sh stop`/`start` restarted it cleanly. Its lifetime beyond the conversation cannot be observed from inside one |
| E7 | **NOT CONFIRMED in this container.** The skill loaded from `/mnt/skills/plugins/lazysite/`; `/mnt/skills/user/lazysite/` is a symlink into `/root/.claude/skills/synced/...`; both were writable (`touch` succeeded). Only `/mnt/skills/public` and `/mnt/skills/examples` are squashfs read-only. Nothing in the scripts depends on it |

**The caveat the release manager attached:** this was a Claude Code cloud
container - curl present, an HTTPS proxy, writable skill mounts - not the plain
claude.ai chat sandbox. E2 and E7 are one environment's answer. Config keys
other than `site_name`, `layout` and `theme` are unverified, because
`lazysite.conf` is not readable over MCP.

## The three notes, and what was done (branch n490)

| Ref | Note | Done |
| --- | --- | --- |
| N1 | `/lazysite-assets/<layout>/<theme>/main.css` 404s locally: the step that writes it on a real site (activation, layout install, package apply) never ran | **Fixed, by running the engine's own step.** The skill carries `mirror.pl`, which loads the installed `Lazysite::Manager::Themes` and calls `_mirror_layout_themes` - the function activation calls - so the local mirror carries the assets, `theme-tokens.css` and the `.fingerprint`. `serve.sh start` runs it whenever the conf names a layout, ahead of its already-running exit. One consequence: the tokens are now LINKED locally, as they are on a real mirrored site, where the session saw them inline (the processor's fallback for a missing mirror). t/tools/130 |
| N2 | `site-context.md` points at a nav.conf format note that does not exist | The note is written from `parse_nav` (`lazysite-processor/sources.pm`): `Label \| /url` split at the first `\|`, a bare label as a heading, indented lines as children of the nearest top-level item and one level only, `#` comments only as the first non-blank character, label-less lines dropped, UTF-8; and write `lazysite/nav.conf` whatever `nav_file` `read_nav` names. t/tools/131 holds the note to the parser |
| N3 | `setup.sh` says the folder IS MOUNTED READ-ONLY, which is wrong for at least one container | It now says the folder MAY be read-only (the chat sandbox, as briefed) or writable (the cloud container, as measured), and that the scripts work either way because none writes beside itself. t/tools/83 holds that property instead of the mount |

**The unread config, documented rather than built.** `site-context.md` now says
which other conf keys reach a rendered page (`site_url`, `lang`, `nav_file`, the
alias and `content_root` keys, `extensions`/`plugins`, `meta_generator`, the
scan and feed sizes, and every other key as a template variable) and how to
learn what the reconstruction left out: compare with the live render from
`preview_page`, read the layout for `[% %]` variables, or ask the editor. It
also corrects its own earlier line that `site_name` comes from
`describe_capabilities`: neither that nor `whoami` reports any conf value. No
MCP conf reader is proposed.

**What would close this.** One run of the skill in the plain claude.ai chat
sandbox, answering E2 (that sandbox's allowlist reaches `archive.ubuntu.com`)
and E7 (whether its skill mount is read-only - which no longer matters to the
scripts, but is the briefing's claim). Closure is the release manager's call.

# The same check over MCP: SM1030

**RULED 2026-10-12 by the release manager: "yes queue the preview_page draft
change"** - the coordinating session's proposal: MCP `preview_page` accepts
DRAFT content (a `content` argument, as validate_page does) and renders it
server-side against the site's real layout and theme WITHOUT writing anything,
so an MCP-connected editor can check a page before saving it (the SM887 skill's
job, with nothing to install).

Built as [[SM1030]]. It is the site-faithful mode without the install: the
render runs on the site itself, so the layout, theme, navigation and access
rules are the site's by construction rather than pulled down and copied. It
needs the editor's connector and a grant that reaches the path; the skill
remains for an editor without one, and for checking against a site that is not
the one being written to. The two are additional to each other in the way this
filing describes MCP and the skill: either works without the other.

# Related

[[SM1030]] (the same render over MCP, on the site itself),
[[SM884]] (the tarball size this install budget depends on), [[SM286]] (the
front end makes no decisions — the same separation this keeps between validating
and publishing), the dev server reference, and the MCP briefings the skill's
reference files must not contradict.
