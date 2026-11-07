---
id: SM1403
title: "SM1403: an operator door for owner_contact"
subtitle: "Triage T-95: owner_contact lives in lazysite/notify.conf and had no manager page, API key or MCP tool. It is now an ordinary setting on the Site configuration page and in config-read/config-set under manage_config, validated as one address or empty."
brand: plain
standard-margins: true
status: withdrawn
raised: 2026-11-07
raised-by: "0.16.7 edge triage, T-95"
area: manager
status-note: "WITHDRAWN before landing (ruling 159): owner_contact is retired by SM1412, so it gets no operator door. Built on n771 (commit 4e4afbf85) and dropped from the branch; nothing of it ships. A form mails people through a notify handler naming a group (SM1413)."
---

> Withdrawn before landing by ruling 159. The text below records what was built on
> the branch and then dropped; none of it ships.

# What happened

SM1362 (0.16.6) made `owner_contact:` in `lazysite/notify.conf` the one address
each form's submission notice is also mailed to. The only way to set it was to
write the file: `config-read` did not carry it, `config-set` did not take it,
and the Config page had no field for it. An operator with `manage_config` and
no shell could not name the site's owner.

# What was built

- `Manager::Config`: `%NOTIFY_KEY` names the Config-page settings that live in
  `notify.conf` (`owner_contact`). `config-read` reads them from `notify.conf`
  (a line of the same name in `lazysite.conf` is ignored); `config-set` takes
  `owner_contact` through the same allow-list, clearable like the other keys
  whose empty means "none", and writes it with `_write_notify_key`: under a
  lock, read-modify-write of the one line, every other line and comment kept,
  temp-and-rename through the manager's checked writer, and recorded in the
  site's history as `lazysite.conf`'s writer records. An empty value removes
  the line, which is what `Lazysite::Notify` reads as unset.
- The value is one email address or empty, checked by the rule the send applies
  (`Lazysite::Mail::one_address`), so a value the owner mail would refuse at
  send time is refused at the door and not stored.
- The Config page (`starter/manager/config.md`, `SITE_SCHEMA`) offers it under
  *Notices*; `t/lint/18` holds the page, `config-read` and `config-set`
  together, as for every other key. MCP reaches it as it reaches every
  `config-set` key.
- `/docs/forms` names the page and the key beside the file.

Test: `t/unit/manager/478` - `config-read` carries the address `notify.conf`
holds and not a decoy in `lazysite.conf`; `config-set` writes it there keeping
the other line and a comment, with `lazysite.conf` untouched, and `Notify`'s
own reader sees it; two addresses, a non-address and a line break are refused
with nothing written; empty clears it; the page offers it. Fails with the
module and the page reverted.
