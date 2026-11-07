---
id: SM1412
title: "SM1412: owner_contact is retired"
subtitle: "Ruling 159 scraps SM1362's owner_contact (0.16.6), used only briefly on edge: its mail path and docs are removed, the key is ignored from 0.16.8, and lazysite check names a site that still sets it with the remedy, a notify handler on the form naming a group."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-07
raised-by: "release manager, rulings 157-159 (Q86, Q88-Q90)"
area: forms
status-note: "SHIPPED (PENDING) on n771: Notify::_mail_owner, its call and the submission.email built-ins removed; lazysite check report_retired_notify_keys WARNs on a set owner_contact with the remedy; /docs/forms and UPGRADE.md say the key is ignored from 0.16.8. t/unit/forms/78 (no handler named: nobody mailed, submission stored), t/tools/337."
---

# What was ruled

Ruling 157 found a single hard-coded owner address the wrong approach:
recipients should be accounts, with their addresses managed on the Users page,
chosen as a group. Ruling 158: no one is mailed by default - a form's
submissions go to file storage, because a site cannot be sure it can send mail
- and people are mailed only through a notify handler the form names, whose
recipients gain a group source (SM1413). Ruling 159: `owner_contact` (SM1362,
0.16.6) is scrapped. Its mail path and docs are removed, SM1403's Config door
and SM1406's route-report line are withdrawn before landing, and the check
names a site still setting it with the remedy.

# What was built

- `Lazysite::Notify`: `_mail_owner` and its call in `notify` are gone, with the
  `submission.email` and `submission.email.full` built-in templates written for
  it. Nothing reads `owner_contact`. SM485's opt-in account notices and an
  import's claim links still go through `send_mail`, in SM1405's shape.
- `lazysite check`: `report_retired_notify_keys` WARNs when
  `lazysite/notify.conf` sets `owner_contact` to a value, saying it is ignored
  and that no form notice is mailed to it, with the remedy - a notify handler on
  the Handlers page whose recipients name the people as a group
  (`[{"groups":["site-owners"]}]`), made one of the form's targets, then the
  line deleted. Silent when absent or empty; changes nothing, with or without
  `--fix`.
- Docs: `/docs/forms` loses "Telling the site's owner by email"; "How a form
  mails people" (SM1413) says how, and that the key is ignored. UPGRADE.md,
  under Unreleased (0.16.8): the key is ignored from 0.16.8, and what to do.
  SM1362's filing notes the retirement; its acknowledgement half stands.
- Tests: SM1362's `t/unit/forms/68` keeps its acknowledgement subtests (now
  `68-a-form-can-answer-the-submitter.t`) and loses the owner ones.

Tests: `t/unit/forms/78` - through the real form handler, with the Form SMTP
extension on and configured, a mock sendmail, an opted-in operator account, the
submission route set to email and `owner_contact` still set, a form whose only
target is `local-storage` mails nobody (on `notify: on` and `notify: full`),
stores its submission under `lazysite/forms/submissions` and puts its notice in
the bell. Fails with the owner path restored. `t/tools/337` - the check names
the key once as a WARN with the remedy, says nothing when it is absent, empty
or there is no `notify.conf`, and changes nothing. Fails with the check removed.
