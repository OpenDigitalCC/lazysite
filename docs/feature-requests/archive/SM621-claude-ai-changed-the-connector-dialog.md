---
title: "SM621: Claude.ai's connector dialog now recommends an OAuth client this server does not implement, and our instructions still say to leave those settings blank"
subtitle: "Operator screenshot, 2026-08-26. The dialog gained an Authentication section and an OAuth client section; the recommended default is CIMD, and lazysite does RFC 7591 dynamic registration"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED in 0.11.2 (2026-08-26), documentation only - no engine change, because nothing is broken in the server. WHAT CHANGED IS OUTSIDE US: Claude.ai's Add-custom-connector dialog now asks which OAuth client to use and RECOMMENDS 'Use Anthropic's hosted client metadata (CIMD)', where the server fetches Claude's client details from a URL Anthropic hosts. lazysite-oauth.pl implements RFC 7591 DYNAMIC CLIENT REGISTRATION, which the same dialog calls 'No client ID - register one automatically'. An operator taking the recommendation gets a connector that cannot register, never reaches the sign-in prompt, and therefore never asks for the one-time connect code the manager just issued. THE FAILURE IS MISLEADING, which is why this is worth more than a footnote: what the operator sees is that the connect code did not work. The code is the thing on screen, counting down, with a Regenerate button next to it - so the natural response is to regenerate it, repeatedly, and none of them will ever be used. Nothing in the old instructions would move them off that. OUR GUIDE SAID THE OPPOSITE OF WHAT IS NOW NEEDED: 'leave Advanced settings blank'. That was accurate for the dialog as it stood and became wrong without anyone touching the file - the same shape as SM607 (a reference sentence that decayed) rather than a mistake made on the day. THE SCREENSHOT ALSO SHOWS 'None - Detected' beside Authentication, which means Claude.ai probed the endpoint and found no OAuth: oauth_enabled is OFF on that instance, so every OAuth endpoint returns 404 and the connect-code flow cannot start at all. Documented as its own branch of the instructions, with the static-bearer alternative (Authentication: None plus an Authorization header) for operators who do not want OAuth. TRANSPORT is now stated rather than assumed: the server is POST-only and answers GET with 405, so SSE cannot work. The default is already correct, which is exactly why it is worth naming - an unmentioned setting is one somebody changes. THE CORRECTION LIVES ON THE CARD, not only in the guide, because the card is what the operator is looking at when the code fails to be asked for. t/unit/manager/123 RUNS the card builder in node and asserts on rendered HTML rather than grepping the page, and pins the guide to the card so the two cannot drift apart again - which is how this got out of date in the first place."
---

# What the dialog now asks, and what to answer

| Dialog section | Choose | Why |
|---|---|---|
| Authentication | *Required when the server asks* | the server answers 401 with `WWW-Authenticate` |
| OAuth client | **No client ID - register one automatically** | RFC 7591 DCR; **CIMD is not supported** |
| Transport | Streamable HTTP | POST-only; `GET` is 405, so SSE cannot work |

# Why the wrong choice is hard to diagnose

The connect code is the thing on screen. It counts down, it has a Regenerate
button, and it is what the instructions talk about. So when sign-in never
happens, the code gets blamed - and regenerating it produces another code that
will also never be asked for.
