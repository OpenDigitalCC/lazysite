---
title: "SM622: the connector panel minted a code, counted down thirty minutes, and polled for a connection the site had not been configured to accept"
subtitle: "Operator request after SM621: check the services are enabled, because there is no point trying if they are not ready"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED in 0.11.2 (2026-08-26). THE 0.9.0 KILLSWITCHES ARE RIGHT AND LEFT A HOLE: every remote surface is off by default, which is the correct posture, and nothing on the connector panel said which ones this flow needs. So the panel would mint a connect code, start a 30-minute countdown, poll for a connection that could not happen, and offer a Regenerate button - the operator sees a code that did not work, blames the code, and re-mints it. NONE OF THEM WILL EVER BE ASKED FOR. This is the same misreading SM621 documents for the OAuth-client radio, reached from a different direction, and it is the second time in one day that a wrong SETTING presented itself as a bad CODE. cmd_onboarding_web now returns a `prereqs` block and the panel renders a warning ABOVE the steps when the flow cannot work, naming the services in WORDS (MCP connector, OAuth authorization server) rather than conf keys, saying that the code will never be asked for, and pointing at Config -> Services. THE TWO FLOWS NEED DIFFERENT THINGS, which is why this is a map and not a boolean: a WEB connector needs mcp_enabled + oauth_enabled; an AGENT redeems a pairing key through token_exchange_enabled and then drives whichever surfaces it holds. Verified empirically against %CHANNEL_SERVICE and the pairing-key path rather than assumed. REPORTED, NOT ENFORCED - an operator may be mid-setup, and a panel that refused to issue a code would be worse than one that says what is missing. ABSENT MEANS SILENT: the panel is served from the site tree and the API from the engine, so they can be different versions mid-upgrade; no prereq data produces no warning rather than a warning invented from missing data, and t/unit/manager/125 pins that. Seven sabotages across SM622 and SM623, all fail - including 'warning moved below the connect code', because a warning found under the code is found after the code has been tried."
---

# What the panel used to do

1. Mint a connect code
2. Start a 30-minute countdown
3. Poll for a connection that **could not happen**
4. Offer Regenerate

Steps 1-4 repeat for as long as the operator's patience lasts.

# What it needs, per flow

| Flow | Services |
|---|---|
| Web connector (Claude.ai, ChatGPT) | `mcp_enabled` + `oauth_enabled` |
| Agent / CLI (Claude Code, Desktop) | `token_exchange_enabled`, then whichever surfaces it drives |
