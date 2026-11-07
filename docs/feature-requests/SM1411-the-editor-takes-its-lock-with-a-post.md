---
id: SM1411
title: "SM1411: the editor takes and renews its lock with a POST"
subtitle: "The editor sent lock and renew-lock as GETs. Both are declared mutating and the API refuses a mutating action sent as GET, so no editor open since 0.7.19 was granted its lock, and since 0.15.5 the page showed the refusal as its lock label. Both are POSTs now, and a lint keeps every manager page's write a POST."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-07
raised-by: "the lazysite developer agent, from edge testing of 0.16.7 (T-105, brief n774)"
area: manager
status-note: "SHIPPED (0.16.8) on n774: starter/manager/edit.md posts lock and renew-lock. t/unit/manager/480, t/lint/340. UPGRADE.md note under Unreleased (0.16.8)."
---

# What happened

On the 0.16.7 edge run (T-105, R9 W2) the editor page for a form's conf began
"zz80-form.conf This action must be sent as POST." before the toolbar words.
It was not the form conf's alone: `starter/manager/edit.md`'s `acquireLock`
took the lock with `fetch(API + '?action=lock&path=...')`, a GET, and the
renewal it schedules every minute sent `renew-lock` the same way. Both are
declared `mutates => 1` in `Lazysite::ControlApi::Actions`, and
`lazysite-manager-api.pl` refuses a mutating action sent as anything but POST
("This action must be sent as POST.", SM475). `unlock`, the editor's "Take
over", already posted.

# Since when

`git log -S` on the editor's fetch names one commit, ec11730db (the editor's
first version as the manager): the lock call has been a GET for as long as the
page has existed. What changed is the server:

- 3923dda28 (SEC-2026-07, 2026-07-15, first in 0.7.19) put `lock unlock
  renew-lock` in the cookie path's `%MUTATING` list with the POST-only refusal.
  From then on no editor open was granted its lock. The page took the refused
  answer as "not locked by anyone" and showed the file as being edited, so
  nobody saw it; the file was simply unlocked while it was edited.
- f7ec23865 (SM475, 0.10.26) moved the refusal in front of both channels, and
  3536e4ee8 (SM943 stage 1a, 0.15.3) declared the same fact as `mutates` on the
  action. Neither changed what the editor received.
- c37798ad6 (SM992, first in 0.15.5) taught the page to show a refused lock:
  `data.ok === false && !data.locked` puts the error in the lock label and
  disables Save. From 0.15.5 every editor open therefore showed "This action
  must be sent as POST." and began with Save disabled.

# Could a released editor save?

Yes. Save starts disabled on every open, and `markDirty` enables it on the
first change, so an edit could still be saved through the page in every
release: the save is its own POST and needs no lock held by the saver. What
no release since 0.7.19 did was hold the lock while a file was open, so two
editors on one file were never told of each other.

# The change

`acquireLock` posts `lock`, and the renewal posts `renew-lock`, as
`takeOverLock` posts `unlock` and SM957 made the bell post `notices-seen`. The
layout's fetch wrapper adds the CSRF token to a POST to the API, so nothing
else changes on the page. The server is unchanged.

# Tests

t/unit/manager/480
: runs the editor's own `acquireLock` under node with `fetch` recorded (the
  shape of t/unit/manager/204): the lock and the renewal it schedules are POSTs
  naming the file. With the change reverted both are GETs (2 assertions fail).

t/lint/340
: reads every `fetch(...)` call in starter/manager/*.md and
  starter/lazysite/manager/, and for each action the call names literally asks
  the action table whether it mutates; a mutating one must say `method:
  'POST'` in the call. At this commit 66 calls name a mutating action and all
  post. With the change reverted it names edit.md's two lock calls. A call
  whose action is built at run time is not judged.

# Upgrade

Nothing to do but the upgrade: the page is a shipped manager page and is
replaced by it. UPGRADE.md says so under Unreleased (0.16.8).
