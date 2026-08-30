---
title: "SM642: an account is shown by its login everywhere, and a group's display name cannot be edited at all"
subtitle: "Operator, 2026-08-27: 'add Display name which is displayed in place of the actual login if it is set... groups now seem to have a display name but this isn't editable. list users/list groups should show display name and login name after in brackets'"
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT. Accounts gain `display_name` - one line, capped at 64, empty clears - surfaced on the settings the Users page reads, with an editor beside the account note. The Users and Groups lists render \"Display Name (login)\" and \"Label (group)\". DISPLAY ONLY, and asserted as such: two accounts may share a display name, and nothing resolves an account by one. That is the property the gradual rollout rests on - a surface that has not adopted it is plainer, never wrong. THE LOGIN IS NEVER HIDDEN from the person administering access: they are deciding who may do what, and the name that appears in the audit trail must be in front of them while they decide. An account with no display name shows the login alone rather than an empty bracket. THE GROUP HALF WAS A UI GAP, NOT A BACKEND ONE - and the original filing was wrong about that. group-settings-set has accepted `label` and `description` since SM195; the first cut of this work added a second, unreachable branch for them before that was noticed. The fix was one editor on the Groups page, not a backend change. Three sabotages, all fail - including hiding the login behind the display name. NOT DONE: the other surfaces. The audit trail, the Sessions page and the connector panels still show logins, deliberately - the operator asked for a gradual rollout and this is the store, the two lists and the editors."
---

# What each half is missing

| | Accounts | Groups |
|---|---|---|
| Has a display name | no | yes (`label`) |
| Shown anywhere | - | Groups page, Users page |
| Settable | - | **no** |

The group half is the odd one. `_default_group_seed` gives every seeded group
a `label` and a `description`, both shown on the Groups and Users pages, and
`cmd_group_settings_set` ends:

    my %ok_key = map { $_ => 1 } ( @CAP_KEYS, 'manager' );
    return { ok => 0, error => "unknown group setting: " . ( $key // '' ) }
        unless defined $key && $ok_key{$key};

`label` is not in that set, and neither is `description`. So the seeded groups
display a name the operator cannot edit, and a group the operator creates
displays its own bare name for ever.

# Display only, and why that is the whole point

The login is the identity. It is the audit trail's actor, the subject of a
grant, the name a credential is minted against, the value the API takes and
returns. None of that changes. A display name is a label rendered over the top
of it, resolved at the point of DISPLAY and nowhere else - so it can be added
to one surface at a time without any surface that has not adopted it being
wrong, only plainer.

That is also what makes the rollout safe to do gradually, as the operator
asked. A half-adopted identity would be a defect; a half-adopted label is
merely uneven.

# The format the operator set

`Display Name (login)` in both lists. The login is never hidden from the person
administering access - somebody reading the Users page is deciding who may do
what, and the name that appears in the audit trail must be in front of them
while they decide. Where no display name is set, the row shows the login alone
rather than an empty bracket.

# What this needs

- A `display_name` key on the account settings store, alongside `comment` and
  `email`, with the same single-line, length-capped, empty-clears treatment.
- `label` and `description` accepted by `cmd_group_settings_set`, with the same
  sanitising - and no capability meaning whatsoever, so a delegate who may
  rename a group gains nothing by it.
- The Users and Groups lists rendering `Display Name (login)`.
- An editor for each, where the operator already edits everything else about
  that account or group.

# What this must not do

It must not become an identity. Nothing may look a user up by display name,
two accounts may hold the same one, and no grant, credential or audit entry
may reference it. If any of those changed, "display only" would stop being
true and the gradual rollout would stop being safe.
