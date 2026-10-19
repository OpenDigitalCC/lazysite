---
id: SM1200
title: "SM1200: the alias override list holds only its keys"
subtitle: "Comments inside the qw() list of per-host override keys were read as keys; they are out of the list, and a test holds the list to its intended members."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-19
raised-by: the C2 restack (release manager's agent), 2026-10-19 (perl's own warning on compiling the processor)
area: engine
status-note: "SHIPPED (PENDING) on n690: lazysite-processor.pl (%ALIAS_OVERRIDE_KEYS); t/unit/processor/145."
---

# What happened

Compiling the processor said "Possible attempt to put comments in qw() list" (and
"...to separate words with commas") at the declaration of `%ALIAS_OVERRIDE_KEYS`.
SM1155 (97fe34072, 2026-10-17) added a `# SM1155: ...` line inside the `qw()`;
two older notes (SM179, July; P16 / SM1002, October) were there already. In a
`qw()` a `#` is a word, so every word of all three notes was a member of the list.

# What the list is, and what the stray words did

`%ALIAS_OVERRIDE_KEYS` is the whitelist of `lazysite.conf` keys that an
`alias.<host>.<key>: value` line may override for one declared host (SM110); a
key not in it is logged as "alias override ignored - key not whitelisted". It is
read in one place, the conf reader in `lazysite-processor.pl`, which takes the key
as `(\w+)` and tests it against the hash.

So a stray word was an accepted key only if it was all word characters. Ten were:
`CSP`, `a`, `app`, `be`, `domain`, `its`, `language`, `may`, `membership`, `own`.
The rest (`#`, `SM179:`, `per-host`, `(name,`, `shell)` and so on) could never be
matched by `\w+`. An accepted word was written into the host's definitions and so
became a template variable of that name for that host (`alias.example.com.domain: x`
set `[% domain %]`). Nothing else reads the hash: none was cached, none was a key
the engine reads as configuration, and it needed an operator's own `lazysite.conf`
line naming a declared host, so no visitor could reach it. The one real risk was
a future key colliding with one of those words; none has.

# What shipped

- The three notes moved above the declaration; the list holds only the 24 keys it
  meant, and the warnings are gone.
- `t/unit/processor/145` loads the processor and holds `%ALIAS_OVERRIDE_KEYS` to
  exactly those keys, and runs `perl -c` on the processor asserting neither the
  qw() comment warning nor the comma warning.
