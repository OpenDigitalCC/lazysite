---
title: "SM635: a protected folder rendered an empty Access cell, and everything inside a protected folder reported nothing at all"
subtitle: "Operator report, 2026-08-27: the Protected sections card said protect-test was gated with 2 pages and 1 asset, and the row's own expansion did not reflect it"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED in 0.11.3 (2026-08-27). TWO CAUSES, and the first is the one the eye lands on: a FOLDER rendered an empty Access cell by construction - `(isDir ? '' : accessBadge(f))` - so the one row that most needed to say 'held back' was the one row that said nothing at all. The second is worse and quieter: protectionFor() answered only for DIRECTORIES and only on an EXACT prefix match, so everything inside a protected folder reported nothing, while the entire point of a section rule is that it covers what is beneath it. An operator standing on a gated page was told nothing, which reads as 'this page is public' - a confident wrong answer about access. VERIFIED BEFORE CHANGING ANYTHING by extracting the real functions and running them: the folder lookup worked given data and the file lookup returned null, which located the defect precisely rather than by guess. THE LOOKUP NOW ANSWERS FOR ANY ROW and says WHERE the rule came from - its own, an ancestor's, or the site-wide rule - because 'this folder is gated' and 'everything here is gated' are different facts and only one of them can be changed from that row. NEAREST MATCH WINS: a draft section inside a gated one is hidden outright, not merely sign-in, so reporting the wider rule would understate the gate. THE CARD IS GONE as the operator asked, and TWO THINGS HAD TO MOVE WITH IT RATHER THAN VANISH. Its Publish / Remove-protection buttons were the only such controls on the page; they now sit in the expansion, and ONLY on the row that OWNS the rule - offering them on an inherited row would be offering a button that acts somewhere else. And the fetch that filled the card also fills the map the LISTING reads, returning early when the card's elements were missing: deleting the markup alone would have fetched the data and thrown it away while every padlock vanished and the page said nothing is protected. A sabotage proved the first version of that assertion pinned the old bug's exact wording rather than the property, and a differently-spelled early return passed. AN UNCOVERED ROW NOW SAYS SO rather than showing an empty expansion, which is indistinguishable from one that failed to load. NOTE THE OTHER PADLOCK: lockGlyph() marks a WebDAV EDIT lock in the actions column - same glyph, different question - so each carries a tooltip naming its own subject."
---

# What the operator saw

| The card said | The row said |
|---|---|
| `protect-test` · gated · manager · 2 pages, 1 asset | *(nothing)* |

# The two causes

| | |
|---|---|
| A folder's Access cell | rendered empty by construction |
| A file inside a protected folder | reported no rule at all |
