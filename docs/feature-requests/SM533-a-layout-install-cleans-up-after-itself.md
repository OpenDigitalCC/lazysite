---
title: "SM533: a layout install cleans up after itself"
subtitle: "Every manifest install leaves its downloaded packages in /tmp because the cleaner matches a different directory prefix."
brand: plain
standard-margins: true
status: candidate
status-note: "FOUND 2026-08-25 by the themes structural review, PROVEN by probe tmp/tl-probe-tmp-leak.pl; class: operability; recommended timing: 0.10.33. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. _cleanup_tmp_layouts (Manager/Layouts.pm 397-400) only removes paths matching /tmp/lazysite-layouts-<digits>; action_layout_install works in /tmp/lazysite-layout-install-$$ (1007) and hands that path to the cleaner at 1014, 1020 and 1049. The probe shows the directory STILL THERE after cleanup. Every install_layout call over the API or MCP leaves the downloaded packages in /tmp. Fix: widen the guard, or give the cleaner the prefix parameter the review's TL-13 proposes."
---

# The finding

`_cleanup_tmp_layouts` (`Manager/Layouts.pm 397-400`) only removes
`^/tmp/lazysite-layouts-\d+$`; `action_layout_install` works in
`/tmp/lazysite-layout-install-$$` (`Manager/Layouts.pm 1007`)
and hands it to that cleaner at `1014`, `1020` and `1049`. Probe:
`/tmp/lazysite-layout-install-<pid> after cleanup: STILL THERE`. Every
`install_layout` call over the API or MCP leaves the downloaded packages
in /tmp.

# Why it matters

Operability: a working directory that is never removed grows /tmp by one
downloaded package set per install, on a host whose root filesystem is
small, and the call reports success as though it had tidied.

# The proving test

NEW `t/unit/manager/104-a-layout-install-cleans-up-after-itself.t`:
`ok(!-d "/tmp/lazysite-layout-install-$$")` after a mocked install.

# Fix shape

Widen the cleaner's guard to cover the install prefix, or fold the two
cleaners into one with a prefix parameter (the review's TL-13), landing
this fix first so the parameter does not fossilise the leak.
