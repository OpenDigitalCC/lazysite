#!/bin/bash
# tools/gate-main.sh - gate main's tip after a landing, so a receipt is
# usually ready when a cut is called (SM950 (2)).
#
#   tools/gate-main.sh [--version X.Y.Z] [--beta|--final|--certified]
#                      [--stage-dir DIR] [--ref REF]
#
# The developer agent runs this, in the background, after the release manager
# lands a branch. It resolves REF (default main) to a SHA, decides the version,
# and then:
#
#   - a receipt for that SHA, version and channel already passed: prints it and
#     exits 0 without running anything - the gate is a fact about a commit, and
#     that commit has not changed;
#   - main is cut-ready (the practice briefing is stamped for the version, so
#     the pre-cut pass has landed): `tools/release.sh gate VERSION --commit SHA`,
#     the real gate, whose receipt `build` accepts;
#   - otherwise: the same with --rehearse - the tree as committed, every gate
#     step, a receipt with result=rehearsal that `build` refuses. Its value is
#     the coverage pass it keeps by digest: when the pre-cut pass lands (it
#     changes nothing coverage reads), the real gate reuses it and takes the
#     suite's time rather than the hour coverage takes.
#
# THE VERSION is the one release.sh would propose: the newest local v*.*.* tag
# with its patch bumped (SM064), which is also what NEXT_VERSION at the gated
# commit says once the post-release record has rolled the pair. If the two
# disagree - a new minor line, say - nothing is guessed: pass --version, after
# the release manager has said which. A version already tagged is refused.
#
# DETACHED, as release.sh's own steps are: `setsid -w ... </dev/null`, so
# nothing in the gate can reach a terminal or prompt for a password, and this
# script calls no sudo, systemctl or pkexec (t/lint/208). One run at a time: a
# second is refused while the first holds tmp/release-gate/.gate-main.lock.
# The whole gate's output is in tmp/release-gate/VERSION/gate-main.log.
#
# Exit: 0 gated (or already gated), 1 the gate failed, 2 refused before
# starting (bad arguments, version undecidable or burned, a run in progress).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
export GIT_TERMINAL_PROMPT=0

REF=main
VERSION=""
CHANNEL=edge
CHANNEL_FLAG=()
STAGE_FLAG=()

refuse() {
    local line
    for line in "$@"; do echo "gate-main: $line" >&2; done
    exit 2
}

need_value() { [ $# -ge 2 ] || refuse "$1 needs a value"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --version)
            need_value "$@"
            VERSION=$2
            shift 2
            ;;
        --ref)
            need_value "$@"
            REF=$2
            shift 2
            ;;
        --beta)
            CHANNEL=beta
            CHANNEL_FLAG=(--beta)
            shift
            ;;
        --final | --stable)
            CHANNEL=stable
            CHANNEL_FLAG=(--final)
            shift
            ;;
        --certified)
            CHANNEL=certified
            CHANNEL_FLAG=(--certified)
            shift
            ;;
        --stage-dir)
            need_value "$@"
            STAGE_FLAG=(--stage-dir "$2")
            shift 2
            ;;
        -h | --help)
            sed -n '2,37p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) refuse "unknown argument '$1' (see --help)" ;;
    esac
done

SHA=$(git -C "$ROOT" rev-parse --verify --quiet "$REF^{commit}") \
    || refuse "'$REF' does not name a commit in $ROOT"

# --- the version -------------------------------------------------------------
LAST_TAG=$(git -C "$ROOT" tag -l 'v*.*.*' | sort -V | tail -1)
PROPOSED=""
if [ -n "$LAST_TAG" ]; then
    PROPOSED=$(printf '%s\n' "${LAST_TAG#v}" | awk -F. '{ printf "%d.%d.%d", $1, $2, $3 + 1 }')
fi
NEXT=$(git -C "$ROOT" show "$SHA:NEXT_VERSION" 2>/dev/null | tr -d '[:space:]' || true)
burned() {
    if git -C "$ROOT" rev-parse --verify --quiet "refs/tags/v$1" >/dev/null; then
        refuse "v$1 is already tagged - a burned version is never gated again (SM064)." \
            "NEXT_VERSION rolls in the post-release record; gate after it lands."
    fi
}
if [ -z "$VERSION" ]; then
    # Burned first: just after a cut, NEXT_VERSION still names the version cut,
    # and that - not a disagreement with the proposal - is what to say.
    [ -z "$NEXT" ] || burned "$NEXT"
    if [ -n "$PROPOSED" ] && [ -n "$NEXT" ] && [ "$PROPOSED" != "$NEXT" ]; then
        refuse "NEXT_VERSION at ${SHA:0:12} says $NEXT; release.sh would propose $PROPOSED (from $LAST_TAG)." \
            "Not guessing which is meant: pass --version once the release manager has said."
    fi
    VERSION=${NEXT:-$PROPOSED}
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || refuse "no usable version ('$VERSION'); pass --version X.Y.Z"
burned "$VERSION"

# --- already gated? ----------------------------------------------------------
GATE_DIR="$ROOT/tmp/release-gate"
RECEIPT_DIR="$GATE_DIR/$VERSION"
RECEIPT="$RECEIPT_DIR/receipt"
field() { sed -n "s/^$1=//p" "$RECEIPT" 2>/dev/null | head -1; }

STAMP=$(git -C "$ROOT" show "$SHA:starter/docs/ai-briefing-practice.md" 2>/dev/null \
    | sed -n 's/^[[:space:]]*engine-version:[[:space:]]*\([0-9.]*\).*/\1/p' | head -1 || true)
REHEARSE=()
WANT=pass
if [ -n "$STAMP" ] && [ "$STAMP" != "$VERSION" ]; then
    REHEARSE=(--rehearse)
    WANT=rehearsal
fi

if [ -f "$RECEIPT" ] && [ "$(field sha)" = "$SHA" ] && [ "$(field version)" = "$VERSION" ] \
    && [ "$(field channel)" = "$CHANNEL" ] && [ "$(field result)" = "$WANT" ]; then
    echo "gate-main: ${SHA:0:12} ($VERSION, $CHANNEL) is already gated - not running it again:"
    sed 's/^/    /' "$RECEIPT"
    exit 0
fi

# --- one at a time ------------------------------------------------------------
mkdir -p "$RECEIPT_DIR"
exec 9>"$GATE_DIR/.gate-main.lock"
if ! flock -n 9; then
    refuse "another gate-main run holds $GATE_DIR/.gate-main.lock; wait for it."
fi

if [ -f "$RECEIPT" ]; then
    echo "gate-main: superseding the receipt for $(field sha) ($(field result), $(field finished))"
fi
if [ "$WANT" = rehearsal ]; then
    echo "gate-main: main is not cut-ready - the practice briefing is stamped $STAMP, not $VERSION -"
    echo "gate-main: so this is a REHEARSAL: every gate step, a receipt build refuses, coverage kept."
fi

LOG="$RECEIPT_DIR/gate-main.log"
echo "gate-main: gating ${SHA:0:12} ($REF) as $VERSION, $CHANNEL; output in $LOG"
START=$(date +%s)
RC=0
# 9>&- : the lock is this script's, not the gate's - a process the gate leaves
# behind must not hold it for ever.
setsid -w bash "$ROOT/tools/release.sh" gate "$VERSION" --commit "$SHA" \
    "${CHANNEL_FLAG[@]}" "${STAGE_FLAG[@]}" "${REHEARSE[@]}" </dev/null >"$LOG" 2>&1 9>&- || RC=$?
SECS=$(($(date +%s) - START))

if [ "$RC" -ne 0 ] || [ "$(field sha)" != "$SHA" ] || [ "$(field result)" != "$WANT" ]; then
    echo "gate-main: the gate FAILED for ${SHA:0:12} (exit $RC, ${SECS}s). Last lines of $LOG:" >&2
    tail -20 "$LOG" >&2
    exit 1
fi
echo "gate-main: $(field result) for ${SHA:0:12} ($VERSION, $CHANNEL) in ${SECS}s;" \
    "coverage $(field coverage) ($(field coverage_from))"
echo "gate-main: receipt $RECEIPT"
