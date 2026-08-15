---
title: "SM306 - acl-set with no path protects the entire site"
subtitle: "One default, chosen for the reading actions, inherited by the one action that can take a site off the air. Omitting an argument selects the most destructive available target."
brand: plain
status: shipped
status-note: "SHIPPED on claude/sm305-principal-picker-and-polish - acl-set now refuses an absent or empty path naming path=/ as the explicit site-wide spelling, and refuses a body carrying a path key naming it. acl-remove, acl-get and list keep their defaults, and a test holds that so a safety change cannot make a site harder to rescue than to break. The THIRD option - narrowing the shared dispatcher default so any future write action stops inheriting the hazard - is deliberately NOT done and stays the follow-up; it is the change that stops the next instance rather than this one. Writing the control subtest for this fix uncovered SM310, a separate defect where acl-get could not read back the site-wide rule it had just written. FILED 2026-08-15 from a partner-agent field test of 0.10.9 on edge (inbox/acl-set-path-defaults-to-the-whole-site-2026-08-15.md, archived). The reporter put the path in the JSON body, where every neighbouring action takes its arguments; acl-set reads its path from the query string, discarded the body key in silence, and applied the default. The response was ok:1 and the site answered 302 to every anonymous request for about a minute. The reporter is explicit that the call was their mistake and the contract is documented - the filing is about which target an omitted argument selects, not about the call being wrong."
---

# SM306 - the destructive target is the default

## What was found

The control API derives the target path once, at the top of the dispatcher, for
every action (`lazysite-manager-api.pl:339`):

```perl
my $path = $params{path} // '/';
```

That default is right for `list`, which should list the site root when asked for
nothing in particular, and harmless for `acl-get` and `acl-remove`. `acl-set`
inherits it, where the same omission applies a site-wide read restriction and
returns `ok:1`.

Before SM287 a root entry sat inert, so this was a no-op. SM287 shipped in
0.10.8 and made a root rule take effect. The default has been hazardous since.

## Why the shape matters more than the instance

**Every other spelling of the root requires typing something that says so.**
SM287 was careful about exactly this: `/` is canonical, `''`, `.` and `./`
normalise to it, and glob spellings are *refused* with a message naming `/`, on
the reasoning that accepting `*` would imply a matching language the store does
not have. That instinct was applied to every spelling of the root except the one
that involves saying nothing at all.

**The body/query split invites the mistake.** `save` takes its content from the
JSON body. `domain-add` takes `host`, `content_root`, `site_url` and the rest
from the body. `acl-set` takes its lists from the body and its path from the
query string. A caller who has just used the first two has been taught where the
arguments go.

**Refusing an unrecognised key is already the house answer.** SM278 made all 51
MCP tools refuse unknown argument names with a message telling the agent not to
retry. The control API accepted a `path` key in a body that has no meaning for
it, and said nothing.

**The response explained the wrong thing.** The answer did carry the SM287
warning, and it is good text - it explains what a root rule means for someone who
chose one. It has nothing to say to someone who did not, and the sentence that
would have helped is the one nobody wrote: that a path had been supplied and
ignored.

## Scope

All four read from the same variable, so all four default to the root today.

```datatable
columns: Action | Effect of an absent path | Direction of failure
widths: 3.6cm | 6.4cm | X
bold: 1
tone: medium
---
`acl-set` | Site-wide read restriction | Destructive
`acl-remove` | Removes the root rule | Recovery
`acl-get` | Reads the root rule | Harmless
`list` | Lists the site root | Intended
---
```

Only the first row needs to change behaviour. The table is here because the
shared default is the cause, so a fix aimed only at `acl-set` should be a
deliberate choice rather than an accident of where it was applied.

## The fix

Require the path on `acl-set`
: refuse when `path` is absent, with a message saying that a site-wide rule is
  written as `path=/` and is deliberately explicit. This keeps the capability and
  removes the accident. `acl-remove` keeps its default, since its direction of
  failure is to un-protect the root, which is what recovery looks like.

Reject a body carrying keys the action does not read
: `path` in an `acl-set` body is a caller error with a clear diagnosis available,
  and refusing it matches what MCP already does on every tool.

Both are cheap and either is sufficient; doing both is better, because the first
removes the accident and the second explains it. The third option the reporter
raises - narrowing the shared default so it belongs with the actions that benefit
rather than at the top of the dispatcher - is the one that stops the *next*
instance, since any future write action inherits the hazard by doing nothing. It
is also the larger change. Take the first two now and keep the third as the
follow-up, recorded here so it is a decision rather than an omission.

## Verification

Each of these must be shown to fail before the fix.

- `acl-set` with no `path` is refused, and the message names `path=/` as the way
  to say site-wide.
- `acl-set` with `path=/` still works, and still returns the SM287 root warning.
- `acl-set` with a `path` key in the body is refused, naming the key.
- `acl-remove`, `acl-get` and `list` are unchanged - a regression here would make
  recovery from a root rule harder than creating one.
- A site-wide rule remains creatable and removable, which is the trap SM287 found
  in its own writer test.

## The MCP surface never had this

`set_permissions` declares `required => ['path']` in its input schema, so the
same operation over MCP has always refused a call with no target. The control
API is where the shared dispatcher default reached it.

Worth recording because the parity machinery did not and could not catch it.
SM239 pins that MCP and the control API expose the same *actions*, and t/lint/23
records which are deliberately one-sided. Neither compares what the two surfaces
*require*, so one channel can demand an argument while the other invents a
dangerous default for it, and both look correct to every check.

That is a candidate for a future lint rather than a defect in this one: for each
paired action, an argument required on one surface should be required on the
other, or the difference should be recorded with a reason.

## Related

SM287 (what made a root rule effective, and which was careful about every other
spelling of it), SM278 (unknown argument names refused on the MCP surface), SM237
(the API explaining a caller's mistake rather than reporting its consequence).
