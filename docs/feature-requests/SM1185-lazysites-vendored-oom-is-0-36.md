---
id: SM1185
title: "SM1185: lazysite's vendored OOM is 0.36"
subtitle: "The pinned OOM snapshot moves from 0.34 to 0.36 (acting for a person, the shop pack, the light rows check); two things in lazysite's tests broke and are fixed."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-19
raised-by: "OOM agent, inbox 2026-10-19-oom-0.36-acting-shop-rows.md (and the advisory notes for 0.35); release manager, 2026-10-19 (wave 2)"
area: odoo
status-note: "SHIPPED on n672 (first commit): t/vendor/oom is OOM 8e4f2c3 (Package 0.36) by tools/vendor-oom.sh with both 0.36 debs. SM747's filed spec is re-filed (section 9 gained rows; new hash). Two test breakages fixed: the host's installed packs were read by the suite (OdooTest), and a fixture pack named with a hyphen (t/unit/odoo/71). Nothing in lazysite's code needed a change."
---

# What happened

OOM 0.36 is built (inbox 2026-10-19-oom-0.36-acting-shop-rows.md): "an
operation declared `acts_for` reads as the person and writes through a service
credential", the shop pack (`packs/shop` 1.0.0, twelve `shop.*` operations),
`Odoo::Ops::Rows->check` ("applies the same rules and throws the same errors as
`Odoo::Ops::Operation->check_rows`") and `failed_changes` carrying a refusal's
`code`. The advisory notes for 0.35 said it renamed `crm-page` to `crm_page` and
`stock.link-stranded` to `stock.link_stranded` and "breaks lazysite's Odoo
tests".

# What shipped

- **`t/vendor/oom` is OOM 8e4f2c3, "Package 0.36"**, taken with
  `tools/vendor-oom.sh --deb libodoo-oom-perl_0.36_all.deb --deb
  odoo-oom-tools_0.36_all.deb 8e4f2c3`; library, spec, `Odoo/Accounts.pm`,
  `Odoo/Tools/` and `bin/oomd` were checked against the debs.
- **SM747's filed spec is re-filed.** MAPPER-SPEC.md changed since 0.34 (probe
  rows in section 9: the DMS route, the shop and lab-36 probes, the pack rename
  to `crm_page`), so sections 7 to 10 and the Open list are re-copied and the
  recorded sha256 is `a649f183...7510` (lint 207).
- **What broke, and the fix, each in lazysite's tests:**
  - **The suite read the host's installed packs.** With no `pack_dirs` and no
    `ODOO_OOM_PACK_DIRS`, OOM's registry loads `/usr/share/odoo-oom/packs`. Once
    `odoo-oom-packs` 0.36 was installed on the host, its `shop` pack claimed
    `shop.basket` beside lazysite's test operation of the same name ("operation
    'shop.basket' claimed by both LazysiteTest::OdooOps::Basket and
    Odoo::Pack::Shop::Basket") and 40 tests in `t/unit/odoo/` failed. That is a
    gate that depends on what is installed. `t/lib/OdooTest.pm` now points
    `ODOO_OOM_PACK_DIRS` at a directory that does not exist, unless the caller
    set it or `LAZYSITE_OOM_LIB` names the host's library
    (`tools/ext-compat.sh`). A test that wants a pack passes `pack_dirs`, as 56
    and 71 do. Tests 56 and 72, which asserted that variable is unset, now
    assert it is back to the value `OdooTest` gave it.
  - **A hyphenated fixture pack.** `t/unit/odoo/71` made a pack named
    `shop-page`; since 0.35 a pack name is lower case letters, digits and `_`, and
    OOM refuses it. The fixture is `shop_page` (`shop_page.names`). lazysite's own
    operation-name rule (SM1178) still admits a hyphen inside a segment, which is
    harmless, and the test's name-rule subtest still holds.
- **Not changed:** the code in `lib/` needed no change. `t/unit/odoo/` and
  `t/unit/daemon/` pass whole; lints 207, 261, 262 pass.
- **Not used from 0.36 by this filing:** acting for a person and the shop pack
  (payment is on hold). The light rows check is SM1198.
