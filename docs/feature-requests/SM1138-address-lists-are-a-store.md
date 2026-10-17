---
id: SM1138
title: "SM1138: address lists are a store, with one module that answers"
subtitle: "Slice A of SM1134: named allow and deny lists of addresses in lazysite/auth/address-lists.json, written by the users tool, kept on a manager page, and read through one module the later slices share. Nothing is enforced yet."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-17
raised-by: release manager, 2026-10-17 (SM1134)
area: auth
status-note: "SHIPPED on n634 (slice A of SM1134; slices B, C, D are SM1139-SM1141): lib/Lazysite/Auth/AddressLists.pm, tools/lazysite-users.pl address-list verbs, lib/Lazysite/Manager/AddressLists.pm, starter/manager/address-lists.md; t/unit/auth/63, t/unit/users/52, t/unit/manager/352, t/integration/266."
---

# What happened

SM1134, ruled in full on 2026-10-17 ("1. yes, 2. yes. 3. yes. 4. yes. 5. yes.
6. yes."): access limited by the visitor's address, with named lists that pages,
folders and groups apply. The first slice is the store and the one module
everything else uses; the later slices (SM1139 pages and folders, SM1140
groups, SM1141 the manager and the template test) only ask this module, so
the matching, the deny-wins rule and what happens when the store is broken
are written once.

# What shipped

## The module: `Lazysite::Auth::AddressLists`

POD is in the module. The API as built, which the later slices call and
nothing else:

    lists()                    { name => { kind, entries => [ {cidr, note} ],
                                 created_by, updated_by, updated, rejected } }
    list_names()               sorted names
    in_list($address, $name)   1 or 0
    decide($address, allow => [names], deny => [names])
                               ('allow'|'deny', $reason)
    client_address()           the visitor's address
    store_fault()              0 | 'unreadable' | 'undecodable' (last read)
    valid_name($name)          1 or 0
    check_entry($text)         ($canonical, '') or (undef, $reason)
    raw_lists()                the store as written, for the writer
    write_lists(\%lists)       atomic write; the users tool's only

Context: `$Lazysite::Auth::AddressLists::AUTH_DIR`, else
`$Lazysite::Auth::Settings::AUTH_DIR`, which every script that reads the other
auth stores already sets. The store is decoded once per change (keyed on path,
mtime and size, with the one-second guard `Auth::Acl` uses; a write clears it).

`decide` answers, in this order:

| Situation | Verdict | Reason |
| --- | --- | --- |
| nothing named | allow | `no-rules` |
| store unreadable or undecodable | deny | `store-fault` |
| address missing or not an address | deny | `no-address` |
| address in any named deny list | deny | `deny-list` (deny wins) |
| an allow list named, address in none of them | deny | `not-allowed` |
| address in a named allow list | allow | `allow-list` |
| only deny lists named, no match | allow | `not-denied` |

**Address matching** is `Lazysite::Util`'s (`parse_trusted_proxies` and its range
matcher), the code `trusted_proxies` and `auth_proxy_trusted_from` use, so an
address means the same everywhere. IPv4 and IPv6, same family only. **The
IPv4-mapped form (`::ffff:203.0.113.5`) is an IPv6 address to that matcher and
is in no IPv4 range**; this is consistent with `trusted_proxies`, it fails
closed for an allow list and open for a deny list, and an operator whose front
end hands over mapped addresses lists them as IPv6 entries
(`::ffff:203.0.113.0/120`, which `check_entry` accepts). A prefix of 0
(`0.0.0.0/0`, `::/0`) is refused, as `parse_trusted_proxies` refuses it.

**Fails closed, as SM1024 ruled** for `groups-settings.json` and `acls.json`: a
store that exists and will not open, or opens and does not decode to an object,
is unknown and not empty. `decide` denies whenever a rule names a list, an
allow list or a deny list alike (a deny list read as empty would open a door
the working file shuts), logs once, and `store_fault()` says which fault. An
absent store is an answer: no lists. The writer refuses to write over a
faulted store (SM785's rule), so one bad read cannot erase the other lists.

**Unknown names.** A name no list carries, and a list named in the wrong slot
(a deny-kind list under `allow`), contributes no addresses and is logged once
per process. Under `allow` it still counts as "an allow list is present", so a
rule naming only a deleted allow list admits nobody rather than becoming
public; under `deny` it blocks nobody. A list with a hand-edited entry that is
not an address keeps its good entries and names the rest in `rejected`.

**`client_address()`** is `Lazysite::Util::request_address` with the
instance's `trusted_proxies`: `X-Forwarded-For` is believed only from a listed
proxy, the rightmost untrusted hop, never read directly.

## Writes: the users tool

`address-list-set NAME --kind allow|deny --entry CIDR[=note] ...`,
`address-list-delete NAME`, `address-lists [NAME]`; the same over `--api`
(`address-list-set`, `address-list-delete`, `address-lists-get`).

- Names are `[a-z0-9_-]{1,64}`. Every entry is validated before anything is
  written (one address or one CIDR; a refusal names the entry and changes
  nothing); duplicates, a note over 200 characters, more than 1000 entries
  and more than 200 lists are refused.
- The entries given are the whole list. With no entries given an existing
  list keeps them (so a kind can change alone); an empty list clears them.
- Every change is audited with who, the list and what changed (`created kind
  allow +203.0.113.0/24,+198.51.100.7`, `-...`, `note ...`, `kind
  allow->deny`, `deleted (2 entries, deny)`). From the shell the tool writes
  the row; from the manager the calling web surface writes it
  (`address-list-set` / `address-list-delete`, target `address list NAME`),
  as for every other store (one row per operation).

**Who may write: the operator, and not a `manage_users` holder.** The
consistent choice by the SM991 rules: group settings are bounded by the
conferring ceiling ("holds AND may grant"), but a list confers no capability,
so that ceiling has no shape here; and a list decides who reaches a page, a
group's grants and (slice D) the manager itself, so whoever edits one can lock
the operator out or open a door from anywhere. The operator group is the
operator's alone; this store is held to the same line. The users tool refuses
a present actor who is not an operator (`forbidden`) and the manager module
asks first. An unsecured site (no group grants manager access) has no
operator to ask, as for every verb in the tool. **Reading is `manage_users`.**

## Manager page, control API, MCP

- **Access -> Address lists** (`/manager/address-lists`): the lists with their
  entries and notes; New, Edit (name, kind, entry rows with notes) and Delete
  for the operator, the lists alone for anyone else. In the menu, the command
  palette and the start-page table; no new CSS classes (lint 96); every
  control declares its impact (lint 109).
- **Control API**: `address-lists` (manage_users, read-only token door).
  `address-list-set` and `address-list-delete` are cookie-only: the operator is
  never a token (SM991). `name` is required on both writes.
- **MCP**: `list_address_lists` (manage_users), the read twin on the same
  function. There is no write tool, and the cookie-only reason is declared on
  the actions.
- A **domain-confined caller** (every token, every MCP grant: SM648) is shown
  the names, the kinds and the entry counts, which is what writing a rule that
  names a list needs, and not the entries or their notes: the lists are the
  instance's and their entries are the site's own network addresses (SM976 R1).

Counts moved: t/lint/98 (122 actions reachable with a token, 69 cookie-only),
t/lint/14 (`address-lists` is a reviewed read).

# What the later slices must know

- Deleting a list that a rule names leaves the rule naming an unknown list;
  slices B-D should refuse the delete while a rule names it, or `lazysite
  check` should warn. This slice has nothing that names a list.
- `decide` reads the store for each call; a render path that asks several
  times in one request gets the memo, not a re-decode.
- The processor carries pinned copies of some `Util` code (ADR 0001); slice B,
  which enforces in the processor, must decide whether it loads this module or
  carries a pinned copy, and pin it with a test as the others are.

# Tests

- t/unit/auth/63: matching (v4, v6, CIDR edges, mapped form), entry
  validation, deny wins, unknown and misplaced names, fail-closed on
  truncated, array, empty, string and unreadable stores, the memo, the
  writer, `client_address` behind a trusted proxy.
- t/unit/users/52: the verbs (CLI and API), validation, names, the operator
  rule, the audit rows, the refusal to write over a broken store.
- t/integration/266: the real manager API, control API and MCP: the operator
  writes, a `manage_users` holder reads and is refused, a token and an MCP
  grant see no addresses and cannot write, the audit rows, a broken store.
- t/unit/manager/352: the page's JavaScript in node.
