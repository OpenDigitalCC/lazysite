---
id: SM861
title: "SM861: theme copy, rename and delete silently edited the name they were given, so they acted on a theme the caller never named"
subtitle: "Each ran s/[^a-zA-Z0-9_-]//g over the name first - on the SOURCE too, so a not-found could quote a theme nobody typed - and copy and rename additionally lower-cased the target. Mixed case is valid everywhere else here, so these three were the only surfaces that could not address half the names the store permits. A tester's copy therefore failed to collide with a mixed-case theme already present."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-09-12 for 0.13.14, as the release manager ruled: refuse, do not mutate. One helper, `_bad_theme_name`, validates against the module's own [A-Za-z0-9_-]+ and answers kind: validation naming the parameter and what is allowed; the strip and the lc are gone from copy, rename and delete. theme-activate and layout-activate are DELIBERATELY unchanged - their strip is load-bearing for SM247. t/unit/manager/187 holds it; t/unit/manager/153 had asserted the folding as incidental behaviour and was updated, with the reversal stated in place."
raised: 2026-09-12
raised-by: site agent (1313E fixture note)
area: themes
---

# What was found

The site agent, clearing its 1313E fixtures:

> "`theme-copy` lower-cases the name it is given, so copying `lumen` to
> `lumen-1312E-backup-20260911T045513Z` did not collide with the existing
> mixed-case theme - it created a second, lower-case
> `lumen-1312e-backup-20260911t045513z`. Whether a theme name should be
> case-folded on copy is a question for you; it is how I got my `exists`
> control, by copying onto the lower-case name a second time."

They reported the case folding. Reading the code found a second, larger mutation
beside it.

# Two silent edits, and the smaller one is the case

`action_theme_copy` opened:

```perl
$from =~ s/[^a-zA-Z0-9_-]//g if defined $from;
$to   =~ s/[^a-zA-Z0-9_-]//g if defined $to;
$to = lc( $to // '' );
```

- **Every disallowed character was stripped, without a word.** `My Theme!`
  became `MyTheme` and was created under that name, reported as a success. The
  caller had no way to learn the name they now had.
- **It applied to `$from` as well**, which is a name being RESOLVED rather than
  created - so `Theme 'X' not found` could quote a theme the caller never typed,
  and a malformed source name could silently become a valid, different one.
- **Only `$to` was folded.** So a mixed-case theme could be read from and never
  written to.

`action_theme_rename` carried the same pair. `action_theme_delete` carried the
strip - on a destructive verb, where acting on a near-miss name is worst.

# Why it reads as a defect rather than a convention

Mixed case is valid **everywhere else in this module**: `theme_config_issues`
accepts `[A-Za-z0-9_-]+`, the theme listing lists mixed-case directories, and
WebDAV creates them - which is how the mixed-case theme the agent collided with
(and didn't) came to exist. So the store permits a set of names that copy and
rename could not address, and the existence check `-d "$themes_dir/$to"` tested
the FOLDED name, which is why a collision could be missed.

The rest of the module also already **refuses** rather than edits -
`theme_config_issues`, the layout/theme guard. These three verbs were the
outliers on both counts.

# The fix, as ruled

Refuse, do not mutate. One helper:

```perl
sub _bad_theme_name {
    my ( $label, $name ) = @_;
    return undef if defined $name && $name =~ /^[A-Za-z0-9_-]+$/;
    return { ok => 0, kind => 'validation', field => $label,
        error => "$label '" . ( defined $name ? $name : '' )
            . "' must match [A-Za-z0-9_-]+" };
}
```

used by copy (`from`, `to`), rename (`name`, `new_name`) and delete (`name`). A
name is used as given or refused by name; mixed case survives; the collision
check now compares what the caller actually asked for.

The rename refusal it replaces is worth naming: `Invalid name` answered for an
empty name **after** stripping, so a wholly-invalid name reported as *absent*
rather than as *wrong*, and a partly-invalid one was accepted as something else.

# What was deliberately NOT changed, and why

**`action_theme_activate` and `action_layout_activate` keep their strip.** It is
load-bearing: the control API defaults `path` to `/`, which the strip reduces to
the empty string, and SM247's guard then names it as a missing parameter with
wording written after a site agent left a live site unstyled by sending the name
in the wrong parameter and trusting `ok:1`. Refusing on the character would
replace that message with a validation error and undo the fix. Recorded here so
the inconsistency is a decision rather than an oversight.

**`_install_theme_from_dir` keeps its fold** of the name read from an uploaded
`theme.json`. That sanitises a value from a file rather than a caller's
parameter, and making upload refuse a name it previously accepted is a separate
behaviour change on a path this finding did not touch.

# A reversal, stated

`t/unit/manager/153` asserted `is( $r->{name}, 'live-next', 'the copy is named,
lower-cased' )`. Its subject is the copy-then-activate workflow and the folding
was recorded as description, not defended by any rationale - so it was updated
rather than worked around. Its collision subtest now also proves the other half:
a name differing only in case is its own theme, where before it silently was not.

# Related

SM247 (the deactivation guard whose strip must stay), [[SM773]] (a missing
parameter named as missing - the same family: never describe an absent or
malformed value as something else), SM532 (rename's other guards).
