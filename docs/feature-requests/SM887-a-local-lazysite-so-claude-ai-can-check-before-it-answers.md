---
id: SM887
title: "SM887: a local lazysite so claude.ai can check an answer before giving it"
subtitle: "A skill that installs the current release into the claude.ai container, runs the dev server, renders the editor's content against the live site's own theme, and only then answers. Additional to MCP and not required by it: MCP writes to the site, this decides whether what is about to be written is right."
brand: plain
standard-margins: true
status: candidate
status-note: "PROPOSED 2026-09-15, briefed by the sites agent (inbox/briefing-claude-ai-lazysite-skill.md) with the container's constraints verified in it the same day; scoped to 0.14.3 by the release manager. THE BRIEFING'S INSTALL SOURCE DOES NOT EXIST AND DOES NOT NEED TO: it specifies fetching the newest release deb from GitHub releases, and this project has no published GitHub repo - no remote grants push, and every tag to date is local and unpushed. It also does not need one: `*.lazysite.io` is already on the container's network allowlist, and download/ already holds exactly the current stable set with its .sha256, kept there by t/lint/113. So the skill installs from lazysite.io and the distribution channel is one that exists today. SM884 matters to this more than it looks: it takes the tarball from 34.2 MB to 6.5 MB, and the briefing's acceptance bar is a cold install under 60 seconds. OPEN DECISIONS are listed below and are mine to make, except the two that need the operator."
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

# The install source, which the briefing got wrong for a good reason

The briefing asks the skill to resolve the newest release asset from
`api.github.com`. That cannot work: this project has **no published GitHub
repository**. No remote grants push, and every tag to date is local and
unpushed. A skill written to that instruction would fail on its first call in a
way that looks like a network problem.

It also does not need to work, because a channel already exists:

- `*.lazysite.io` is on the container's allowlist, verified in the briefing;
- `download/` holds **exactly** the current stable release and its `.sha256`,
  and [[SM884]]'s sibling lint `t/lint/113` is what keeps it that way — one
  release, complete, named by the newest stable GATE-LOG row;
- the digest is already there to verify the download, which a skill installing
  into a fresh container should do rather than trust the transfer.

So the skill fetches from lazysite.io, and the rule that keeps `download/`
correct is the same rule that makes it a usable install source.

**[[SM884]] is a prerequisite in practice.** The acceptance bar is a cold
install under 60 seconds; the fix takes the tarball from 34,185,929 bytes to
6,481,528. It lands at 0.14.3, which is this item's release.

# The environment, as verified

Stated in the briefing from the container on 2026-09-15, and these are
constraints rather than preferences:

| Ref | Fact | What it forces |
| --- | --- | --- |
| E1 | Ubuntu 24.04, Perl 5.38.2, runs as root, `apt-get install ./file.deb` works | Debian dependencies only — CPAN is unreachable, which the deb already satisfies |
| E2 | Network allowlist: github.com and friends, `*.lazysite.io`, Ubuntu archives, PyPI/npm/crates | The install source above; no other fetch may be attempted |
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
| D2 | A zip of that folder attached to each release, so the skill always matches the deb |
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
