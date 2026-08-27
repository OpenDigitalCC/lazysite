---
title: "SM307 - the private store move reports a cause it never checked"
subtitle: "One condition, two different messages, and neither names the real fault - while the WebDAV layer on the same docroot names it exactly"
brand: plain
status: shipped
status-note: "SHIPPED on claude/sm305-principal-picker-and-polish. move_in and move_out share one _move_failure reporter that branches on $!{EXDEV}: a genuine cross-device DIRECTORY move still refuses and now names both locations and why it refuses; anything else reports what $! says, borrowing the WebDAV wording that separates a server configuration fault from a decision about the request, and points at `lazysite check` / `--fix`. The single-file _mkpath branch reports the same way, so one condition no longer gets two accounts. The comment describing the copy fallback as general now says it covers FILES ONLY. VERIFIED by t/unit/manager/75, shown to fail before the fix. SEPARATELY, and beyond the filing: the rollout script now REPAIRS what its health summary finds and re-checks, because SM270 recurred on edge three releases after the ordering fix - a rebuild driven through the control panel never reaches that script. FILED 2026-08-15 from a partner-agent field test of 0.10.9 on edge (inbox/private-store-move-error-message-2026-08-15.md, archived). SM296 named this as open and separable in its own 'Why the move failed there' section, and predicted the Hestia cause correctly; this is that separable piece, narrowed to how the failure is described rather than why it occurs. Message-and-comment scope only - the refusal behaviour is correct and stays."
---

# SM307 - a guess, reported as a diagnosis

## What was found

When content cannot be moved into the private store, `Lazysite::Private` reports
one of two causes. It determines neither. On the host measured, both were wrong,
and the correct diagnosis was available two layers away in the same codebase.

Three operations, one host, one docroot, minutes apart:

```datatable
columns: Operation | What it reported
widths: 5.6cm | X
bold: 1
tone: medium
---
`acl-set` on a folder holding content | cannot move a folder across filesystems
`acl-set` on a single file | cannot create the private store
WebDAV PUT at the site root | the target directory is not writable by the server. This is a server configuration fault, rather than a permission decision about your request - the operator must fix the directory permissions
---
```

The third is correct, specific and actionable. The first two describe the same
underlying condition as each other and as the third, and disagree with both. The
real fault was that `public_html` came back from a vhost rebuild without group
write, which is SM270 recurring; the private store is a sibling of the docroot,
so it inherits that condition exactly.

## The cause

`move_in` tries `rename`, and on failure reports without consulting `$!`:

```perl
return ( 1, undef ) if rename $src, $dst;

# Cross-device, or a rename the filesystem refused.
return ( 0, 'cannot move a folder across filesystems' ) if -d $src;
return ( 0, "copy failed: $!" ) unless copy( $src, $dst );
```

The comment is honest about the uncertainty - *"Cross-device, or a rename the
filesystem refused"*. The message below it drops the second half and states the
first as fact. `rename` sets `$!`; `EXDEV` is the cross-device case and
everything else is something else, so the distinction the comment already draws
is one line of code away from being made.

`move_out` carries the identical pair of lines, so un-protecting misreports the
same way in reverse.

## The second half: a folder never reaches the fallback

The guard order has a consequence beyond the message. Directories stop at the
`-d $src` line; only files continue to the copy fallback. The comment
introducing the sub describes that fallback as general:

> Across filesystems it fails with EXDEV, and the fallback copies, VERIFIES, and
> only then removes the original - so an interrupted copy leaves the content
> public and reports failure, rather than leaving it half-moved and unreadable.

Since a folder ACL is the normal way to protect a section, the fallback the
comment describes is unreachable in the common case, and a reader would conclude
the opposite.

## What the fix is not

The obvious repair is a recursive copy for directories. That would be wrong, and
the reason is in the same comment: `rename` is atomic within a filesystem and
moves a whole directory in one step, which is what makes protecting a section
safe - there is no window in which half a section is public. A recursive
copy-then-delete reintroduces exactly that window on the operation whose entire
purpose is to close it.

**Refusing a cross-device directory move is correct and stays.** What needs
fixing is the reporting around it.

## The fix

Report the errno
: branch on `$!{EXDEV}`. When it is genuinely cross-device and the source is a
  directory, the current message is accurate - say so plainly, naming both paths
  so the operator can see which two filesystems. When it is anything else, say
  what `$!` says.

Say the same thing for a file and a folder
: the single-file path fails earlier, at `_mkpath`, and produces a different
  message for one condition. Whatever the store cannot do, both paths describe it
  the same way.

Borrow the wording that already works
: the WebDAV layer distinguishes a server configuration fault from a permission
  decision about the request, and tells the operator which. That sentence is the
  model, and the ACL path has more need of it, because its failure leaves content
  served while the rule reads as applied.

Correct the comment
: state that the copy fallback covers files only, and that a directory is
  refused deliberately.

## Why a filing rather than a comment fix

**It contradicts a check that shipped alongside it.** SM296 added a `lazysite
check` report on whether the store exists, is writable, or could be created,
naming the directory, its owner and its mode. On a host where the docroot is not
writable, that check answers correctly while the ACL response blames the
filesystem layout. Two parts of one release give an operator different accounts
of one fault, and the wrong one is the one returned at the moment they act.

**The wrong diagnosis is expensive.** Mount layout is not something an operator
changes casually, and on the Hestia layout the store sits in the domain folder
beside `public_html`, which looks like the sort of place a separate mount could
plausibly be. The suggested cause is credible enough to be investigated, and the
real fix is a `chown`.

## Verification

- With the store unwritable for a reason other than EXDEV, a folder `acl-set`
  reports what `$!` says rather than naming filesystems. Fixture is cheap: make
  the store's parent unwritable, protect a folder, read the message.
- A single-file and a folder `acl-set` failing for one cause return descriptions
  that agree.
- `move_out` reports the same way as `move_in` for the same condition.
- The cross-device half needs two filesystems and is fair to leave to a
  maintainer fixture, the way the 507-with-a-reason path already is.

## Related

SM296 (the crash that hid this, and which left the cause open), SM286 (the flip
that introduced the move), SM283 (the exposure shape a failed move leaves
behind), SM270 (the docroot permission fault that produced it here).
