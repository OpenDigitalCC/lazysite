---
title: "Files"
brand: plain
---

# Files

Governing capability: `manage_content`. Scope-confined users see only their own
domains' content roots - test that with a scoped account, not an operator, or the
confinement is untested.

## Browse and filter

Where
: Content -> Files

Do
: Open a folder from the breadcrumb, filter by name, then filter by type.

Expect
: The listing shows name, access, modified and a selection box. The breadcrumb
  reflects the canonical path, not what you typed - a path spelled with `..`
  resolves and is displayed resolved. A recent-change dot appears beside anything
  edited inside the recent window, with who and when in its tooltip.

Negative
: Without `manage_content` the Files item is absent from the nav; a user with
  `manage_users` sees it greyed with a padlock and a tooltip naming the grant
  needed.

## Create, edit and save a page

Where
: Content -> Files -> Add File

Do
: Create `walkthrough.md`, edit it, save. Then open it a second time in another
  browser and try to save from both.

Expect
: The editor opens with the file's content. Saving writes it and invalidates the
  cached render. The second browser is told the file is locked and by whom; the
  lock ages out rather than stranding the file forever.

Negative
: A user whose ACL grants read but not write can open the file and is refused on
  save, with a message naming the owner.

## Upload and download

Where
: Content -> Files -> Upload / Download selected

Do
: Upload an image, a text file, and something over the size limit. Select two
  files and download them as a zip.

Expect
: Accepted uploads appear immediately. An oversize upload is refused before the
  body is read, with the limit stated. The zip contains exactly what was
  selected.

Negative
: An upload of a file type the site disallows is refused with the reason, not a
  generic failure.

## Per-file permissions

Where
: Content -> Files -> a file's Access column

Do
: Claim a file, set a read list and a write list, then sign in as an excluded
  user and try to read it.

Expect
: You become the owner. The lists accept users and `@groups`. Setting a rule that
  names a `@group` returns a warning saying the rule cannot match a token, MCP or
  WebDAV partner - those channels carry no groups.

Negative
: A non-owner, non-operator cannot change permissions at all; the refusal says
  only the owner may.

## Protected sections

Where
: Content -> Files -> Protected sections

Do
: Add a folder ACL with `draft: true` on a section, reload, then Publish it.
  Repeat with a gated (non-draft) section and use Remove protection.

Expect
: The panel lists each protected prefix with its policy (draft / gated), who may
  read it, and a recursive count of pages and assets. A draft section 404s to a
  signed-out visitor and is absent from `/sitemap.xml`. **Publish** clears the
  draft flag and keeps the read list; **Remove protection** deletes the entry
  entirely - two different acts, two different controls.

Negative
: A scope-confined manager sees only sections inside their own scope. This one
  carries security weight: the list must not tell them content exists elsewhere.

## Content history

Where
: Content -> Files -> a file's History, and History overview

Do
: Edit a file three times, open its history, view an old revision, restore it.

Expect
: Each save is one revision with an author and a date. A restore routes back
  through the ordinary save path, so it takes its own lock, invalidates the same
  caches and appears in the audit trail as a restore. The overview lists every
  file under history with revision counts.

Negative
: Absent entirely when content history is not enabled for the site - the control
  hides rather than erroring.

## Aliases

Where
: Content -> Files -> Aliases

Do
: Add `aliases:` to a page's front matter, save, and reload the panel.

Expect
: The alias appears with its target and a 301 badge; `aliases_temp:` shows 302.
  The list is read-only - aliases are authored in front matter, and the panel
  says so.
