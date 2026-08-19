---
title: "lazysite - What the test suite cannot check"
subtitle: "The areas where a green gate proves nothing, why each one is out of reach, and the manual pass that covers it"
brand: plain
---

# Why this document exists

The gate is thorough about the things it can reach: 6,000-odd tests, a
performance baseline and per-file coverage floors. It is silent about several
areas where lazysite's behaviour actually lives, and that silence reads exactly
like success.

The risk is not that these areas are untested. It is that **"all tests passed"
gets reported as "it works"** when the suite never touched the thing in question.
Every entry below is a case where a change can be complete, green and wrong.

Each section says what cannot be checked, **why** it is out of reach, and the
smallest manual pass that covers it. Where a lint pins the *structure* of
something whose *behaviour* is unreachable, that is called out - a passing lint
there means "the shape is still right", never "it works".

# Manager UI JavaScript

## Why it is out of reach

The manager pages are shipped Markdown with inline JavaScript, rendered into the
browser. The repository has **no browser harness** - no headless Chrome in the
gate, no DOM, no event loop. Nothing executes that code during a test run.

`t/lint/24-no-control-chars-in-manager-pages.t` and
`t/lint/29-domains-one-form.t` read the page SOURCE. They can tell you a function
exists, an id is not duplicated and a retired form has not come back. They cannot
tell you a button works.

## The pass

Sign in to the manager and work each page you changed. For the Domains page
specifically (SM259 consolidated two forms into one, so both modes need
exercising):

1. **Add domain** &rarr; a content folder, a title, an appearance, seed ticked.
   Confirm it registers, appears in the list, and the seeded home page exists.
2. **Add domain** again &rarr; fill in only the host. Confirm it registers and
   every other value shows as inherited.
3. **Add domain** &rarr; use *Copy settings from* against an existing domain.
   Confirm the content folder, title, appearance and language copy across, and
   that the **site address does not** - the new host gets its own.
4. Type a host into a fresh Add form and watch the **site address fill itself
   in**; then edit the address by hand and keep typing in the host. The address
   must stop following once you have touched it.
5. **Configure** the domain you just made. Confirm the sheet shows what you set,
   and that the two modes agree about which fields a domain has.
6. Confirm **Preview**, **Check**, **Export site** and **Delete** still work from
   the sheet, and that Delete is the only destructive control in the danger zone.

For any other manager page: exercise the control you changed, then reload and
confirm the change persisted - a control that updates the DOM without saving
looks identical to one that works.

## The full walkthrough

`docs/manager-ui-guide/` is the menu-complete companion to this document, and
the split is deliberate. **This document is the things the suite structurally
cannot reach, and why.** That one is the whole manager surface, item by item,
with a Where / Do / Expect / Negative for each - written for a person reviewing
the product end to end, an agent being onboarded, and whoever is owed a tutorial.

Use this document when you have changed something and need to know what a green
suite does not tell you. Use the guide when you are reviewing the product rather
than a change. `t/lint/32-manager-guide-covers-the-nav.t` keeps the guide
menu-complete, so a new item cannot ship without an entry.

## The SM266 / SM267 / SM277 batch

Four panels landed together so they share one pass. Their server-side halves are
covered - `t/unit/manager/60`, `t/unit/manager/65`, `t/unit/manager/66` - so what
follows is the part no test reaches, and only that part.

**The tiers below exist so this does not have to be done in one sitting.** A
walkthrough that must be completed before anything ships gets rushed or skipped,
and a rushed pass is worse than an honest partial one. Tier A is small and
genuinely blocks a release. B and C do not.

Record each tier in `docs/manual-check-register.md` when it is done, against the
version it was done on. A pass nobody wrote down has to be repeated.

### Tier A - blocks the PROMOTION, not the cut

Four checks, each a control that **writes or destroys** where the data path is
tested and the button wiring is not. About twenty minutes. Do A1 to A3 in order -
the first creates what the next two need; A4 stands alone.

(This said "three" until 2026-08-19. A4 was added with the 0.10.10 pickers and
the count above it was not, so the section understated its own scope - and a
reader counting checks would have stopped one short of the one with access-control
consequence.)

**Run these against a deployed EDGE build, not against a released site.** The
first version of this document said tier A blocked the cut, which is circular: the
panels only exist after a cut and a deploy, so nobody can verify them on the
release they are meant to gate. An operator went to run it against 0.10.6 and
correctly found the controls absent - they had never shipped.

The order is: cut as **edge**, deploy to an edge site, run tier A there, and let
passing be what allows promotion to beta and stable. A tier-A failure on edge is
an edge release doing its job, and no customer site has seen it.

Sign in as an operator. You will need one folder of content you do not mind
hiding for a minute; make one if there is not one, with two or three pages in it.

#### A1 - hide a section, then publish it

1. Go to **Files**.
2. Find your folder in the list. At the right-hand end of its row, click the
   small **&#9662;** chevron. A card opens underneath it.
3. In that card, under **Protect this section**, choose **Draft**.
4. Leave *Who may read it* blank.
5. Click **Protect this section**, and confirm.

   *Expected:* a message saying the section is hidden. Further down the Files
   page, the **Protected sections** card now lists your folder with a **draft**
   badge and a count of what is under it.

6. Open the site in a **private/incognito window** (not signed in) and visit the
   folder's page - `https://<your site>/<folder>/`.

   *Expected:* **404**. Not a sign-in prompt - the section's existence is what is
   being withheld.

7. Back in the manager, on the **Protected sections** card, click **Publish** on
   that row, and confirm.

   *Expected:* the badge changes from **draft** to **gated**, and the row stays -
   the read list survives. Reload the private window: the page now loads.

**This fails the tier if:** the row does not appear, Publish does not change the
badge, the page still 404s to the public after publishing, or the row vanishes
entirely (Publish must not delete the rule - that is the other button).

#### A2 - remove protection completely

1. On the same **Protected sections** row (now showing **gated**), click
   **Remove protection**.
2. Read the confirmation before accepting it.

   *Expected:* it says this drops the read list as well, so the section stops
   being access-controlled - a wider act than Publish, and it should read as one.

3. Accept.

   *Expected:* the row disappears from the card entirely. The folder is ordinary
   content again.

**This fails the tier if:** the confirmation is indistinguishable from Publish's,
or the row survives, or the content is still gated afterwards.

#### A3 - apply a site package, then undo it

Needs a second registered domain with its own content root and at least one page
in it. If you do not have one, **skip A3 and say so** - a skipped check recorded
as skipped is fine; a guessed one is not.

1. Go to **Backups**. If there is no site package listed, create one first with
   **Export site** on the Domains page for any domain.
2. On a package row, click **Apply**. A panel opens.
3. In **Apply to**, choose your second domain.

   *Expected:* a block appears saying how many files are new and how many would
   be **overwritten**. Note the overwrite number.

4. Change **Apply to** to a different target, then change it back.

   *Expected:* the numbers **change** when the target changes. A number that
   stays the same is a cached first answer, and that is a failure.

5. Click **Apply package** and confirm.

   *Expected:* a success message, and a bar appears at the top of the page
   offering **Undo - restore <snapshot name>**.

6. Visit the target domain and confirm its content is now the package's.
7. Click **Undo** in that bar, and confirm.

   *Expected:* a restore runs. Visit the target domain again - it is back to what
   it was before step 5.

**This fails the tier if:** the overwrite count does not change with the target,
the Undo bar does not appear, or Undo does not restore the previous content.

#### A4 - name a person, the same way, in four places (0.10.10)

SM305 replaced **five** different controls for naming a person or group with one
shared `<select>`. Four manager pages changed, and every one of them is browser
JavaScript, which no automated test in this repository can reach: the suite
proves the files parse and that no datalist survives, and neither proves a
control works when a human clicks it.

It is tier A rather than tier B because the loosest of the five governed **who
may read protected content**, so a control that silently fails to register a name
grants a section to nobody while reporting success.

1. Go to **Files** and open a folder's card. Under **Protect this section**, use
   the picker beside *Who may read it*.

   *Expected:* a dropdown of real users and `@groups` - not a free-text box.
   Choosing one adds a removable chip. There is no way to type a name that does
   not exist.

2. Add two, remove one with its **&times;**, then click **Protect this section**.

   *Expected:* the section is protected for exactly the remaining name. Re-open
   the card: the read list matches what you left.

3. Go to **Groups**, open a group, and use the *add a user or group* picker.

   *Expected:* a dropdown, and the group itself is **absent** from its own list.
   Selecting a name does **not** post on its own - the **Add** button commits it.
   Arrow through the options with the keyboard: nothing is added until you press
   Add.

4. Go to **Users**, start the add-user form, and use the *add a group* picker.
   Then go to **Domains**, configure a domain, and use the *Groups allowed to
   manage* and *Users locked to this domain* pickers.

   *Expected:* all three are dropdowns constrained to real principals. The
   Domains ones offer only the right kind - groups for one field, users for the
   other.

**This fails the tier if:** any of the five is still a free-text box or a
suggestion list that accepts typed text; if the Groups picker posts on selection
rather than on **Add** (a keyboard user arrowing through options would add
members they never chose); if a chip cannot be removed; or if a saved read list
does not match what was chosen.

### Tier B - blocks the minor bump, not the cut

Verification of things that are wrong-but-recoverable, or read-only.

4. A draft section 404s to a signed-out visitor and is absent from
   `/sitemap.xml`.
5. A **scoped** (non-operator) manager sees only sections inside their scope.
   Security weight, but the filter itself is suite-covered
   (`t/unit/manager/66`) - what is unverified is that the panel passes the
   request through it.
6. The readiness warning appears for a target whose DNS is not pointed, and the
   apply is **still allowed**.
7. **Keep this site's theme** on apply: content arrives, theme does not change.
   Untick everything and confirm the previous behaviour is unchanged.
8. Services counts: "held by N groups / M accounts" matches the Groups page, and
   turning a service off flags those grants dormant in the Users grid.

### Tier C - opportunistic

Cosmetic or convenience. Do them when passing.

9. Counts on the protected-sections rows are right (pages vs assets, recursive).
10. An operator with `manage_config` but not `manage_users` sees **no** Services
    counts - absent, not zero.
11. The connect code counts down, says plainly when it has expired, and strikes
    it through.
12. **Regenerate** swaps the code in place without rebuilding the panel, and the
    old code is refused at the OAuth prompt.

# Web-server behaviour (vhost templates)

## Why it is out of reach

The vhost templates are configuration for Apache and nginx. The suite has
neither. `t/lint/28-registries-routed-to-engine.t` asserts the routing lines are
PRESENT in all four templates and explains why; it cannot start a web server and
issue a request.

This gap has already cost a release: SM248's per-domain handler was correct in
the processor and unreachable in production, because `FallbackResource` only
routes paths that do not exist. It worked on the dev server, which is where it
was tested, and nowhere else.

## The pass

On a real Apache or nginx front, with at least two domains where the secondary
has its own `content_root` **and the primary has registries of its own** (a
primary with no `sitemap.xml` proves nothing - there is nothing to fall through
to):

```bash
curl -sS https://secondary.example/sitemap.xml | head
curl -sS https://secondary.example/llms.txt   | head
```

Both must reflect the secondary domain, not the primary. Repeat for
`robots.txt`, `feed.rss` and `feed.atom`.

**A deployed site does not get this from an upgrade.** The templates apply at
install time, so an existing vhost keeps its old routing until it is regenerated
or the lines are added by hand. Check the vhost actually in force, not the
template in the tree.

# Multi-domain serving

## Why it is out of reach

Per-Host behaviour needs a real `Host` header reaching a real front end. The
integration suite drives the processor directly with a synthesised environment,
which exercises the engine's logic and not the routing in front of it.

## The pass

For each registered domain: its own home page, its own 404 (mistype a URL and
confirm the branding is that domain's), its own theme assets loading rather than
404ing, and - if it is part of a language set - the switcher offering its
siblings.

Confirm a **chrome-only alias** (no `content_root`) still inherits the primary's
content. Breaking that trades one defect for another and the suite will not
notice.

# WebDAV clients

## Why it is out of reach

`t/integration/dav-publish.t` speaks the protocol directly. Real clients -
Finder, Windows Explorer, `rclone`, `cadaver` - differ in how they lock, how they
probe, and what they do with a `507`. A response that satisfies the RFC can still
confuse a specific client.

## The pass

Mount the endpoint with at least one GUI client and one command-line client.
Create, edit, rename and delete a file; confirm each lands. Then write to a
directory the site user cannot write and confirm the error names the condition
(SM235) rather than surfacing as a generic failure.

# The MCP connector

## Why it is out of reach

The unit tests drive the JSON-RPC endpoint as a subprocess, which covers the
protocol and the tool logic. They do not cover a real assistant connecting: the
OAuth exchange, the tool list as the client renders it, or how a model reads a
tool description.

A description that misleads an agent is a real defect and no test will find it -
SM261 exists because five tools returned five differently-named list keys and an
agent reported working code as broken.

## The pass

Connect a real client. Confirm `whoami` and `describe_capabilities` answer, that
the tool list matches what the account should hold, and that a refusal reads
clearly enough to act on. When a tool description changes, have the agent attempt
the task from the description alone.

# Delivery: email, chat, notifications

## Why it is out of reach

SMTP and XMPP delivery need a server on the other end. The suite checks that a
handler is invoked and what it is handed; it stops at the socket.

## The pass

Submit a real form on a site with an SMTP handler and confirm the mail arrives,
including from a queue rather than only in the happy path. With `notify-xmpp`
configured, confirm the chat notice arrives and carries **no submitted content** -
that is the design, and a regression would leak content to a phone on a lock
screen.

# Installer and permissions

## Why it is out of reach

`install.pl` runs as root against a real filesystem, sets ownership and modes,
and behaves differently under `sudo`. The suite exercises its logic in a
temporary tree as an unprivileged user, which is the wrong user on the wrong
filesystem.

This has already caused a live incident: a stable deploy dropped group write on
every root folder, which is what SM246 exists to prevent recurring.

## The pass

On a scratch host, install fresh and then upgrade in place. After each, confirm
group write survives on the docroot and every directory the engine writes to,
that a site user can still publish, and that `lazysite-check --fix` reports
nothing left to repair. Do the same run under `sudo` - the ownership path differs.

# FastCGI pool

## Why it is out of reach

`t/lib/MiniFcgi.pm` pins state isolation across consecutive pool requests over
the real protocol, which is the part most likely to break. It does not cover the
systemd unit, socket permissions, or what happens when the pool is not running.

## The pass

Under the pool: confirm anonymous traffic is served, a logged-in operator still
gets the admin bar (session traffic must stay on the CGI path), and stopping the
pool degrades visibly rather than serving stale or empty pages.

# Security headers as actually served

## Why it is out of reach

The processor's headers are asserted in the suite. What a browser receives is the
processor's set **plus whatever the front end adds, strips or overrides**.

CSP and HSTS are no longer vhost concerns: since SM352 the engine emits both.
HSTS only over TLS, and the CSP only on HTML, in the mode `lazysite.conf` sets -
`csp: enforce | report-only | off`, defaulting to **report-only**.

That default is the thing to check by hand, because the suite cannot: a CSP
hash covers a `<script>` **block** and NOT an inline event-handler attribute,
and the manager's own pages use `onclick=`. So under `csp: enforce` the
manager's cache, audit, sessions and plugins controls may silently stop firing -
in the browser, with nothing in the response to say so. **Walk the manager with
the console open before setting a site to enforce**, and confirm zero CSP
violations.

## The pass

```bash
curl -sSI https://example.test/ | sort
curl -sSI https://example.test/no-such-page | sort
```

The 404 must carry the same baseline set as the 200 (SM253), and that now
includes the CSP and - over TLS - HSTS, because the engine emits them itself.

**402 and 403 are the ones to check by hand**, not the 404: they were found
printing their own headers and carrying none of the baseline set (SM381).

# Static files under access control (SM223)

## Why it is out of reach

The enforcement is engine-side and fully tested: `t/integration/35` drives the
processor directly and covers the read decision, folder scope, group entries,
the 403-versus-login-bounce split and `no-store`. What no test can reach is
whether a front end **lets the request get to the engine at all** - which is the
entire failure mode SM223 exists to fix.

`t/lint/31` asserts the routing rule is present in all ten shipped configs, and
that is a text match. It cannot tell you whether Apache and nginx actually
*behave* that way: rule ordering, the interaction with `DirectoryIndex`, whether
`RewriteCond ... -f` on the ACL file evaluates per request as expected, or
whether nginx's `error_page 418 = @lazysite` jump fires where intended.

The dev server IS covered - `t/unit/tools/03` drives the predicate, and the
behaviour was confirmed against a running instance. Apache and nginx were not,
because this host runs neither.

## The pass

On a site with **no** `lazysite/auth/acls.json`, first confirm nothing changed:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://example.test/assets/logo.png
curl -sS -o /dev/null -w '%{http_code}\n' https://example.test/some-static-page
```

Both 200, served by the front end. Check the access log shows no CGI hit for
them - if the engine is now handling every asset on a site with no ACLs, the
condition is inverted and every site pays the indirection.

Then create the store and re-check:

```bash
echo '{"private":{"read":["alice"]}}' > <docroot>/lazysite/auth/acls.json
curl -sSI https://example.test/private/brief.html | head -3
curl -sS https://example.test/private/notes.pdf | head -c 40
```

Anonymous must get a 302 to the login page with `Cache-Control: no-store`, and
**no body bytes**. Then sign in as a permitted user and confirm the file is
served, and as a non-permitted one and confirm 403.

Three specific things to look at, each of which the lint cannot see:

- **ordering** - the ACL rules must fire before the SM133 `.shtml`/`.html`
  fallbacks. Every rule in those files ends in `[L]`, so a mis-ordered ACL rule
  is simply never reached and the file is served as before.
- **no redirect loop** - the rewrite targets `/cgi-bin/lazysite-auth.pl`, and
  `/cgi-bin/` is excluded from the condition. Confirm a normal page still loads.
- **the `.brief` deny** - Apache's `<FilesMatch>` matches the *resolved* file, so
  once the request is rewritten to the CGI that deny no longer applies to it. The
  processor's own guard covers it. Request a `.brief` on an ACL site and confirm
  it 404s.

Remove the test `acls.json` afterwards, or the site keeps routing every static
through the engine.

# The front end that answers first (SM283)

## Why it is out of reach

This is the check that would have caught a live disclosure, and the reason it
did not exist is worth stating plainly: **every check we had asked about the
layer we had a file for.** On Hestia the request path is nginx to Apache.
lazysite shipped four Hestia templates, all of them Apache, and `t/lint/31`
proved the ACL rules were present in every one. They were. Hestia's own nginx
proxy answered the request first, off a fixed list of static extensions, and
Apache never saw it.

The measurement, on a live site: identical bytes uploaded into one ACL'd folder
under five extensions. `.png`, `.pdf`, `.txt` and `.bin` were served to an
anonymous client, byte-identical to the source. `.dat` gated - because `.dat`
was not on the proxy's list. The section's *pages* bounced to login throughout,
so the manager, the audit trail and the operator all agreed it was protected.

The suite now goes further than it could when this section was first written.
`t/lint/34` runs `nginx -t` over every shipped nginx config, and
`t/integration/42` **starts nginx** against the rendered Hestia proxy template
and reproduces the measurement above: five extensions, one folder ACL, all five
must leave nginx. It also pins the fast path, so a template that "fixed" this by
sending every static request to the engine fails too. Both skip where nginx is
absent, which is a real gap and the reason `t/lint/33` still pins the same files
by text.

That leaves a narrower thing for a person, and it is worth being exact about
what it is. The tests render the template with a *representative*
`proxy_extensions` list and no Apache behind it. A real host has Hestia's own
list (which the operator can change), Hestia's rendering of the template, and a
live origin. So what a human is confirming is that **this deployment** behaves,
not that the template is right.

## The pass

**Run this on a deployed Hestia site, after the release is out** - it gates
promotion to beta/stable, not the cut (see *How to use this document*).

1. Ask which front end answered. No credentials, from anywhere:

   ```bash
   curl -sI https://example.test/ | grep -i x-lazysite-front
   ```

   Expect `X-Lazysite-Front: hestia-proxy/acl`. Nothing means the domain is
   still on a stock proxy template - stop here and apply
   `v-change-web-domain-proxy-tpl <user> example.test lazysite-proxy`.

2. Reproduce the original measurement. Put the same bytes under five
   extensions inside a folder you then protect:

   ```bash
   cd <docroot> && mkdir -p upcoming
   head -c 2048 /dev/urandom > upcoming/probe.png
   cp upcoming/probe.png upcoming/probe.pdf
   cp upcoming/probe.png upcoming/probe.txt
   cp upcoming/probe.png upcoming/probe.bin
   cp upcoming/probe.png upcoming/probe.dat
   echo '{"upcoming":{"read":["alice"]}}' > lazysite/auth/acls.json
   ```

   Then, anonymously:

   ```bash
   curl -sS -o /dev/null -w '%{url_effective} %{http_code}\n' \
        https://example.test/upcoming/probe.{png,pdf,txt,bin,dat}
   ```

   **All five must be 302** to the login page. Four 200s and one 302 is the
   defect verbatim. Confirm no body bytes come back on any of them.

3. Confirm the fast path is intact. Delete `lazysite/auth/acls.json` and fetch
   an ordinary asset:

   ```bash
   curl -sI https://example.test/assets/logo.png | grep -i 'expires\|x-lazysite'
   ```

   It should carry `Expires` far in the future - nginx served it directly. A
   site that never asked for access control must not start paying for it.

4. Check the fleet, not just the site in front of you:

   ```bash
   lazysite-hestia-list.sh
   ```

   Any domain flagged `ACL-BYPASSED-BY-PROXY(SM283)` is exposed right now.
   `lazysite-hestia-update-all.sh --proxy` moves them all.

Remove the probe files and the test `acls.json` afterwards.

## Or let the site do it (SM285)

Steps 2 and 3 above are now a command, and it does the whole thing - creates
the probe, gates it, fetches it anonymously under six file extensions, compares
each against a public control of the same type, and cleans up after itself:

```bash
lazysite check --docroot <docroot> --check-acl https://example.test
```

A **FAIL** names the extensions that leaked and says whether the split is by
file type, which is the signature of a front end serving a static list off the
docroot. An **OK** states its evidence: every type was served when public and
refused when gated. A **warn** means it could not tell - the public control did
not come back either, so a refusal proved nothing.

Run this first. The manual pass above is still worth doing once on a new
deployment shape, because a person notices things a probe was not told to look
for - but on a known shape the command answers the same question in one line,
and it is the thing to put in a cron job.

# How to use this document

Read the section matching what you changed, not the whole file. If a change
touches an area listed here, **say so when reporting it**: "tests pass" is true
and incomplete, and the difference between the two is what this document exists
to keep visible.

When a manual pass finds something, the fix is usually a test one level down -
the routing lint (SM248) and the one-form lint (SM259) both exist because a
manual pass found what the suite could not.
