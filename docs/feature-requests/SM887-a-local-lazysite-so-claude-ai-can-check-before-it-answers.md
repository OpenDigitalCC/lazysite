---
id: SM887
title: "SM887: a local lazysite so claude.ai can check an answer before giving it"
subtitle: "A skill that installs the current release into the claude.ai container, runs the dev server, renders the editor's content against the live site's own theme, and only then answers. Additional to MCP and not required by it: MCP writes to the site, this decides whether what is about to be written is right."
brand: plain
standard-margins: true
status: candidate
status-note: "PROPOSED 2026-09-15, briefed by the sites agent (inbox/briefing-claude-ai-lazysite-skill.md) with one container's constraints verified in it the same day; scoped to 0.14.3 by the release manager. THE INSTALL SOURCE IS THE WHOLE PROBLEM AND THE ANSWER IS TO NOT HAVE ONE. The briefing specifies fetching the release from GitHub, which this project has no published repo for. My first answer was to fetch from lazysite.io instead, because it was on the allowlist the briefing recorded - CORRECTED 2026-09-15 by the release manager: that allowlist was THAT editor's container, and no other editor's can be assumed to carry it. So the engine must arrive without any host this project controls being reachable. IT CAN: the briefing already asks for a zip of the skill folder attached to every release, so the zip CARRIES THE DEBS. Nothing is fetched, the version matches the release by construction, and the only network the install needs is archive.ubuntu.com for Perl dependencies - which is on every container's allowlist because the base image needs it. common + nginx is about 2.4 MB. This also removes SM884 as a prerequisite and most of the 60-second budget with it. OPEN DECISIONS are listed below and are mine to make, except the container for acceptance, which needs the operator."
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

**DEPENDENCY, and it is the operator's:** A1 needs a container. I cannot install
OS packages on this host, and docker use here is bounded by the standing rule
that the daemon is not to be restarted. Whether this runs under docker, and on
which host, is the operator's call and should be settled before the work starts
rather than discovered at acceptance.

# Related

[[SM884]] (the tarball size this install budget depends on), [[SM286]] (the
front end makes no decisions — the same separation this keeps between validating
and publishing), the dev server reference, and the MCP briefings the skill's
reference files must not contradict.
