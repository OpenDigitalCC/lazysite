---
title: "SM568: nav-read and pages need manage_nav on the API but manage_content over MCP"
subtitle: "The first thing the API/MCP twin-capability pin found: two reads under different capabilities on the two channels, and nobody decided that."
brand: plain
standard-margins: true
status: shipped
status-note: "DECIDED AND SHIPPED 0.10.32 (EDGE): the API accepts manage_content OR manage_nav for nav-read and pages (token gate, ControlApi::Actions registry and Capabilities.pm unlocks agree; docs/reference regenerated); read_nav and list_pages stay under manage_content over MCP, which the API now accepts, so the twins leave t/lint/23 %TWIN_DIFFERS and the set rule passes - the proving test. t/lint/14 and 86 green. FOUND 2026-08-25 by the t/lint/23 twin-capability check added under SM567 (the operator's four-surface question, API-to-MCP column): nav-read and pages sit under manage_nav in the control API's registry while their MCP twins read_nav and list_pages sit under manage_content. Reading the navigation and listing pages are content reads; a manage_content partner can do both over MCP and neither over the API. Recorded in the lint's %TWIN_DIFFERS with this filing as the reason, so the class stays guarded. PLANNED for 0.10.33 under SM516: decide (probably manage_content OR manage_nav on both channels, since a nav editor needs the page list and a content author needs the nav) and remove the exemption."
---

# The proving test

t/lint/23: remove `nav-read` and `pages` from `%TWIN_DIFFERS`; the
set-equality assertion passes once both channels agree.
