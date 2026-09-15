---
id: SM887
title: "SM887: a local lazysite so claude.ai can check an answer before giving it"
subtitle: "A skill that installs the current release into the claude.ai container, runs the dev server, renders the editor's content against the live site's own theme, and only then answers. Additional to MCP and not required by it: MCP writes to the site, this decides whether what is about to be written is right."
brand: plain
standard-margins: true
status: partial
status-note: "BUILT 2026-09-15 AND AWAITING THE ONLY TEST THAT COUNTS. F2 (validation as an engine capability) and F1 (the skill itself) are both built; D3, the lazysite.io docs pointer, is filed to the sites agent. The cold run happened in a real ubuntu:24.04 container: A2 8 seconds against a 60-second budget, A3 renders, A4 exits 1, A6 is a 1-second no-op - recorded below with the two things the run found that reading would not have (the base image has no curl, and the dev server refused to start over a module nothing loads). A5 and the E2/E5/E7 constraints are CLAUDE.AI'S, not a container's, and the release manager offered to run it there - so this stays PARTIAL until they report, rather than being called done on the half that can be automated. PROPOSED 2026-09-15, briefed by the sites agent (inbox/briefing-claude-ai-lazysite-skill.md) with one container's constraints verified in it the same day; scoped to 0.14.3 by the release manager. THE INSTALL SOURCE IS THE WHOLE PROBLEM AND THE ANSWER IS TO NOT HAVE ONE. The briefing specifies fetching the release from GitHub, which this project has no published repo for. My first answer was to fetch from lazysite.io instead, because it was on the allowlist the briefing recorded - CORRECTED 2026-09-15 by the release manager: that allowlist was THAT editor's container, and no other editor's can be assumed to carry it. So the engine must arrive without any host this project controls being reachable. IT CAN: the briefing already asks for a zip of the skill folder attached to every release, so the zip CARRIES THE DEBS. Nothing is fetched, the version matches the release by construction, and the only network the install needs is archive.ubuntu.com for Perl dependencies - which is on every container's allowlist because the base image needs it. common + nginx is about 2.4 MB. This also removes SM884 as a prerequisite and most of the 60-second budget with it. OPEN DECISIONS are listed below and are mine to make, except the container for acceptance, which needs the operator."
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

# Related

[[SM884]] (the tarball size this install budget depends on), [[SM286]] (the
front end makes no decisions — the same separation this keeps between validating
and publishing), the dev server reference, and the MCP briefings the skill's
reference files must not contradict.
