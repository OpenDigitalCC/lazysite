---
title: "SM841: on a phone the Files trigger is clipped to 'Se' in the accessible style, and nothing says the table scrolls"
subtitle: "Sites agent, 1312E-08, 2026-09-11: SM834 fits at 420px in all three styles, but accessible has 13px of headroom that a desktop scrollbar takes, and at 360px the row's only action is two letters behind an unsignposted sideways scroll"
brand: plain
standard-margins: true
status: candidate
---

# What was measured

At a true 420px of usable width, the trigger's right edge and the headroom:

| Style | Right edge | Headroom |
| --- | --- | --- |
| modern | 381 | 39px |
| classic | 397 | 23px |
| accessible | 407 | **13px** |

A 15px desktop scrollbar puts accessible 2px over. At 360px the page never
scrolls sideways - the table scrolls inside its wrapper, as SM834 intended - but
the tester's verdict on whether that is usable was **yes in modern and classic,
no in accessible**, where the trigger reads *"Se"*.

# The part that is a decision rather than a pixel

**Nothing signposts that the table scrolls.** No edge shade, no fade. A person who
does not think to swipe inside the table cannot reach the only per-row action,
and on a phone that is the whole interaction. The tester's suggestion - collapse
a column at this width, or move the trigger into the name cell - would beat
taking another 40px out.

Moving the trigger changes the row idiom SM819 settled for every list, so it
belongs to whoever decides that idiom; taking 20px more out of accessible is the
cheap interim and does not answer the signposting.

# Related

[[SM834]] (the fix at 420px), [[SM819]] (the three-column row), [[SM845]] (the
row trigger across every list).
