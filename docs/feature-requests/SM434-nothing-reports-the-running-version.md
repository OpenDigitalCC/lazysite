---
title: "SM434: nothing reports the running engine version"
subtitle: "The generator meta says what RENDERED a page. There is no served surface that says what is running - so 'did the upgrade take' has no honest answer, and two agents in a row reached for the nearest number that looked like one."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED (PENDING) as the filing suggested: version added to the instance endpoint, read from the install state and never cached. THE CORRECTION IN THIS FILING STANDS AND IS THE REASON IT EXISTS - the generator meta was never wrong and is not changed; it reports what RENDERED a page, which is honest metadata about an artefact. What was missing was anywhere to ask what is RUNNING, and there is now. ORIGINAL FILING FOLLOWS. FILED 2026-08-20, and it is the finding that was hiding behind SM413 the whole time. THE CORRECTION FIRST: the `<meta name=generator>` version is read from the install state and baked into the HTML AT RENDER TIME, then cached with the page. A cached render therefore reports the version that produced it, which is CORRECT - honest metadata about the artefact. A page rendered under 0.10.18 and still cached on a 0.10.19 instance is not stale in any sense that matters; it is accurately describing itself. The release manager stopped a second, larger invalidation change that was being built on the opposite assumption. THE ACTUAL GAP: /.well-known/lazysite-instance.json returns instance and host and no version; nothing else served reports one either. So an operator or agent asking 'is this host on the new build' has nothing to ask, and both the field agent and I reached for the generator meta - a number that answers a different question and answers it correctly. WHY THE MISREADING WAS SO DURABLE: a render is served while its html mtime exceeds its source's, and an upgrade overwrites every SHIPPED page, so those re-render by themselves. The operator's own index.md is PRESERVED by the installer precisely because it is operator-edited, so its mtime never moves. The one page that keeps an old render is the homepage, which is also the first page anyone checks after an upgrade - a coincidence that made a non-fault look like a fault four deployments running. SUGGESTED: add version to the instance endpoint. Small, and it makes the question answerable by the thing that actually knows."
---

# The two questions

```datatable
columns: Question | Answered by | Today
widths: 5.6cm | 5cm | X
bold: 1
tone: medium
---
What rendered this page? | `<meta name="generator">` | correct, and cached with the page
What is running on this host? | nothing | **no surface reports it**
```

::: widebox
The first is not a broken version of the second. It is a correct answer to a
different question, and reading it as the second is what produced SM413's
entire investigation - by two agents independently, which suggests the trap is
in the absence rather than in either reader.
:::

# What SM413 turns out to have been

The homepage kept a render because its source was preserved across upgrades -
the installer deliberately not touching operator-edited content. Every shipped
page re-rendered because its source was overwritten. Neither behaviour is
wrong. What was wrong was reading the render's own honest self-description as
a claim about the engine.

The 0.10.18 render-invalidation change stands on its own merits - a new engine
may render differently, so clearing renders at upgrade makes that take effect
promptly - but it was justified at the time by this misreading and its
status-note should say so.

# Suggested

`version` on `/.well-known/lazysite-instance.json`, beside instance and host.
It is served by the engine, so it reports what is actually running, and a
sweep tool then has something to read that means what it says.
