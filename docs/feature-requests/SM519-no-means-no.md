---
title: "SM519: no means no"
subtitle: "YAML 1.2 spells `no` as a string. The descriptor loader tested it with Perl truth, so `public: no` published the table to anonymous visitors, `required: no` refused writes and `unique: off` built a unique index."
brand: plain
standard-margins: true
status: shipped
status-note: "FOUND 2026-08-25 by the data/auth structural review, proven by probe tmp/dac-probe-yaml-bool.t through the real load_table with YAML::PP: `public: no`, `timestamps: No` and `unique: off` all loaded as TRUE and `required: no` came through as the string 'no'. YAML::PP implements YAML 1.2, where only true/false are booleans; Descriptor.pm tested every flag with Perl truth and refused only references. SHIPPED 0.10.32 (the beta build): one _bool normaliser serves public, timestamps, required and unique - 1/0, true/false, yes/no and on/off case-insensitively, plus JSON::PP booleans; absent is false; anything else is refused with the message the file already promised, `<key> must be true or false`. required and unique are written back normalised so Schema, Value and SQLite read the same answer. t/unit/data/01 asserts every spelling, the refusal, and the probe's YAML text through YAML::PP. starter/docs/data-tables.md states the accepted spellings."
---

# The defect

*No means no.* A descriptor saying `public: no` meant the author had
decided the table was private, and the loader published it. Access.pm
asked `$desc->{public}` and was told 1, because the string `no` is true
in Perl and YAML 1.2 hands it over as a string.

The same test of truth reached three other flags: `timestamps: No` created
the timestamp columns, `required: no` refused every write that left the
field empty, and `unique: off` built a unique index. Each is the natural
spelling of "off", and each read as "on".

# The fix

- One `_bool` normaliser, used at every boolean site in Descriptor.pm.
- Accepted, case-insensitively: `1`, `0`, `true`, `false`, `yes`, `no`,
  `on`, `off`, and a JSON::PP boolean from the API path. Absent is false,
  because every flag here defaults closed.
- yes/no/on/off are honoured rather than refused. They are the natural
  spelling, and refusing them would be the surprising alternative.
- Anything else is refused at load with the descriptor's own error shape:
  `table 'x': public must be true or false`, `rule` naming the key; field
  flags carry `field 'f': required must be true or false`.
- `required` and `unique` are written back normalised, so every downstream
  reader of the field spec sees 1 or 0 and never the word.

# Field question

Whether any live descriptor already says `no` is a question for the site
agents: after this build such a descriptor refuses to load only if it says
something outside the accepted set, and otherwise starts meaning what it
says.
