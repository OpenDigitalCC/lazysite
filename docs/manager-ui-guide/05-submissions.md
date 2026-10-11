---
title: "Submissions"
brand: plain
---

# Submissions

Governing capability: read_submissions; the menu count also needs notifications.

What visitors have sent through the site's forms, one click from the menu: it is
the first entry of the first group, because it is what an operator opens on most
visits (SM957). Every form is listed with what it has kept; a form's rows show
newest first, with the quarantine filter, and each row opens that one submission
on its own page - the page a submission notice links to.

The entry carries a count: this account's unread submission notices, from the
bell's own read state. Opening the page marks nothing read. Following a notice
(from the bell) or a row's **Open** marks that notice read, **Mark all read** in
the bell clears the lot, and the count moves with each.

## Read what was submitted

Where
: Site -> Submissions

Do
: Submit two forms on the public site, a minute apart. Open Submissions, choose
  the form, and open the newer row. Then open a second form from the list.

Expect
: Every form is listed with its count, and a form that keeps nothing says "none
  kept". The rows are newest first. **Open** shows that one submission. The count
  on the menu entry falls by one when a row's notice is followed, and not when the
  page is merely opened. Each form's **Handlers** opens the Handlers page with that
  form's card open.

Negative
: Without `read_submissions` the entry is shown locked, with the reason and - for
  an account that can grant it - a link to the Groups page; it is not a link to a
  page that would refuse. Without `notifications` the entry carries no count.

## Quarantine and approval

Where
: Site -> Submissions -> a form with quarantined rows

Do
: Use **Quarantine only**, then **Confirm** a row; on a registration form
  (`account_email:`) **Approve** an open row.

Expect
: Quarantined rows show their reason as text beside the tag. Confirm clears the
  flag and keeps the row; Approve creates the account and says how to set its
  password. **Download CSV** and **Delete selected** act on the loaded form.

Negative
: Confirm and Delete need `manage_forms` as well as `read_submissions`; Approve
  needs `approve_accounts` (or `manage_users`). Without them the server refuses
  and the page says so. An account holding `approve_accounts` alone sees only the
  forms that declare `account_email:` here, and is refused any other form's rows.

## The old address

Where
: `/manager/plugin-config?submissions=<store>`, a bookmark from before SM957

Do
: Open it.

Expect
: It redirects to Submissions with that store's forms listed. A file handler's
  **Submissions** on the Handlers page links to the same place.

Negative
: A store address that is not a `/`-bounded path, or that contains `..`, is not
  read; the page says so and lists every form instead.
