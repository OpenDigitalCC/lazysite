---
title: "SM285 - A site should be able to prove its own gating works, whatever is in front of it"
subtitle: "SM283's fix is a template for one panel. The general problem is that a site cannot tell whether its protected sections are actually protected, and the operator who most needs to know is the one least able to find out."
brand: plain
status: shipped
status-note: "SHIPPED on main (unreleased) 2026-08-12, as phase 1 item 1 of WORK-PLAN-ACCESS-CONTROL. `lazysite check --check-acl URL` creates a probe folder, gates it against a principal that cannot exist, and fetches it anonymously under six extensions - several on purpose, because SM283 gated .dat and leaked the rest, so a one-extension probe reports a leaking site healthy. EACH GATED FILE HAS A PUBLIC CONTROL of the same type outside the folder: without it a refusal proves nothing, since an unreachable site and a 403 the front end returns because it cannot read the file both read as correct gating. Cleans up its files and its ACL entry, including via an END block after an interrupt, re-reading the store so a rule added meanwhile is not reverted, and sweeps anything an earlier interrupted run left. No filesystem path in the output - it names EXTENSIONS, which is what identifies the layer. TESTED against two real front ends in t/integration/43: the dev server (must report OK) and nginx serving a static extension list with the rest proxied, which is SM283 reproduced (must FAIL and must recognise the extension split). IT SHIPPED BROKEN FIRST AND THE TEST CAUGHT IT: the extension list was a file-scoped `my` below the main body, which exits before reaching it, so the list was EMPTY - zero fetches, 0 == 0, and a verdict of 'the front end respects the ACL' against a port with nothing listening. A security check that passes by testing nothing is the exact defect this programme exists to remove; it has its own regression test, and perlcritic flags the same hazard as unreachable code."
---

# SM285 - let the site answer the question

## The question that prompted this

After 0.10.7 shipped the Hestia nginx proxy template, the operator asked whether
applying it was essential - the panel makes custom proxy templates awkward.

The honest answer is that the template is **one** fix, for **one** front end,
and lazysite currently has no way to tell an operator whether any given
deployment is exposed. That is the more serious gap, and it is the one SM283
should have been read as reporting. Twice now (SM248, SM283) correct engine code
has been unreachable because of a layer in front of it, and both times the
discovery came from outside: a person fetching a URL and being surprised.

## The proposal

`lazysite check --check-acl URL` - a self-probe that answers the only question
that matters, without knowing anything about nginx, Apache, Hestia or extension
lists:

1. write a file with random content into a temporary path;
2. give that path an ACL entry that permits nobody;
3. fetch it over HTTP from the URL the operator gives, **anonymously**;
4. **FAIL** if the bytes come back; OK on a 302 to login or a 403;
5. remove both the file and the entry, whatever happened.

The whole mechanism already exists. `--check-dav` shells `curl` list-form with
`--max-time`, reads the status code, and distinguishes a routing failure from an
auth challenge - which is exactly this shape, pointed at a different question.

## Why this beats the template as the primary answer

**It is front-end agnostic.** It gives the same verdict on Hestia, on plain
nginx, on Apache, on a shape nobody has thought of yet. The template only fixes
the deployment we happened to diagnose.

**It fails closed on ignorance.** An operator who has never heard of
`proxy_extensions` gets a FAIL with a remedy. Today the same operator gets
silence, and silence reads as safety.

**It would have found SM283 without anyone looking.** The exposure was live for
weeks across a fleet, and what eventually found it was an agent uploading the
same bytes under five names by hand.

**It converts a fleet-wide guess into a list.** "Which of my sites are exposed?"
is currently answered by knowing which front end each domain uses. It should be
answered by running the checker.

## What it does not do

It does not replace the proxy template. A site that fails this check still needs
a fix, and on Hestia that fix is the template (or turning the domain's proxy
off). This tells you **whether** you need it and **whether it worked** - which
is what an operator can act on, and what SM283 conspicuously lacked.

It also cannot run where the site has no egress to itself. `--check-dav` has the
same limitation and reports it as a WARN rather than pretending; do the same.

## Care needed

**The probe must not become the exposure.** It writes a real file that is
briefly reachable by path. Use an unguessable name, remove it in an `END` block
so an interrupted run cannot leave it behind, and never place it inside content
the operator published.

**A cached 200 must not read as a pass or a fail.** Request with
`Cache-Control: no-cache` and treat an unexpected code as WARN, not OK - the one
outcome that must be unambiguous is "the bytes came back", which is the FAIL.

## Acceptance

- On a site whose front end serves ACL'd statics directly, `--check-acl` FAILs
  and names the layer rather than the file.
- On a correctly-gated site it reports OK, and leaves nothing behind.
- The probe file and its ACL entry are removed even when the run is interrupted.
- No filesystem path appears in any output (the standing rule).
- A site with no egress to itself gets a WARN that says so.

## What building it taught, which was not in the design

**The probe shipped with a false pass and a test found it.** The extension list
was declared as a file-scoped `my` beside the subs, and this file's main body
exits before it gets there - so the list was empty, the loop ran zero times, the
"all refused" verdict compared 0 with 0, and the probe reported a healthy front
end against a port with nothing listening on it. It would have reported every
site healthy, for ever, and its output would have read exactly like success.

That is the same shape as [[SM278]] and as SM283 itself: **a control reporting
success without doing the work.** Writing a checker does not make one immune to
the class of defect the checker exists to find.

**"Refused" is not evidence unless something was served.** The first design
counted a 403 as correct gating. But a 403 can be the front end failing to read
the file, and a site that is simply down refuses everything - both would have
read as a pass. Every gated probe now has a **public control** of the same file
type outside the gated folder, and the OK verdict states its evidence: *served
when public, refused when gated*. Without the control the check could only ever
have proved the absence of a leak, never the presence of gating.

## Related

[[SM283]] (the Hestia half, shipped in 0.10.7 - its "there was no observable"
finding is what this generalises), [[SM248]] (the first time front-end routing
made correct engine code unreachable), [[SM223]] (the engine enforcement, which
has been right throughout), and `--check-dav` in `tools/lazysite-check.pl`,
which is the pattern to copy.
