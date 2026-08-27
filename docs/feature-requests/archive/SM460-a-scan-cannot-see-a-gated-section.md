---
title: "SM460: a scan: list could not see content in a gated section"
subtitle: "The page rendered successfully and listed nothing, so the author blamed their pattern. Every scan-driven index - blog listings, feature indexes, library pages - was unavailable behind a gate."
brand: plain
standard-margins: true
status: shipped
status-note: "FILED AND SHIPPED 2026-08-21 from the field. THE DEFECT: gating MOVES content out of the docroot (SM286), and resolve_scan globbed the docroot and walked beneath it, so a scan inside a protected section found nothing. It did not error and it did not warn - the page rendered, the list was empty, and the reasonable conclusion for the author is that their content is missing or their pattern is wrong. WHY IT WAS SAFE TO WIDEN: the ACL filter in resolve_scan was ALREADY written for private entries - its own comment says each entry is keyed through _content_rel 'so a page resolved from the private store is keyed and checked rather than skipping the branch and being listed' - and had never received one. Finding them was the missing half; the gating was already there. The leak guard is the first assertion in the test, and removing the filter is one of the four sabotages, so the guard is proven able to fail. TWO FURTHER FAULTS FOUND WHILE PROVING IT, neither reported and neither assumed absent: (1) the result URL was derived by stripping the scan root off the front, and the private root BEGINS with the scan root, so a page found there came back as '-lazysite-private/library/one' - a broken link that also published the store's naming. That is SM463's fault in a second place, and precisely what SM286's own header warns about: resolution and key derivation must change together, or widening the search INTRODUCES the fault rather than finding it. (2) The 200-file cap took a prefix of an unordered hash, so an uncapped listing came out right and a capped one held a different 200 pages on every render. TESTING NOTE worth carrying: the first test drove full renders and every case including the UNGATED CONTROL returned a bare status line with no body - the assertions were measuring the harness, and a control that fails is not a result. It was rewritten to call resolve_scan directly after load_processor, which t/unit/processor/13 already does."
---

# What the author saw

```datatable
columns: | Expected | Got
widths: 5cm | 5cm | X
bold: 1
tone: medium
---
A scan inside a protected section | its pages listed | an empty list, on a page that rendered successfully
An index in a public folder | its pages listed | correct throughout
```

Nothing distinguished the two for the author: no error, no warning, no log
line. The only signal was an absence.

# Why it was not simply a missing feature

The filter that decides what a scan may list was written for exactly this
case and says so in its own comment. It keyed each entry through
`_content_rel` so that a page resolved from the private store would be
checked rather than listed unchecked -- and no such page had ever reached
it, because nothing searched that tree. The gate was built and never used.

That is the shape worth recognising: a guard written for an input that the
producer never supplies looks identical, in the source, to a guard that
works.

# What shipped

The scan searches both trees, the governed copy wins a collision, the URL
is mapped back to its public spelling before it leaves, and the file cap
truncates a sorted list. Four sabotages, each confirmed to fail the test,
including removing the ACL filter to prove the leak guard can fail.
