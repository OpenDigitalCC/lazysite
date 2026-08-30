---
id: SM695
title: A token client cannot tell protected-by-design from merely unrecorded
raised: 2026-08-29
raised-by: edge-testing agent
area: content-history
status: shipped
status-note: "SHIPPED in 0.11.7. The cause was narrower and more precise than first filed: SM286 already reported the private STORE correctly (versioned:0 with a notice), and said nothing for the paths the REPOSITORY excludes - the auth store, the forms store, runtime state, generated .html. lazysite/forms/submissions/ is in git @EXCLUDE, so it can never hold a commit, and it was answering versioned:true. Git::excluded_from_history now derives that from the same @EXCLUDE list git is given, and the two empty cases carry different sentences: a protected file's history ran up to the point it was protected, an excluded path was never recorded at all. ORIGINALLY FILED AS: Measured on 0.11.5: for a file in the private store, both `git-history` (control API) and `list_versions` (MCP) return `{versions:[], versioned:true, enabled:true}` - byte-identical in shape to a normal file that simply has no commits yet. SM683 fixed the misleading wording, but only on the FILES PAGE, which applies the interpretation when it renders. Every other client sees an empty list and no reason, so a token client cannot distinguish 'this content is held outside version control on purpose' from 'recording may be failing' - which is the exact confusion SM683 exists to remove."
---

# What was measured

The edge agent probed `lazysite/forms/submissions/contact` - a file in the
private store - on 0.11.5:

| Surface | Response |
| --- | --- |
| `git-history` (control API) | `{versions:[], versioned:true, enabled:true}` |
| `list_versions` (MCP) | the same |
| a normal content file with no commits | **the same** |
| a normal content file with commits | its real commit list |

So the tools return raw version data and say nothing about WHY a list is empty.

# Why this is SM683 again, one surface out

SM683's defect was that an empty history was reported as a possible fault -
"version recording may be failing... run `lazysite check`" - for content that
has no history BY DESIGN, because the private store sits outside git's work
tree. A working system described itself as broken and sent the operator to a
diagnostic that reports health.

That was fixed **in the Files page**, which applies the interpretation when it
renders an empty history for a protected file. The fix lives in the renderer,
not in the answer.

The consequence is that the page is now the only client that can tell the two
apart. An agent, an integration, or any future surface asking the same question
gets the same undifferentiated empty list SM683 was filed about - and will draw
the same wrong conclusion, because the data genuinely does not distinguish them.

# What it needs

The ANSWER should carry the reason, and the page should render what the answer
says rather than deciding for itself:

- `versioned: false` with a reason when the path is in the private store, or
- `versioned: true, reason: "protected"` - the exact spelling matters less than
  that a machine reader can branch on it.

Either way the Files page then displays what it is told, which also removes a
second place where the interpretation could drift from the truth.

Worth checking at the same time whether `git-history` should say anything for a
path it cannot version at all, versus one that is versionable and simply has no
commits yet. Those are three states - unversionable, versionable-but-empty, and
has-history - and today the first two are indistinguishable.

# Related

[[SM683]] (the same confusion, fixed on the page only; its versioning work would
change this answer again), [[SM687]] and [[SM689]] - the same shape a third and
fourth time: a correct answer that one surface interprets and others do not.

# Not started
