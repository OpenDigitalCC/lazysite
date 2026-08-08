---
title: "SM235 - A WebDAV write to an unwritable target reports 500"
subtitle: "An environment fault and a genuine server error are the same response, so an agent cannot tell 'this server cannot store it' from 'your request is not allowed' and probes to find out."
brand: plain
status: shipped
status-note: "IMPLEMENTED in the 0.10.2 edge line (2026-08-08, commit 8e10865). Reported by the sjm-claude-code site agent 2026-08-07, observed on sovereigncomputing.org (0.10.0) with the operator's knowledge. Small, and it cost real diagnosis time plus a wrong report to the operator. Verified in lazysite-dav.pl."
---

# SM235 - an unwritable target reports 500

## Why

Every PUT to the docroot root returned 500 and wrote nothing, while PUTs into
subdirectories under the same grant succeeded:

```
PUT /apple-touch-icon.png        -> 500   (nothing written)
PUT /assets/apple-touch-icon.png -> 201   (fine)
```

The cause was filesystem permissions: the docroot directory itself was not
writable by the server user although its subdirectories were. Once corrected, an
identical PUT returned 201 with no other change - same token, same scope, same
client.

A 500 says the server broke. It gives a client no way to separate three different
situations, which call for three different responses:

Scope refusal
: the path is denied to this grant, and the client should stop asking.

Environment fault
: the target directory is not writable, and an operator must act.

Genuine server error
: something unexpected happened and is worth reporting.

The reporting agent did the reasonable thing and probed to characterise the
failure - varying the file type, then the directory - work that was unnecessary
only because the response would not say what was wrong. It also drew the wrong
conclusion first, reporting to the operator that root writes were denied by
policy, before a retest disproved it. A misleading error is worse than a terse
one.

## What is true today

`lazysite-dav.pl` fails a write in three places, all with a bare 500 and a
two-word body:

```perl
open my $out, '>:raw', $tmp
    or return send_status( 500, body => "Cannot write\n" );
...
unless ( close $out )  { ...  send_status( 500, body => "Write failed\n" ) }
unless ( rename $tmp, $r->{abs} ) { ... send_status( 500, body => "Rename failed\n" ) }
```

The first is the one that fired: `open` on `$r->{abs}.tmp.$$` fails because its
parent directory is not writable. `$!` is available and is discarded.

Note that 507 is already in the module's status-phrase table
(`507 => 'Insufficient Storage'`), so the vocabulary exists.

Also `MKCOL` (`send_status( 500, body => "Cannot create\n" )`) and `DELETE`
(`"Delete failed"`) have the same shape and should move together.

## What to change

### Distinguish the environment fault

Before returning 500 on a write failure, test whether the target's parent
directory is writable. When it is not, return a distinct status with a reason
that names the operation and the condition:

```
507 Insufficient Storage
{ "error": "target directory is not writable by the server" }
```

507 or a 403 with an explanatory body are both acceptable to the reporter;
anything that separates "your request is not allowed" from "this server cannot
currently store it" is enough. 507 is the better fit because the request is
valid and the server is at fault, which is exactly what 403 would deny.

### Say what failed, not where

Include the failing operation and the reason in the body, consistent with how
scope denials already report. Do not include the filesystem path - a client has
no use for it and it discloses the layout.

### Surface it before an agent trips over it

An unwritable docroot is an installation fault that will affect every write. It
belongs in whatever health reporting exists rather than being discovered one 500
at a time. This is the natural consumer of the status work in SM222, and if that
is not built, an `audit_site` check is the cheaper alternative.

## Verification

- A PUT whose parent directory is unwritable returns 507 (not 500) with a reason
  naming the condition.
- A PUT that fails for any other reason still returns 500.
- The response body names the operation and the reason and contains no
  filesystem path.
- MKCOL and DELETE report the same way.
- Scope refusals are unchanged.

## Not in scope

- Attempting to fix permissions. The server reports; the operator acts.
- Any change to how scope refusal is decided or reported.
