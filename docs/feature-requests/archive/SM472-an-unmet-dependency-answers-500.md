---
title: "SM472: an unmet dependency answered 500, and enabling never checked"
subtitle: "The data plugin enabled cleanly on a host without YAML::PP, listed its empty set of tables happily, and answered HTTP 500 to every attempt to declare one. Every signal was honest; none of them said the module's name."
brand: plain
standard-margins: true
status: shipped
status-note: "REPORTED 2026-08-22 from edge by the field agent, bisected carefully: the brief's own products descriptor with the table in body and query, body only, query only, a two-line minimal descriptor and deliberately malformed YAML all returned HTTP 500; only a call with NO descriptor answered properly. REPRODUCED locally by hiding YAML::PP from require, which produces every symptom exactly: list_data_tables succeeds because it globs filenames and, with no tables declared, never reaches the parser; the no-descriptor call answers because the parameter check runs before the require; everything else dies, and a die in a CGI is an HTTP 500 with an HTML body. THREE HONEST SIGNALS THAT TOGETHER SAID THE WRONG THING - 'writes are broken' rather than 'one package is missing'. TWO FIXES, and the second is the release manager's and is the better one. (1) Every require of a declared module is checked, and a missing one is reported with the module name AND a package that provides it - on the write path, the read path (which the RENDER path calls, so a die there is a visitor-facing 500), and in store_diagnosis, which now leads with the module because it explains every other symptom at once. (2) ENABLING A PLUGIN VERIFIES ITS DECLARED DEPENDENCIES and refuses if any are absent. ADR 0009 already has a plugin declare what it needs and the SBOM gate already reads that list; nothing read it at the one moment it answers a question an operator has - can this work here? Refused rather than warned, because the alternative is a plugin that is on and does not work, which is the state that produced the 500s. The check reads the plugin's OWN declaration rather than a list kept in the manager: a list there would be a second opinion about the same fact and would go stale the first time a plugin gained a dependency. NOT A PACKAGING DEFECT: DBI, DBD::SQLite and YAML::PP are declared in sbom-deps.json, in the deb and in the plugin's owns. The host serving edge did not have them."
---

# What the field met

```datatable
columns: Call | Answer | What it meant
widths: 6cm | 2.6cm | X
bold: 1
tone: medium
---
`list_data_tables` | fine | globs filenames; with no tables, never parses
No descriptor at all | correct JSON | the parameter check runs before the `require`
Any descriptor | **500** | `require YAML::PP` died
Deliberately bad YAML | **500** | so the promised validation never happened
```

Each answer was truthful. Together they described a broken write path, and
the truth was one absent package.

# Why enabling is the right place

An operator enabling a plugin is asking *can this work here*. The plugin has
already declared what it needs -- ADR 0009 requires it, and the SBOM gate reads
the same list to stop anything shipping undeclared. Nothing read it at the
moment the answer mattered.

Refusing is better than warning: a warning leaves a plugin that is on and does
not work, which is precisely the state that produced the 500s. The refusal
names the module and a package that provides it, so it is a next step rather
than a dead end -- install, then enable, which is the right order anyway.
