#!/bin/bash
# tools/regen-generated.sh - rewrite every document that is generated from code.
#
# SM948: each of these is checked by a test that fails when it is stale
# (t/tools/26, t/tools/25, t/lint/110), and a stale one used to fail a six-minute
# handoff whose fix was always one command. tools/handoff.sh runs this first and
# commits what changed, so a handoff never fails on a generated document.
#
# Prints the paths it changed, one per line; nothing when everything was current.
# A generator that fails exits non-zero and the handoff fails on it.
set -u
cd "$(dirname "$0")/.." || exit 2
rc=0
gen() {    # gen OUTFILE cmd...   - write cmd's stdout to OUTFILE only if it differs
    local out=$1; shift
    local tmp="$out.regen.$$"
    if ! "$@" > "$tmp"; then echo "regen: FAILED: $*" >&2; rm -f "$tmp"; rc=1; return; fi
    if cmp -s "$tmp" "$out"; then rm -f "$tmp"; else mv "$tmp" "$out"; echo "$out"; fi
}
gen docs/reference/capability-map.md      perl tools/gen-capability-docs.pl map
gen docs/reference/quickstarts.md         perl tools/gen-capability-docs.pl quickstarts
gen docs/reference/control-api-actions.md perl tools/gen-capability-docs.pl actions
gen docs/reference/host-dependencies.md   perl tools/gen-host-deps.pl
before=$(git hash-object docs/INDEX.md 2>/dev/null)
perl tools/gen-doc-index.pl --write >/dev/null || { echo "regen: FAILED: gen-doc-index.pl" >&2; rc=1; }
[ "$(git hash-object docs/INDEX.md 2>/dev/null)" != "$before" ] && echo docs/INDEX.md
exit "$rc"
