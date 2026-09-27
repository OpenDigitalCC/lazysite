---
id: SM873
title: "SM873: a refusal kind assembled at run time can never be mapped to a status, and the store-inspection family is assembled at run time"
subtitle: "`lib/Lazysite/Data/Tables.pm:275` emits `kind => 'store_' . $why->{reason}`. SM670's map is keyed by literal name, so no member of that family can ever match it and every one answers 400 Bad Request - including the ones that are server-side faults and should be 500. SM872's lint can only see the literal stem `store_`, so it exempts the family rather than pretending to cover it."
brand: plain
status: shipped
status-note: "SHIPPED 2026-09-27 for 0.15.0. ONE LITERAL KIND, NOT A FAMILY. The five reasons store_diagnosis can return - missing_module, no_store, unreadable, directory_not_writable, unknown - are all the same class: this host failing to read its own state. So enumerating them as five kinds would have bought nothing, and Data::Tables now emits the single literal `store-uninspectable`, mapped to 500 in %REFUSAL_STATUS, with `reason` carried in a field of its own for a caller that wants to tell 'install the driver' from 'make the directory writable'. `reason` is not a kind and no status is looked up by it, which is why it may be built at run time where a kind may not. THE 404 QUESTION DOES NOT ARISE: this filing wondered whether an absent store should be 404, and an absent store never reaches the refusal at all - read_rows answers it as `pending_schema`, an ordinary state, above the diagnosis. t/lint/139's `%PREFIX_ONLY` exemption is GONE rather than replaced, so the family is checked like every other kind. And t/lint/150 is the part that outlives the fix: it refuses four assembly shapes (a literal extended by concatenation, an interpolating double-quoted string, two values concatenated, a string-building function) while allowing a pass-through parameter, a ternary of literals, and the unrelated `kind` fields a backup, a layout and a snapshot each carry - so it closes the class without flagging the three legitimate uses. Both gates sabotage-proved by restoring the old line: lint 150 fails 'no refusal kind is assembled at run time', lint 139 fails \"'store_' has a decided status\". t/unit/data/11 asserts the literal kind, the reason field and the 500."
raised: 2026-09-12
raised-by: dev (found by SM872's kind/status audit)
area: control-api, data
---

# What was found

SM872 added `t/lint/139`, which requires every `kind => '...'` in the tree to
have a decided HTTP status. One kind cannot satisfy it, because it is not a
kind:

```perl
# lib/Lazysite/Data/Tables.pm:275
return refusal(
    "table '$name': the data store could not be inspected. " . $why->{detail},
    table  => $name,
    kind   => 'store_' . $why->{reason},
    detail => $why->{detail},
);
```

`$why->{reason}` is decided at run time, so this single line emits a **family**
of kinds. `%REFUSAL_STATUS` is keyed by literal name and `refusal_status`
defaults to `400 Bad Request` for anything it does not know, so **every member
of the family answers 400** - and no static check can enumerate them.

# Why 400 is the wrong answer here

The message says the data store *could not be inspected*. That is not the
caller's request being malformed; it is the server failing to read its own
state. SM670 already maps that class:

```perl
( map { $_ => '500 Internal Server Error' }
    qw(render-failed snapshot-failed no-cgi-headers empty-render) ),
```

`store_*` belongs with those, not with `invalid` and `validation`. A client
retrying a 400 will keep sending the same request and keep being told it is
malformed, when what is wrong is at the other end.

**But not necessarily all of them.** `$why->{reason}` is not enumerated
anywhere, and some reasons may genuinely be the caller's fault. Establishing
which is which is the work, and it is why this is filed rather than folded into
SM872's one-line map change.

# The shape of the fix

Two parts, and the second matters more than the first.

1. **Enumerate the reasons.** Find every producer of `$why->{reason}` and give
   each a decided status - most likely 500, possibly 404 for "the store is not
   there at all".
2. **Stop building kinds by concatenation.** A `kind` is a contract clients read
   and a key the status map looks up. Assembling one from a runtime value means
   no static check can ever verify the set, which is how this went unnoticed
   through SM670's own review. Whatever the reasons turn out to be, they should
   be literal kinds at their emit sites - `store_unreadable`, `store_corrupt` -
   so the lint can see them.

A lint that every `kind =>` is a literal string, not an expression, would close
the class rather than this instance. That is the same argument SM872 made about
the silent 400 default, one level up.

# What is in place meanwhile

`t/lint/139` exempts the literal stem `store_` explicitly, with the reason
recorded at the exemption rather than in a commit message:

```perl
my %PREFIX_ONLY = ( 'store_' => 1 );
```

So the family is **known-unmapped rather than silently unmapped**, which is the
distinction SM872 exists to draw. Removing that exemption is how this filing
gets closed.

# Not urgent

No caller has reported it, the refusal body already carries `detail` naming what
went wrong, and changing a status is a compatibility change that wants doing
once, deliberately, with the reasons enumerated. It should not go into 0.14.0
alongside SM872's low-risk set.

# Related

[[SM872]] (the audit that found it, and the lint that exempts it), [[SM670]]
(the status map and its silent default),
[[feedback_a_declaration_the_code_ignores]] (a contract nothing can check is a
contract nothing keeps).
