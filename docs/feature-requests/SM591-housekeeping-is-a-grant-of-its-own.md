---
title: "SM591: housekeeping is a grant of its own, in two tiers"
subtitle: "Part 2 of SM576, split out because its tiers depend on a rule nobody has ruled on yet: destruction across every store answers a lateral grant rather than each module's own capability."
brand: plain
standard-margins: true
status: candidate
status-note: "SPLIT FROM SM576 BY THE OPERATOR 2026-08-25 so the rest of that design can land in 0.10.33 without waiting. THE DESIGN, unchanged from SM576's part 2: deletion and housekeeping are the same job wherever they happen and are typically reserved to one person, so the destructive verbs across every store (brief-delete, data-safety-export-delete, backup-delete, artefact backups, cache and registry sweeps, retention) answer a LATERAL grant instead of the module capability that lets a partner use the module - so 'may use' and 'may destroy inside' stop being the same sentence. TWO TIERS, on the operator's ruling that the irreversible half is its own capability, assigned by an objective test - does the engine retain a copy? Self-healing (cache-invalidate, registry sweeps: rebuilt on the next request); recoverable (data-table-drop: mints a safety export); irreversible (brief-delete, data-safety-export-delete, backup-delete: no copy survives). The case that settles the rule is data-safety-export-delete: a drop is recoverable ONLY because the export exists, so deleting the export makes the earlier drop permanent - proven in the field 2026-08-25, a principal holding manage_data alone dropped another principal's table and deleted its export four seconds later. BLOCKED ON SM587: acl-remove is reversible as an OBJECT (the rule can be re-set) and irreversible as an EFFECT (content that was exposed cannot be un-exposed), and the copy test does not decide it; the recommendation on SM587 is to keep destructive meaning data-cannot-be-recovered and give exposure its own axis. ALSO CARRIES SM577: a backup store is instance-wide, so backup-delete is not scoped by the site whose grant authorised it - the sharpest case in the irreversible tier. NOT IN 0.10.33 unless SM587 is answered first."
---

# Why it was split

SM576's other two parts - `manage_briefs` and assignable groups - are
buildable today. This part is not, because assigning an action to a tier
needs the rule SM587 asks for, and a tier boundary drawn before the rule
would have to be redrawn after it.

# Concentration, carried over

One grant reaching every store is the point - it makes destruction
reviewable - and it also makes a mis-scoped lateral grant the most
valuable mistake available on the estate. So: it is the first capability
row swept, it is the strongest case for SM573's generated brief, and it
must be visible in the role that carries it.

# Proving tests

- A grant holding the recoverable tier reaches `data-table-drop` and is
  refused `data-safety-export-delete`.
- A grant holding a module capability but not the lateral one can use
  the module and cannot destroy inside it.
- The roster of effective holders (through the group closure) is
  readable where roles are assigned.
