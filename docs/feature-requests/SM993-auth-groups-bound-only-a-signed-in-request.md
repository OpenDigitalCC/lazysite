---
id: SM993
title: "SM993: auth_groups bound only a signed-in request, and auth: manager guarded no content page"
subtitle: "A page naming auth_groups went to the public unless it also said auth: required, and auth: manager on a content page enforced nothing. auth_groups now means signed in, and auth: manager outside the manager refuses everyone."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: SM980's two findings, filed there for a ruling (WORK-PLAN-0153 open question Q17b)
area: security
status-note: "SHIPPED (PENDING): ruled 2026-10-12, Fix both as recommended. auth_groups makes a page signed-in whatever auth: says (a paid page's list stays its payment bypass); auth: manager outside the manager path is unreadable - 403 to everyone, logged, listed nowhere, reported by lazysite validate. t/integration/130."
---

# What was wrong

Found while building [[SM980]] and filed for a ruling:

- **Finding 3.** `check_auth` (`lazysite-processor/auth.pm`) returned before its
  group test for `auth: none` - the default - and, for an anonymous visitor,
  for `auth: optional`. So `auth_groups: [readers]` with no `auth:` served the
  page to everyone, signed in or not; with `auth: optional` an anonymous
  visitor got the page a signed-in non-member was refused (403). The scan and
  the registries (`sources.pm`, `_scan_hidden`, `_registry_hidden`) took the
  same level and listed such a page. `frontmatter.md` and `auth.md` said the
  user "must be signed in and in at least one" group.
- **Finding 4.** `auth: manager` is enforced by the manager path's own gate
  (`handle_manager_path`); `check_auth` reads it as a level it does not act on,
  so on any other page it enforced nothing - 200 with the body to an anonymous
  visitor.

Measured on n385: 28 assertions of t/integration/130 fail
(`tmp/sec-evidence/sm993-t130.base.out`).

# The ruling

Release manager, 2026-10-12, Findings 3+4, "Fix both as recommended":
auth_groups always implies sign-in (auth: optional + auth_groups -> anonymous
refused, as auth: required); `auth: manager` on a content page (outside the
manager path) is unreadable -> refuses everyone, logged, and `lazysite
validate` reports it (extend SM980's single reader and its marked copy; lint
220 keeps the copies equal). Test + sabotage.

# The fix

- **auth_groups means signed in.** `check_auth` reads a page naming groups as
  `auth: required` - an anonymous visitor is sent to sign in, a non-member is
  refused 403 - outside the manager path. The scan and registry gates do the
  same, so such a page is in no anonymous scan and in no registry.
- **Except on a paid page.** `docs/payment` documents `auth_groups` on a
  `payment: required` page as the list of members who skip payment, "all other
  users (including unauthenticated) see the 402 payment page", and
  `check_payment` implements it. Reading that list as a sign-in would refuse
  the people the page exists to charge, so a paid page keeps its meaning:
  members free, everyone else 402. `peek_auth` now carries `payment` for this.
  Nothing a caller could reach widens: a paid page served before exactly what
  it serves now. Recorded for the release manager in case the ruling meant
  paid pages too.
- **auth: manager outside the manager path is unreadable.** The single reader,
  `_access_keys_read($fm, $where)` (front-matter.pm), and its marked copy
  `Lazysite::Validate::read_access_keys`, take where the page is - `manager`,
  `content`, or undef when the caller does not know - and answer `auth:
  manager` on a content page as unreadable, with the reason. The gate's peek
  is keyed by file and does not know; `check_auth`, which has the URI, asks the
  reader again with `content` for a page outside the manager path, and refuses
  it as SM980 refuses any unreadable key: 403 to everyone, a WARN line naming
  the key and the reason. The scan and registry gates leave an `auth: manager`
  page out of every listing.
- **lazysite validate** works out where the page is (`_page_place`: under the
  docroot by its path there, else by a `manager` directory in the path; the
  site's `manager_path` when the docroot is given) and reports the key as an
  `access-key-unreadable` issue. Given only text (validate_page with no path)
  it cannot tell and reads the key as the gate's peek does.
- **Lint 220** runs both readers over every text with each of the three
  places, and the seeded generator with a random one.

## The shipped pages

WORK-PLAN-0153 Q17b said no shipped page used `auth: manager` outside
`/manager/`. Three did: `starter/docs/ai-connector-setup.md`,
`ai-connector-tools.md` and `onboarding-brief-template.md`, served to anyone
until now. Under the ruling as written they would answer 403 to everyone,
operator included, so they now say `auth: required` - the nearest level the
engine enforces, and narrower than what they had. t/integration/130 asserts no
shipped content page carries `auth: manager`. A site's own copies of these
pages, if an upgrade does not replace them, answer 403 until they are changed;
`lazysite validate` names them.

# Behaviour changes

- A page naming `auth_groups` with `auth: none`, `optional` or no `auth:` sends
  an anonymous visitor to sign in (was: served) and refuses a signed-in
  non-member (with `none`, was: served). It leaves anonymous scans and the
  registries. A paid page is unchanged.
- A content page saying `auth: manager` answers 403 to everyone and is in no
  listing (was: served to everyone); `lazysite validate` reports it.
- Three shipped docs pages say `auth: required` instead of `auth: manager`.

# Evidence

t/integration/130 (28 assertions fail on n385, all pass after), t/lint/220
(three places per text). t/integration/16's `auth: manager` page moved under the
manager path (outside it the page is now refused, which is the point), and
t/unit/processor/81 carries the group name on a members page read by a member,
so its public page stays cacheable. Sabotage: 11 cases
(`tmp/sec-evidence/sm993-sab*.out`) - each half of the gate, the paid-page
exception and the payment key it reads, both readers, the validator's place,
the scan and the registry - each bit.
