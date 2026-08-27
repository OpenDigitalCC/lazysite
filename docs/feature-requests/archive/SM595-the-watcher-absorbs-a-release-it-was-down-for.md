---
title: "SM595: the deploy watcher absorbs any release that landed while it was down"
subtitle: "The baseline is whatever is already in dist at startup, so a release that arrived while the watcher was stopped is treated as already deployed. The workaround was renaming the tarball."
brand: plain
standard-margins: true
status: shipped
status-note: "RAISED BY THE OPERATOR 2026-08-25 from repeated practice: `if it isnt running when release lands, it re-baselines so i have to rename to get it to see new`. VERIFIED FROM THE CODE: watch_and_deploy sets `current=$(latest_version \"$DIST\")` at startup and only ever deploys something strictly greater, so a release sitting in dist when the watcher starts IS the baseline and can never deploy. That is right while the watcher keeps running - it deploys each bump as it appears - and wrong across a restart, which is exactly when a release is most likely to have been missed. SHIPPED 0.10.33: `--baseline X.Y.Z` seeds the baseline explicitly, and the startup line now says whether the baseline was `given` or `detected` so the two cases are distinguishable in a log. TWO COPIES EXIST AND HAD DIVERGED: tools/lazysite-deploy.sh is tracked and carries no host defaults (SM379 - a hostname in a released artefact is a detail about the operator), while the operator's working copy keeps theirs; the fix is in both, from one implementation, and the operator's defaults were lifted from their own file rather than retyped. TWO DEFECTS FOUND WHILE BUILDING IT, both fixed here: the tracked copy refused to run without LAZYSITE_HOST/LAZYSITE_DIST BEFORE parsing arguments, so `--help` failed for anyone who had not configured it yet - the check now sits in the deploy path; and usage() printed a fixed line range, which would silently truncate the help when anything above it was edited - it is delimited by markers now. Proving tests in t/tools/42."
---

# What was wrong

The watcher's baseline is the highest version already in `dist` when it
starts. While it keeps running that is exactly right: each new bump is
strictly greater, so each one deploys. Across a restart it inverts - the
release that landed during the outage is already there, so it becomes the
baseline and is never deployed.

The operator's workaround was to rename the tarball so the watcher could
not see it, start the watcher, then rename it back.

# What it does now

```
lazysite-deploy.sh --baseline 0.10.31   # 0.10.32 already in dist WILL deploy
```

`--baseline` says what has actually been deployed. Anything strictly
higher then deploys as usual, including something already sitting in
`dist`. Without it the behaviour is unchanged.

The startup line names which kind of baseline it holds:

| Line | Means |
|---|---|
| `baseline: 0.10.32, detected` | taken from `dist` - deploy the next bump |
| `baseline: 0.10.31, given` | stated by the operator - deploy anything above it |

A given baseline that is already beaten by something in `dist` says so
before it deploys it, so the log shows the catch-up was deliberate.

# Why the value is validated where it is read

`--baseline` is checked against the same plain `X.Y.Z` shape
`latest_version` accepts, at the point the argument is READ rather than
after the parse loop. An empty string is the "not given" sentinel, so a
check placed after the loop would let `--baseline ''` fall back to
detection silently - the one spelling most likely to come from a shell
variable that did not expand.
