---
title: "Test plan - 0.15.3 and 0.15.4 on edge"
subtitle: "0.15.3 went to edge with no plan of its own, so this one covers both. Sixteen release-specific checks that only a deployed host can run, the upgrade check that comes before them, and the standing tiers."
brand: plain
standard-margins: true
---

# What this plan is for

0.15.3 (published 2026-10-09) and 0.15.4 (gate running on main 5b5a3857 at the
time of writing) are mostly security work. Moving the manager API's gates into
modules (SM944) meant reading each gate as it moved, and the reading found
places where a caller confined to some domains could reach others. Every gap
was reproduced by a probe before it was fixed, and each fix has tests that fail
when it is undone. The suite cannot see three things this work depends on.

**Real grants on real sites.** The tests build their own tokens, grants and
domains. Whether an existing partner token on a live multi-domain site still
does its job after the upgrade is a question only a deployed site answers.

**A FastCGI pool under real traffic.** SM973 is about what a pooled worker
remembers between requests; the tests drive the request loop in one process.

**What a browser and a WebDAV client actually send.** The Appearance page's new
domain choice, and the bytes a WebDAV client uploads, are exercised by fixtures,
not by the clients people use.

# Before anything else: the upgrade check

The behaviour changes below can take a working partner's access away. Check
this on every multi-domain edge site BEFORE walking the rows, and report what
you find even when nothing breaks.

**U1 - who loses what.** For each token, MCP grant and WebDAV account on a site
with more than one domain, note its scope. After the upgrade:

- one with **no scope** reaches the primary site only. It can no longer write
  any other domain (SM975). To restore it, name its group in that domain's
  `allowed_groups`.
- one **scoped to some domains** reaches only those domains, and can no longer
  change instance-wide settings: configuration, theme or layout activation
  without a host, layouts, extensions, registries, instance backups (SM976).
- the structured nav read (`read_nav`, `nav-read`) no longer needs
  `manage_content` or `manage_nav` (SM943); writing the nav still needs
  `manage_nav`.

*Report:* each credential that was doing something it can no longer do, and
whether that was intended. It is a FAIL if the operator's own cookie session,
or a single-site site's credentials, lose anything.

# The order

1. Record the version the check panel REPORTS, not the tarball's.
2. U1 above.
3. R1 to R4, the confinement core, on a site with at least two domains.
4. R5 (the pool) on a FastCGI-pooled site.
5. R6 to R16 in any order.

# Release-specific checks - 0.15.3

## R1 - a token or grant with no scope reaches no other domain (SM975)

With a token (or MCP grant) holding `manage_domains` and no scope, try
`domain-set`, `remap-save` and `domain-remove` on a domain that is not the
primary, and `remap-save` on a host the instance does not serve.

*You should see:* each refused, the message saying the credential has no scope
and how to give it one. Nothing written. The same calls from the operator's
session succeed.

## R2 - a scoped caller reaches only its own domains (SM976)

With a credential scoped to domain A, on a site that also serves domain B:
`read_nav host=B`, `set_nav host=B`, `domain-set` on B, `domain-add` with a
content root outside A, a site package of B (create, download, delete), and
`list_domains`.

*You should see:* every call on B refused; `list_domains` lists A only; the same
calls on A succeed. Repeat over WebDAV: a GET and a PUT of B's nav file are
refused (before this build both worked).

It is a FAIL if any call on B succeeds, or if a refusal names or lists B.

## R3 - a confined caller cannot change instance-wide settings (SM976)

With the credential scoped to A and holding `manage_config`: `config-set` of
`site_name`; theme activation with no host.

*You should see:* both refused as instance-wide. Activation WITH `host=A`
succeeds and changes A only. The operator can still do both.

## R4 - reads are not audited unless they fail (SM943)

Run a few successful reads (`read_page`, `read_notices`, `describe_capabilities`)
over MCP and over the API, then one refused read (a path outside the
credential's scope), then a write.

*You should see:* in the audit trail, no rows for the successful reads on
either surface, one row for the refused read, one for the write. A download
(`file-download`, `site-backup-download`) still writes its row.

## R5 - a pooled worker sees a protection added after its first request (SM973)

On a FastCGI-pooled site, fetch an unprotected file (a PDF works) anonymously
a few times so the workers have served it. Then give it a read rule in the
manager and fetch it anonymously again, several times.

*You should see:* every fetch after the rule redirects to sign-in. Before this
build a worker that had already served it kept serving it until it restarted
(up to 500 requests). Remove the rule: it is served again.

## R6 - a stats day is a UTC day (SM974)

On a host whose clock is east of UTC (BST counts), make a few visits between
local midnight and 01:00, then read the next day's Stats.

*You should see:* those visits counted in the UTC day they happened in. Before
this build the last local hour of each day never reached the day's file. A site
that reads the web-server log now buckets by UTC day too; the day of the
upgrade may be split across two.

# Release-specific checks - 0.15.4

## R7 - a theme another domain serves cannot be written by a scoped caller (SM976 F1)

With a credential scoped to A: write a file into the theme that domain B (or the
primary) is serving, over MCP `write_file`, over WebDAV, and through the
manager's file editor.

*You should see:* each refused, saying to copy the theme, edit the copy and
activate it with `host`. Writing into a theme only A uses, or an unused one,
works. Uploading over a file in the instance's active theme is refused for
everyone, operator included (multipart upload never checked this before).

## R8 - forms and briefs stay inside the caller's scope (SM976 F2, Q15e)

With a credential scoped to A: `form_list`, then read the submissions and change
the upload settings of a form bound only on B's pages; read a brief for a page
on B.

*You should see:* the list shows A's forms only; the other calls refused, with
the same answer a missing form gets.

Then the takeover: pick a form no page binds (it counts as the primary's) and
save a page in A's content with `form: <that name>` in the front matter.

*You should see:* the save refused (403, `form-bind-refused`), and the form's
submissions still unreachable. Editing a page that already binds one of A's
forms still saves. A brand-new form name binds as before.

## R9 - the Appearance page activates on the manager's own domain (SM976 F4)

Sign in as a manager scoped to one domain; open Appearance and activate a theme.

*You should see:* it activates on that domain, and the page says where Activate
applies; no `manage_domains` needed. A manager scoped to two domains is asked
which. The operator's page behaves exactly as before.

## R10 - create_form adds to the page instead of replacing it (SM977)

Over MCP, `create_form` on an existing page using the extensionless path the
tool documents (`/about` for `about.md`).

*You should see:* the page's existing text intact, with the form block appended.
Before this build the page was overwritten with a blank scaffold. On a page that
does not exist, the page is created as before.

## R11 - copy_file refuses an existing destination (SM977)

`copy_file` onto a page that already exists.

*You should see:* refused, saying `write_file` replaces a file. The destination
is unchanged.

## R12 - a page that is not UTF-8 is refused at the door (SM976 Q15h)

Upload a `.md` page saved as Latin-1 with an accented letter (`José` as byte
`0xE9`): over WebDAV PUT, over MCP `upload_file`, and through the manager's
upload.

*You should see:* each refused (415, `page-encoding-refused`), naming the offset
of the first bad byte and saying to save the file as UTF-8. The same page saved
as UTF-8 uploads. It is a FAIL if any door stores the Latin-1 file.

## R13 - one bad page on disk no longer breaks the site (Q15h, Q15i)

Place a Latin-1 page directly on disk (shell or SFTP, since the doors now refuse
it) under a folder that a `scan:` page lists, on a test site.

*You should see:* the listing page, the home page and the sitemap still render;
before this build every page answered 500. The bad page itself still answers
500. MCP `list_pages`, `audit_site`, `form_list` and `search_files` answer for
the rest of the site, and `read_page` on the bad page returns
`page-encoding-refused` with the offset, not an empty answer. The engine log
names the skipped page. Remove the test page afterwards.

## R14 - a version that is not UTF-8 is not restored (Q15k)

Only if a page's history holds such a version (R13's page, committed, will do):
`restore_version` to it.

*You should see:* refused with the encoding error naming the version; the page
left as it is and no new commit. Restoring a UTF-8 version works byte for byte.

## R15 - the page walk says when it stopped (Q15j)

Only on a site with more than 1,000 pages: `list_pages` or `audit_site`.

*You should see:* `truncated: true` and the cap in the answer. On a smaller site,
`truncated` is false.

## R16 - blocking an address by hand works (bad-url-block)

`bad-url-block` blocks a client IP address. Do NOT block your own address. Block
a documentation address (`203.0.113.7`), read the list with `bad-url-blocks`,
then unblock it with `bad-url-unblock` and read the list again.

*You should see:* the address listed after the block and gone after the
unblock. Before this build the block action failed every time and listed
nothing.

# Standing tiers

Tier A before any promotion to beta or stable, as for every edge build. U1 is
part of this plan's promotion decision: report it even when every row passes.
