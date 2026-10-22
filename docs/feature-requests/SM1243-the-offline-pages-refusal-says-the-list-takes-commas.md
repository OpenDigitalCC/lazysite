---
id: SM1243
title: "SM1243: the offline pages refusal says the list takes commas"
subtitle: "app_offline_pages set to paths separated by spaces was refused as one path that is not plain. That was true, but the refusal did not say the list is separated by commas. Now it does, with the list written that way."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-20
raised-by: "the 0.15.15 test-plan results (inbox 2026-10-20-test-plan-01515-results.md), task #372c"
area: manager
status-note: "SHIPPED (PENDING) on n725: Config.pm's app_offline_pages check adds 'the list is separated by commas, e.g. ...' to a refusal whose entry reads as paths separated by spaces. t/unit/manager/368."
---

# What happened

On the 0.15.15 walk, `app_offline_pages: /zz75/a /zz75/m` was refused as
"/zz75/a /zz75/m is not a plain site path". That is correct, but the refusal did not
say that the list is separated by commas.

# What the setting accepts

A list separated by commas, with spaces around each comma allowed. Each entry is a
plain site path. Both readers split it the same way: `split /,/` with each entry
trimmed, in the save check (`Manager::Config`) and in the processor
(`lazysite-processor/app.pm`). Spaces alone do not separate entries, so `/a /b` is one
entry, and it is not a path.

# What shipped

When an entry is refused and it reads as paths separated by spaces (a space followed by
`/`), the refusal adds: "; the list is separated by commas, e.g. /zz75/a, /zz75/m". A
single path with a space inside it, such as `/portal/a b`, is refused as before, with no
hint.

# Tests

t/unit/manager/368, new subtest: `/portal/ /portal/new` is refused as not a plain site
path, the refusal says the list takes commas and ends with `e.g. /portal/, /portal/new`,
`/portal/a b` gets no hint, and the stored list is unchanged. With the change reverted,
the two hint assertions fail.

# Not done

- `app_shell` is read the same way (separated by commas) and its refusal has the same
  gap. It is not changed here.
