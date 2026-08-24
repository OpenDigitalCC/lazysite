---
title: "SM513: delete_page takes a path as well as a slug"
subtitle: "read_page takes path; delete_page took only slug. Two page tools, two identifiers - a mistake every agent makes once per session."
brand: plain
standard-margins: true
status: shipped
status-note: "NOTED BY THE SITE AGENT 2026-08-24 as a method error of their own (delete_page{path} refused; the message named the accepted argument, so it cost one round trip) and flagged as worth a glance. SHIPPED 0.10.31 on the operator's pick: delete_page accepts slug OR path (read_page's spelling, /about.md), and refuses naming both when given neither. rename_page keeps old/new - they are already paths-or-slugs and were not the complaint. t/unit/mcp/01 pins the alias and the refusal."
---

# The asymmetry

`read_page { path }` and `delete_page { slug }` name the same page two
ways. The refusal message was clear, so it cost one round trip - but it
costs that round trip to every agent, every session.

# The fix

`delete_page` accepts either identifier: `slug` as before, or `path` as
`read_page` spells it. Given neither, it refuses naming both.
