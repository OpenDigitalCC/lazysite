---
id: SM1173
title: "SM1173: a read has room for a scanner (reads default to 2,000 and 20,000 an hour)"
subtitle: "An Odoo binding's default rate caps depend on whether it reads or writes: reads 2,000 per caller and 20,000 per binding, writes keep 20 and 200. A binding's own caps still win, either way."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-18
raised-by: lazysite-sites agent, OOM Lab stock and picking apps (inbox, L-14)
area: odoo
status-note: "SHIPPED on n662 (base n661): Lazysite::Odoo::Binding::rate_limits picks the default from the operation; the manager form no longer saves a default into the binding; guide: starter/docs/odoo.md, Rate caps: reads and writes; test t/unit/odoo/60."
---

# What happened

OOM Lab, stock and picking apps, L-14 (lazysite-sites agent, 2026-10-17):

> The default caps (20 per caller per hour, 200 per binding) stop a scanning
> app within minutes - the twentieth scan of a picking hit it, and the shared
> header read on every page blocked a session. A scanning page needs thousands
> an hour. Either a much higher default for reads, or the binding guide saying
> so prominently.

Ruled by the release manager, 2026-10-18:

> Higher read defaults: reads default to 2,000 per caller per hour and 20,000
> per binding; writes keep 20 / 200. A binding can still set its own caps either
> way. The guide says so prominently.

# What shipped

- **The default follows the operation.** The binding parser records which caps
  the binding said (`rate_set`); at each call `rate_limits` takes the binding's
  own number where it said one, else 2,000 / 20,000 when the operation does not
  write (`$class->writes`, the same answer that decides a plan or an apply) and
  20 / 200 when it does. The cap is still taken before the call, per caller and
  per binding, as before.
- **A binding's own cap.** Unchanged in rule: any whole number, no ceiling, in
  either direction, for a read and for a write (so a write binding may be given
  more than 20, and a read binding fewer than 2,000). `0` refuses every call.
- **The manager form.** The two *Cap* fields had a schema default (20, 200),
  which the form displayed and the save then stored in the binding - that would
  have pinned every read binding made in the manager to the write numbers. The
  default is removed; the fields are empty by default and their hint says
  "Leave empty for the default: 2000 for a read, 20 for a write...".
- **The guide.** `starter/docs/odoo.md` has a section *Rate caps: reads and
  writes* with the defaults in a table, that a scanning page is a read, and how
  to set a binding's own caps.
- **Bindings saved before.** A binding saved earlier through the manager holds
  `rate_per_visitor_hour: 20` and `rate_per_hour: 200` as its own caps, and
  keeps them (it said them). Clear the two fields to take the read default.

Test: t/unit/odoo/60-a-read-has-room-for-a-scanner.t drives the rolling record
directly: a read allows the 21st call and refuses at 2,001 (caller) and 20,001
(binding); a write refuses the 21st and the 201st; a binding's own caps win for
both, above and below the defaults; the saved binding stores no caps.
