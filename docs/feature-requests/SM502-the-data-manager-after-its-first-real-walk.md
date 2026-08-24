---
title: "SM502: the data manager, after its first real walk"
subtitle: "Task 5 walked by the operator on 0.10.28: all ten steps pass, rows/CSV/JSON round trips confirmed in LibreOffice - and five UI findings from actually using it, filed with refs."
brand: plain
standard-margins: true
status: shipped
status-note: "FILED 2026-08-24 from the operator's Task 5 browser walk on deployed 0.10.28 - the walk the register had carried as NOT WALKED since DM-7. ALL TEN STEPS PASS: rows add fine, CSV downloads into LibreOffice, CSV edit-and-import round-trips, JSON download works, and the SM487 migrate pre-flight refuses correctly with its reasons (the operator asked for and received a fuller explanation of the analysis - apply never loses data, rebuild is the explicit destructive path with a safety export first; worth folding into the panel text, see U-6). FIVE FINDINGS FROM USE, refs for quoting: U-1 rows are NOT paginated - the fetch carries no limit/offset at all, so a 5,000-row table renders 5,000 rows into one panel (the ROW_CAP=500 in Query.pm governs page bindings, not this listing); U-2 add/edit row should be a MODAL rather than an inline panel; U-3 label conventions drift - the descriptor panel closes with 'Close', the row editor with 'Cancel', the import with 'Cancel', for structurally identical dismiss actions; sweep the manager's widgets against one convention (Cancel = discard changes, Close = nothing to discard) and state it in the manager style notes; U-4 the descriptor is edited as raw YAML - it should be a structured form like the row editor, with a YAML tab retained for the full shape; U-5 there is NO 'add table' control - declaring happens over MCP/API only, so the one manager page about tables cannot create one; U-6 the migrate panel's explanation should carry the apply-vs-rebuild contract in its own words (apply refuses to lose data; rebuild makes the descriptor true, losses included, safety export first). SIZES: U-1 S-M, U-2+U-3 M together (the modal work is where the label sweep naturally happens), U-4 M, U-5 S-M (a declare form is a schema editor - overlap with U-4), U-6 S. SHIPPED 0.10.30: U-1 (data-rows always carried a silent 200-row server cap; the reply now returns the total and the panel pages honestly - rows X-Y of N, Prev/Next), U-5 (Declare a table: name prompt + starter descriptor through the same data-table-save/validate/plan path as editing), U-6 (the apply-vs-rebuild contract stated in the plan panel itself). THEN 0.10.31: U-2 (row editor modal), U-3 (Cancel/Close convention stated in the manager UI guide and swept), U-4's modal half (fields editor modal; the STRUCTURED descriptor form with a YAML tab remains queued under this number). SHIPPED 0.10.30 (87dafc9) as a PARTIAL: U-1, U-5, U-6; the number stays the home of U-2/U-3/U-4, still queued."
---

# The walk

Task 5 (MANUAL-CHECKS-WALKTHROUGH), walked by the operator on deployed
0.10.28: all ten steps pass. Confirmed by use: row add, CSV download into
LibreOffice, CSV edit and staged import, JSON download, and the migrate
pre-flight refusing with its reasons.

# The findings, from use rather than review

```datatable
columns: Ref | Finding | Size
widths: 1.2cm | X | 2.5cm
bold: 1
tone: medium
---
U-1 | Rows are not paginated - the fetch has no limit/offset; a big table renders whole | S-M
U-2 | Add/edit row should be a modal | M (with U-3)
U-3 | Close vs Cancel drift on identical dismiss actions - one convention, swept and stated | M (with U-2)
U-4 | Descriptor edited as raw YAML - structured form like the row editor, YAML as a tab | M
U-5 | No 'add table' control - the tables page cannot create a table | S-M
U-6 | The migrate panel explains apply-vs-rebuild in its own words | S
```

# Register

The manual-check register's Task 5 row moves from NOT WALKED to walked
(2026-08-24, operator, all steps pass) in the same commit as this filing.
