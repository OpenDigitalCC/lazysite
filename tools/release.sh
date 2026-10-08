#!/bin/bash
# tools/release.sh - gate, build and publish a lazysite release.
#
#   land -> (auto) gate -> "cut X" -> build -> publish
#
#   The release manager lands branches; tools/gate-main.sh gates main's tip after
#   each landing, unattended. When the release manager says "cut X", Claude runs
#   `build`. The release manager then runs `publish`, which pushes main and the
#   tag together. Nobody waits for a test: the gate has run before the call.
#
# Usage:
#   tools/release.sh gate    VERSION [--commit SHA] [--beta|--final|--certified]
#   tools/release.sh build   VERSION --notes FILE   [--beta|--final|--certified]
#   tools/release.sh publish VERSION
#
#   GATE (Claude, detached, usually via tools/gate-main.sh): clones the commit
#   into a stage, writes the release material into it with
#   tools/release-material.pl - the CHANGELOG section with every PENDING ref
#   stamped, the FEATURES entry, VERSION/NEXT_VERSION, the practice briefing,
#   the doc index, the archive at a new minor - with a placeholder subtitle, and
#   runs the full suite, the bench, coverage, the manifest, SBOM and man-page
#   checks on that tree. A pass writes a receipt for the commit under
#   tmp/release-gate/VERSION/, with every log beside it. So the gate tests what
#   will ship, and main can pass a gate at any moment.
#
#   BUILD (Claude, minutes): needs a passing receipt for main's tip. It writes
#   the release material into a worktree of main with the notes' subtitle and
#   FEATURES text, adds the GATE-LOG row and the gate's coverage record, and
#   makes ONE release commit on top of main. It refuses unless that commit
#   touches only the release-material paths (release-material.pl --paths) and
#   the lints that read them pass on it. It then packages from the commit -
#   tarball, the four .debs, the claude.ai skill - tags it LOCALLY, and moves
#   local main to it. A stable cut adds a second commit replacing download/.
#   Any failure leaves main and the tags exactly as they were.
#
#   PUBLISH (the release manager - the one step that is theirs, and the only one
#   that touches the network): pushes main and the tag together, atomically.
#   Refused when origin's main is not an ancestor of local main (no force) or
#   the tag is already on origin (a burned version is never reused, SM064).
#
#   NOTES FILE (build): a header block ended by a blank line, then the tag
#   annotation. Subtitle and Features are required; Assisted-by (required) and
#   Claude-Session become the release commit's trailers:
#
#     Subtitle: an install says whether the site works
#     Features: Provision ends by running the health check (SM933) ...
#       continuation lines indented
#     Assisted-by: Claude:claude-opus-5-5[1m]
#     Claude-Session: https://claude.ai/code/session_...
#
#     lazysite 0.15.3 (edge)
#     ...the annotation...
#
#   NO STEP CAN PROMPT FOR A PASSWORD. Gate and build steps run under
#   `setsid -w` with stdin from /dev/null, so there is no controlling terminal:
#   anything that reaches for sudo or polkit fails, visibly, in the log, instead
#   of stopping the release on a prompt (2026-10-04). This script never calls
#   sudo, systemctl or pkexec - t/lint/208 pins that.
#
#   Channels: edge (default) < --beta < --final (alias --stable) < --certified
#   (ADR 0010: the signed declaration, restore rehearsal and pentest posture
#   block a certified cut). LAZYSITE_SKIP_DEB=1 cuts a tarball-only release and
#   says so. --stage-dir DIR (or LAZYSITE_STAGE_DIR) says where the stage goes;
#   --keep-stage keeps a successful one. A failed stage is always kept, and the
#   next run removes it.
set -e

# The repository this script belongs to - the one it gates, builds and tags.
ORIGIN=$(cd "$(dirname "$0")/.." && pwd)

# SM328: where the gate runs, taken from the environment rather than hard-coded.
#
# This was /tmp/lazysite-release-$$. On a host whose /tmp is a tmpfs the gate
# EXHAUSTS ITS INODES - not its bytes. Devel::Cover writes one runs/<id>/
# directory per instrumented PROCESS at ~6 files each, and this suite drives real
# CGI subprocesses rather than mocking them, so a full gate produces hundreds of
# thousands of them. Measured at the failure: 4.8G tmpfs, 139M used (3%), and
# 1048576/1048576 inodes (100%).
#
# Bytes were never the constraint, which is why "14G free on /" was such a
# misleading reading, and why a size-only pre-flight check would have passed
# cheerfully. A larger tmpfs would not have helped either - only more inodes, or
# a filesystem that does not cap them.
#
# tools/lazysite-cli.pl already honours $TMPDIR for its own scratch; this is that
# convention, applied to the tool that needs it most.
STAGE_BASE="${LAZYSITE_STAGE_DIR:-${TMPDIR:-/tmp}}"
KEEP_STAGE=0

# --- arg parse ---

VERSION=""
NOTES_FILE=""
COMMIT_REF=""
CHANNEL="edge"          # ladder: edge (default) < beta < stable < certified

# SM303: THREE JOBS THAT SHARE ONLY A VERSION NUMBER.
#
#   gate     the tree, the toolchain, CPU - the hour of tests. No remote.
#   build    the release commit, the packages and the LOCAL tag. No remote.
#   publish  remote credentials, and the judgement that this release should
#            exist upstream. Needs nothing else.
#
# Conflating build and publish cost two flags and two failures pointing
# opposite ways: a fetch under `set -e` aborted a build host that had no
# credentials before a single gate step ran, and the repair then died at the
# LAST step on `git push`, leaving a gated, built and tagged release reporting
# exit 128. Naming the job removes the flag that had to remember which host it
# was on.
MODE=""
case "${1:-}" in
    build|publish|gate) MODE=$1; shift ;;
    -h|--help)     ;;
    *)
        # Not a silent fallback to either. The old form's failure modes are the
        # reason this split exists, so guessing which half was meant would
        # preserve them.
        if [ $# -gt 0 ]; then
            echo "release.sh: say which job. Building needs no remote access;" >&2
            echo "release.sh: publishing needs nothing else." >&2
            echo "release.sh:" >&2
            echo "release.sh:   tools/release.sh build   VERSION --notes FILE" >&2
            echo "release.sh:   tools/release.sh publish VERSION" >&2
            echo "release.sh:" >&2
            echo "release.sh: The single-command form did both and could fail at" >&2
            echo "release.sh: either end for reasons belonging to the other (SM303)." >&2
            exit 2
        fi
        ;;
esac

while [ $# -gt 0 ]; do
    case "$1" in
        --notes)
            NOTES_FILE="$2"
            shift 2
            ;;
        --commit)
            COMMIT_REF="$2"
            shift 2
            ;;
        --final|--stable)
            CHANNEL="stable"
            shift
            ;;
        --beta)
            CHANNEL="beta"
            shift
            ;;
        --certified)
            CHANNEL="certified"
            shift
            ;;
        --stage-dir)
            STAGE_BASE="$2"
            shift 2
            ;;
        --keep-stage)
            KEEP_STAGE=1
            shift
            ;;
        -h|--help)
            sed -n '2,65p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        -*)
            echo "release.sh: unknown flag '$1'" >&2
            echo "release.sh: run with --help for usage." >&2
            exit 2
            ;;
        *)
            if [ -z "$VERSION" ]; then
                VERSION="$1"
            else
                echo "release.sh: extra argument '$1'" >&2
                exit 2
            fi
            shift
            ;;
    esac
done

# --- publish: the push, and the only network this script touches -------------
#
# SM303. Everything below is gate or build and none of it runs here. Publish
# needs the tag to exist locally (so it cannot invent one) and to be on local
# main (build put it there), needs the remote (so it fails honestly on a host
# without credentials rather than half way through), and does nothing else.
#
# MAIN AND THE TAG GO TOGETHER (SM971): the tag names the release commit, which
# is on local main and nowhere else. `--atomic` pushes both or neither, and
# nothing is forced: origin's main must already be an ancestor of local main.
if [ "$MODE" = publish ]; then
    if [ -z "$VERSION" ]; then
        echo "release.sh: publish needs a version, e.g. release.sh publish 0.10.14" >&2
        exit 2
    fi
    TAG="v$VERSION"

    if ! git -C "$ORIGIN" rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null; then
        echo "release.sh: $TAG not found locally. Build it first:" >&2
        echo "release.sh:   tools/release.sh build $VERSION --notes FILE" >&2
        exit 1
    fi
    TAG_SHA=$(git -C "$ORIGIN" rev-parse "$TAG^{commit}")
    LOCAL_MAIN=$(git -C "$ORIGIN" rev-parse --verify --quiet refs/heads/main || true)
    if [ -z "$LOCAL_MAIN" ] || ! git -C "$ORIGIN" merge-base --is-ancestor "$TAG_SHA" "$LOCAL_MAIN"; then
        echo "release.sh: $TAG ($TAG_SHA) is not on local main. build puts the release" >&2
        echo "release.sh: commit on main; a tag anywhere else is a release no branch traces." >&2
        exit 1
    fi

    echo "==> Asking origin for main and $TAG"
    if ! REMOTE_REFS=$(git -C "$ORIGIN" ls-remote origin refs/heads/main "refs/tags/$TAG"); then
        echo "release.sh: cannot reach origin. Publishing is the half that" >&2
        echo "release.sh: needs credentials - run it where they are." >&2
        exit 1
    fi
    if printf '%s\n' "$REMOTE_REFS" | grep -q "refs/tags/$TAG\$"; then
        echo "release.sh: $TAG is ALREADY on origin. A burned version is never" >&2
        echo "release.sh: reused (SM064) - cut a new one." >&2
        exit 1
    fi
    REMOTE_MAIN=$(printf '%s\n' "$REMOTE_REFS" | awk '$2 == "refs/heads/main" { print $1 }')
    if [ -n "$REMOTE_MAIN" ]; then
        if ! git -C "$ORIGIN" cat-file -e "$REMOTE_MAIN^{commit}" 2>/dev/null; then
            git -C "$ORIGIN" fetch --quiet origin main || true
        fi
        if ! git -C "$ORIGIN" merge-base --is-ancestor "$REMOTE_MAIN" "$LOCAL_MAIN" 2>/dev/null; then
            echo "release.sh: origin's main ($REMOTE_MAIN) is not an ancestor of local main" >&2
            echo "release.sh: ($LOCAL_MAIN). Pushing would discard commits on origin, and" >&2
            echo "release.sh: publish never forces. Reconcile main first, then publish." >&2
            exit 1
        fi
    fi

    echo "==> Pushing main ($LOCAL_MAIN) and $TAG ($TAG_SHA) together"
    git -C "$ORIGIN" push --atomic origin "$LOCAL_MAIN:refs/heads/main" "refs/tags/$TAG:refs/tags/$TAG"
    echo ""
    echo "==> Published $TAG"
    exit 0
fi

if [ -z "$MODE" ]; then
    sed -n '2,65p' "$0" | sed 's/^# \?//'
    exit 0
fi

# A version is always given: gate-main.sh decides it for a gate, and the
# release manager's "cut X" names it for a build. Nothing here prompts.
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "release.sh: '$VERSION' is not a valid semver (X.Y.Z); $MODE needs VERSION" >&2
    exit 2
fi

TAG="v$VERSION"

# Q14b: asked of git, not of a `.git` DIRECTORY - in a worktree it is a file.
if ! git -C "$ORIGIN" rev-parse --git-dir >/dev/null 2>&1; then
    echo "release.sh: no git repo at $ORIGIN" >&2
    exit 1
fi
# Q14b: THE STATE LIVES IN THE MAIN CHECKOUT, wherever the code runs from.
# Receipts, the coverage store and the lock go under the repository's main
# working tree (the parent of git's common dir), so a gate run from a
# `git worktree` - which keeps the tree it reads stable while development
# switches branches in the main checkout - leaves its receipt where build looks.
STATE_ROOT=$(git -C "$ORIGIN" rev-parse --path-format=absolute --git-common-dir)
STATE_ROOT=$(dirname "$STATE_ROOT")

# SM303: GATE AND BUILD NEVER TOUCH THE REMOTE. The origin check belongs to
# publish, where the credentials and the judgement are.
echo "==> Working locally; origin is not consulted (publish does that)"

# The LOCAL check - the one this host can answer.
if git -C "$ORIGIN" rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null; then
    echo "release.sh: tag $TAG already exists locally" >&2
    exit 1
fi

RECEIPT_DIR="$STATE_ROOT/tmp/release-gate/$VERSION"
RECEIPT="$RECEIPT_DIR/receipt"
receipt_field() { sed -n "s/^$1=//p" "$RECEIPT" 2>/dev/null | head -1; }

# The release date, written into the CHANGELOG heading and the FEATURES entry.
REL_DATE=$(date +%Y-%m-%d)

if [ "$MODE" = gate ]; then
    # The gate has no notes - its subtitle and FEATURES prose are placeholders -
    # and it gates one commit, main's tip unless told otherwise. The ref is
    # resolved HERE, in the repository, not inside the stage clone: a clone
    # carries only the launching worktree's branch, and `--commit main` from a
    # worktree on a feature branch was once "unknown revision" (0.14.3).
    if [ -n "$NOTES_FILE" ]; then
        echo "release.sh: the gate takes no notes - build writes them into the release commit" >&2
        exit 2
    fi
    TARGET_SHA=$(git -C "$ORIGIN" rev-parse --verify --quiet "${COMMIT_REF:-main}^{commit}") || {
        echo "release.sh: '${COMMIT_REF:-main}' does not name a commit in $ORIGIN" >&2
        exit 1
    }
fi

if [ "$MODE" = build ]; then
    # BUILD BUILDS MAIN'S TIP. The commit it makes goes on main, so there is no
    # other commit it could sensibly build from.
    if [ -n "$COMMIT_REF" ]; then
        echo "release.sh: build takes no --commit - it builds main's tip, whose gate receipt it needs" >&2
        exit 2
    fi
    if [ -z "$NOTES_FILE" ] || [ ! -f "$NOTES_FILE" ]; then
        echo "release.sh: build needs --notes FILE (the subtitle, the FEATURES text, the" >&2
        echo "release.sh: trailers and the tag annotation; see --help). Got: '${NOTES_FILE:-none}'" >&2
        exit 2
    fi
    NOTES_FILE=$(cd "$(dirname "$NOTES_FILE")" && pwd)/$(basename "$NOTES_FILE")

    MAIN_SHA=$(git -C "$ORIGIN" rev-parse --verify --quiet refs/heads/main) || {
        echo "release.sh: no local main in $ORIGIN" >&2
        exit 1
    }
    if ! git -C "$ORIGIN" cat-file -e "$MAIN_SHA:tools/release-material.pl" 2>/dev/null; then
        echo "release.sh: main ($MAIN_SHA) has no tools/release-material.pl to build with" >&2
        exit 1
    fi
    material_at_main() { git -C "$ORIGIN" show "$MAIN_SHA:tools/release-material.pl" | perl - "$@"; }

    # The notes are read before anything else, so a missing header is a
    # second's refusal rather than a stage's.
    if ! TRAILERS=$(material_at_main --notes "$NOTES_FILE" --print trailers) \
        || ! SUBTITLE=$(material_at_main --notes "$NOTES_FILE" --print subtitle); then
        echo "release.sh: the notes file is not usable (above)" >&2
        exit 2
    fi
    if ! printf '%s\n' "$TRAILERS" | grep -q '^Assisted-by: '; then
        echo "release.sh: the notes file has no 'Assisted-by:' header - the release commit" >&2
        echo "release.sh: carries the same trailers as every other commit Claude makes." >&2
        exit 2
    fi
    if ! material_at_main --notes "$NOTES_FILE" --print annotation | grep -q '[^[:space:]]'; then
        echo "release.sh: the notes file has nothing after its header - that is the tag annotation" >&2
        exit 2
    fi

    # A RECEIPT COUNTS ONLY FOR THE COMMIT, VERSION AND CHANNEL IT NAMES, and
    # only from a gate that wrote the release material into what it tested.
    if [ ! -f "$RECEIPT" ]; then
        echo "release.sh: no gate receipt for $VERSION at $RECEIPT." >&2
        echo "release.sh: gate main's tip first: tools/gate-main.sh --version $VERSION" >&2
        exit 1
    fi
    TARGET_SHA=$(receipt_field sha)
    if [ "$(receipt_field version)" != "$VERSION" ] || [ "$(receipt_field channel)" != "$CHANNEL" ] \
        || [ "$(receipt_field result)" != pass ] || [ -z "$(receipt_field material_tool)" ]; then
        echo "release.sh: the gate receipt does not match this build:" >&2
        echo "release.sh:   receipt: sha=$TARGET_SHA version=$(receipt_field version) channel=$(receipt_field channel) result=$(receipt_field result) material_tool=$(receipt_field material_tool)" >&2
        echo "release.sh:   build:   version=$VERSION channel=$CHANNEL (a receipt with no material_tool" >&2
        echo "release.sh:            is from a gate that did not test the release material)" >&2
        exit 1
    fi
    echo "==> Gate passed for ${TARGET_SHA:0:12} ($(receipt_field finished)): $(receipt_field files) files, $(receipt_field tests) tests"
    echo "==>   coverage: $(receipt_field coverage) $(receipt_field coverage_from)"
    echo "==>   receipt and logs: $RECEIPT_DIR"

    # MAIN MAY HAVE MOVED PAST THE GATE ONLY THROUGH RELEASE MATERIAL. Those
    # paths are exactly what this build rewrites and then re-checks with the
    # lints that read them, so a landing that only touched them - a PENDING ref
    # stamped by hand after the generator refused it, a FEATURES wording fix -
    # changes nothing the hour-long gate measured. Anything else needs a gate.
    if [ "$TARGET_SHA" != "$MAIN_SHA" ]; then
        if ! git -C "$ORIGIN" merge-base --is-ancestor "$TARGET_SHA" "$MAIN_SHA" 2>/dev/null; then
            echo "release.sh: main ($MAIN_SHA) does not descend from the gated commit" >&2
            echo "release.sh: ($TARGET_SHA). Gate main's tip: tools/gate-main.sh --version $VERSION" >&2
            exit 1
        fi
        MOVED=$(git -C "$ORIGIN" log --format= --name-only "$TARGET_SHA..$MAIN_SHA" | sort -u | grep . || true)
        OUTSIDE=$(printf '%s\n' "$MOVED" | grep -vxF -f <(material_at_main --paths) || true)
        if [ -n "$OUTSIDE" ]; then
            echo "release.sh: main has moved past the gated commit ${TARGET_SHA:0:12} and changed" >&2
            echo "release.sh: more than release material - a new gate is needed:" >&2
            printf '%s\n' "$OUTSIDE" | sed 's/^/release.sh:   /' >&2
            echo "release.sh: tools/gate-main.sh --version $VERSION" >&2
            exit 1
        fi
        echo "==> main moved past the gated commit ${TARGET_SHA:0:12} only in release material:"
        printf '%s\n' "$MOVED" | sed 's/^/      /'
    fi

    # Where main is checked out, if anywhere: the build moves main, and a
    # worktree on main moves with it - which needs that worktree clean. Asked
    # now, not after the packages are built.
    MAIN_WT=$(git -C "$ORIGIN" worktree list --porcelain \
        | awk '/^worktree /{ wt = substr($0, 10) } $0 == "branch refs/heads/main" { print wt }')
    if [ -n "$MAIN_WT" ] && [ -n "$(git -C "$MAIN_WT" status --porcelain --untracked-files=no)" ]; then
        echo "release.sh: main is checked out at $MAIN_WT with uncommitted changes, and" >&2
        echo "release.sh: build moves main. Commit or move them first:" >&2
        git -C "$MAIN_WT" status --short --untracked-files=no >&2
        exit 1
    fi
fi

# --- the stage: a clone (gate) or a worktree of main (build) ---

# SM328: the staging path, and a trap that removes it however this run ends.
#
# Cleanup used to be `rm -rf "$STAGE"` as the last line of the happy path, so any
# failure - a failing test, a refused gate, an interrupt, a power cut, the disk
# filling - left the whole clone behind. Four cuts in a day was enough to exhaust
# a tmpfs, and nothing reclaimed them.
#
# SM895 G3: A FAILED RUN KEEPS ITS STAGE. The first 0.14.3 cut ran the
# instrumented suite for two hours, the report step printed nothing, and the
# trap removed the database it had failed to report on - so the second attempt
# was launched blind and failed the same way. A gate failure is exactly when
# somebody wants to look inside, and "re-run with --keep-stage" is advice for a
# run that has already thrown the evidence away.
#
# The reconciliation with SM328 is prune_dead_stages, below: a run tidies its
# predecessors at START, when it can tell which of them are dead, so at most
# one failed stage sits on the filesystem at a time and a live run is never
# touched. Success still removes (--keep-stage keeps even then).
#
# SM971: a build stage is a WORKTREE of this repository, so the release commit it
# makes is already here when main is moved to it. A removed worktree leaves an
# entry that `git worktree prune` clears, and both removals below prune.
STAGE="$STAGE_BASE/lazysite-release-$$"
cleanup_stage() {
    local rc="${1:-0}"
    [ "$KEEP_STAGE" = 1 ] && return 0
    [ "$rc" -ne 0 ] && return 0
    rm -rf "$STAGE"
    git -C "$ORIGIN" worktree prune 2>/dev/null || true
}
trap 'cleanup_stage $?' EXIT

# SM560: every abort names what became of the stage - and it must be TRUE.
# Eleven abort paths printed "staging dir retained" while the trap above
# removed it, so the first diagnostic step after any gate failure was a dead
# end. Since SM895 G3 an abort keeps the stage, so the sentence is one sentence
# - and it says when the directory goes, because the answer used to be "now".
stage_disposition() {
    echo "release.sh: staging dir retained: $STAGE" >&2
    echo "release.sh:   (a failed stage is kept for inspection and removed at the start" >&2
    echo "release.sh:   of the next run; --keep-stage keeps a successful one too)" >&2
}

# SM895 G3: the other half of keeping a failed stage - the next run removes it.
#
# Every lazysite-release-PID directory under STAGE_BASE whose PID is not alive
# is a previous run's leftover: a failure kept for inspection (the point of
# keeping it was to read it before the next cut, not to collect it), or a run
# that died without reaching its trap. A directory whose PID is alive is a
# concurrent cut and is left alone; so is this run's own. The logs a run keeps
# BESIDE its stage (PID-coverage-*.txt) are files, not directories, and stay:
# they are the evidence that outlives the clone by design (SM736b, SM895 G1).
prune_dead_stages() {
    local d pid
    for d in "$STAGE_BASE"/lazysite-release-*; do
        [ -d "$d" ] || continue
        pid="${d##*-}"
        case "$pid" in ''|*[!0-9]*) continue ;; esac
        [ "$pid" = "$$" ] && continue
        if kill -0 "$pid" 2>/dev/null; then
            echo "release.sh: stage $d belongs to a live process ($pid); left alone." >&2
            continue
        fi
        echo "release.sh: removing the stage a previous run left behind: $d" >&2
        rm -rf "$d"
    done
    git -C "$ORIGIN" worktree prune 2>/dev/null || true
}

# Every gate failure said the same three things in the same order: what failed,
# what became of the staging directory, and that the build is over. One sentence
# per argument, all with the release.sh prefix.
abort_build() {
    local _line
    for _line in "$@"; do
        echo "release.sh: $_line" >&2
    done
    stage_disposition
    exit 1
}

# N141-02: THE STAGE PATH IS MADE ABSOLUTE BEFORE ANYTHING USES IT.
#
# A RELATIVE --stage-dir DID NOT FAIL - IT PRODUCED A WRONG VERDICT. The gate
# runs as
#
#     GATE_OUT="$STAGE/.gate-output.txt"
#     ( cd "$STAGE" && set -o pipefail && prove -lr t/ 2>&1 | tee "$GATE_OUT" )
#
# and the `cd` is load-bearing (see its own note below). With a relative $STAGE
# the path in $GATE_OUT no longer resolves once we are inside it, so `tee` dies
# with "No such file or directory", pipefail propagates, and the run is reported
# as `test suite failed; not releasing.`
#
# Observed on the 0.13.16 cut: the suite printed "All tests successful. Result:
# PASS" and the script refused the release on the next line. A wrong path
# inverted the RESULT rather than raising an error, which is the worst available
# behaviour - a green suite read as red, and (had the polarity gone the other
# way) a red one could read as green.
#
# Resolved rather than refused, because a relative path is a reasonable thing to
# type and there is nothing wrong with it until the cd. `mkdir -p` first so the
# path exists to be resolved; `cd -P ... && pwd` rather than realpath, which is
# not everywhere.
mkdir -p "$STAGE_BASE"
case "$STAGE_BASE" in
    /*) ;;
    *)
        STAGE_BASE=$( cd -P "$STAGE_BASE" && pwd ) || {
            echo "release.sh: --stage-dir '$STAGE_BASE' cannot be resolved; not releasing." >&2
            exit 1
        }
        echo "==> stage dir resolved to $STAGE_BASE (it was relative; the gate cd's into it)"
        ;;
esac

# SM895 G3: before measuring the room, make it - the previous run's kept
# stage is the largest thing that could be sitting there.
prune_dead_stages

# `df -i --output=...` is REFUSED by coreutils - the options are mutually
# exclusive - and the first version of this check used it, so the variable was
# empty and the check silently did nothing. A guard that skips when it cannot
# read its input is the defect this whole file is about, so an unreadable
# reading is now reported rather than passed over.
_free_inodes=$(df --output=iavail "$STAGE_BASE" 2>/dev/null | tail -1 | tr -d ' ')
_free_kb=$(df --output=avail "$STAGE_BASE" 2>/dev/null | tail -1 | tr -d ' ')

case "${_free_inodes:-}" in
    ''|*[!0-9]*)
        echo "release.sh: could not read free inodes for $STAGE_BASE - not checking." >&2
        _free_inodes=""
        ;;
esac

# SM896: THE NUMBER IS MEASURED, NOT REMEMBERED. This said "roughly 1.1M" and
# refused below 1.2M. The 0.14.3 cut needed 4.15M - Devel::Cover leaks one
# lock file per structure file per process, 4,131,376 of them - on a
# filesystem with 4.75M in total; it passed this check twice and wedged the
# host twice. coverage.sh now reaps those locks as it runs and prints the DB's
# real footprint ("coverage: DB footprint N inode(s)").
#
# MEASURED ON THE FIRST CUT THROUGH THE FIXED GATE (0.14.4): the footprint
# AFTER the final clean was 15,671 inodes for 7,309 runs - but the PEAK during
# the run is what the filesystem has to hold, and mid-run there were 133,149
# live locks: the population younger than the reaper's one-minute threshold,
# ~100 processes a minute x ~574 files each. With the clone (~11k) the peak is
# ~170k. The first version of this floor said 200k against an estimate of
# "a few thousand live locks" - inside the truth, but by a margin that would
# not survive a slower host. 500k is the peak with room. Before trusting this
# number again, read the footprint line from the last gate's coverage log,
# and remember it is the post-clean figure, not the peak.
if [ -n "$_free_inodes" ] && [ "$_free_inodes" -gt 0 ] \
   && [ "$_free_inodes" -lt 500000 ]; then
    echo "release.sh: $STAGE_BASE has only $_free_inodes free inodes." >&2
    echo "  A gate run PEAKS at ~170k as measured (0.14.4: ~133k live locks" >&2
    echo "  under the reaper's threshold, plus the clone); 500k is that with" >&2
    echo "  room. Point somewhere with more: --stage-dir DIR, or LAZYSITE_STAGE_DIR." >&2
    exit 5
fi
case "${_free_kb:-}" in ''|*[!0-9]*) _free_kb="" ;; esac
if [ -n "$_free_kb" ] && [ "$_free_kb" -lt 2000000 ]; then
    echo "release.sh: $STAGE_BASE has only $((_free_kb/1024))MB free; ~2GB wanted." >&2
    echo "  Point somewhere larger: --stage-dir /srv/tmp, or LAZYSITE_STAGE_DIR." >&2
    exit 5
fi


# NO TERMINAL REACHES A GATE OR BUILD STEP. `setsid -w` starts each one in a new
# session with no controlling terminal and stdin from /dev/null, so sudo cannot
# ask for a password and polkit has no agent to ask with: a test that reaches
# for either FAILS, in the log, rather than stopping a release on a prompt. The
# exit status is passed through (-w), so the verdict is unchanged.
detached() { setsid -w "$@" </dev/null; }

if [ "$MODE" = gate ]; then
    echo "==> Staging clone at $STAGE"
    git clone --quiet "$ORIGIN" "$STAGE"
    git -C "$STAGE" checkout --quiet --detach "$TARGET_SHA"
    # The clone names this repository's main origin/main, and has a local main
    # only when the launching worktree was on it. Lint 53 asks whether every
    # stamped ref is on main, so the stage has the same main this repository has.
    if MAIN_NOW=$(git -C "$ORIGIN" rev-parse --verify --quiet refs/heads/main); then
        git -C "$STAGE" branch --quiet -f main "$MAIN_NOW"
    fi
    echo "==> Target commit: $TARGET_SHA"
else
    echo "==> Staging a worktree of main ($MAIN_SHA) at $STAGE"
    git -C "$ORIGIN" worktree add --quiet --detach "$STAGE" "$MAIN_SHA"
fi

# --- the release material (SM971) ---------------------------------------------
#
# ONE GENERATOR, IN BOTH JOBS. tools/release-material.pl writes the CHANGELOG
# section (every PENDING ref stamped with its landed SHA, or a refusal naming
# the entry), the FEATURES entry, VERSION/NEXT_VERSION, the practice briefing,
# the doc index and, at a new minor, the archive move. The gate runs it with no
# notes - a placeholder subtitle and FEATURES text - so what it tests differs
# from what ships only in that prose; the build runs it with the notes.
#
# This replaces the pre-cut pass, a landing that had to happen before main could
# pass a gate at all (the practice briefing's version stamp, lint 89), and the
# VERSION stamp this script used to write into the stage (SM375, SM383): the
# generator sets the pair through tools/bump-version.pl, BEFORE the compliance
# gate, the manifest, the SBOM check and the tarball read it.
MATERIAL_TOOL=$(sha256sum "$STAGE/tools/release-material.pl" 2>/dev/null | awk '{print $1}')
if [ -z "$MATERIAL_TOOL" ]; then
    abort_build "the commit has no tools/release-material.pl; not releasing."
fi
if [ "$MODE" = build ] && [ "$MATERIAL_TOOL" != "$(receipt_field material_tool)" ]; then
    abort_build "tools/release-material.pl differs from the one the gate ran" \
        "(gate $(receipt_field material_tool), build $MATERIAL_TOOL); gate main's tip again."
fi
MATERIAL_ARGS=("$VERSION" --dir "$STAGE" --channel "$CHANNEL" --date "$REL_DATE")
if [ "$MODE" = build ]; then
    MATERIAL_ARGS+=(--notes "$NOTES_FILE")
fi
echo "==> release-material.pl ${MATERIAL_ARGS[*]}"
if ! perl "$STAGE/tools/release-material.pl" "${MATERIAL_ARGS[@]}"; then
    abort_build "the release material could not be written (above); not releasing."
fi

# The release-material allowlist, from the generator that owns it.
material_paths() { perl "$STAGE/tools/release-material.pl" --paths; }

# Paths a commit range touched outside a list of allowed paths (or prefixes,
# when the list entry ends in /), one per line; nothing when it stayed inside.
outside_of() {
    local from=$1 to=$2 allowed=$3 p a ok
    git -C "$STAGE" diff --name-only "$from" "$to" | while IFS= read -r p; do
        ok=0
        while IFS= read -r a; do
            case "$a" in
                */) case "$p" in "$a"*) ok=1 ;; esac ;;
                *) [ "$p" = "$a" ] && ok=1 ;;
            esac
        done <<< "$allowed"
        [ "$ok" = 1 ] || printf '%s\n' "$p"
    done
}

if [ "$MODE" = gate ]; then
    # Committed IN THE STAGE ONLY, so the suite runs on a clean tree exactly as
    # the release commit will be. The clone is thrown away; nothing leaves it.
    git -C "$STAGE" add -A
    git -C "$STAGE" -c user.name="lazysite gate" -c user.email="gate@lazysite.invalid" \
        commit --quiet -m "Release material for $VERSION (gate stage only)"
    MATERIAL_SHA=$(git -C "$STAGE" rev-parse HEAD)
fi

if [ "$MODE" = build ]; then
    # --- the GATE-LOG row and the coverage record, INTO the release commit -----
    #
    # SM400: the manifest inside the artefact attests the gate; GATE-LOG is the
    # copy that answers the same question WITHOUT the artefact, because the
    # question is always asked later, by someone who has the repo. Its Commit
    # column is the GATED commit: the release commit cannot name itself, and it
    # differs from the gated one only by the release material.
    #
    # Both used to be appended to the working tree UNCOMMITTED and landed by a
    # post-release record branch. They are part of the release commit now, so
    # there is no second landing and no record to remember.
    GATE_FILES=$(receipt_field files)
    GATE_TESTS=$(receipt_field tests)
    GATE_LOG="$STAGE/docs/releases/GATE-LOG.md"
    mkdir -p "$STAGE/docs/releases"
    if [ ! -f "$GATE_LOG" ]; then
        {
            printf -- '---\n'
            printf 'title: "lazysite - release gate record"\n'
            printf 'subtitle: "Which commit each release was validated at, newest last. Appended by tools/release.sh."\n'
            printf 'brand: plain\n'
            printf 'standard-margins: true\n'
            printf -- '---\n\n'
            printf '| Version | Channel | Commit | Files | Tests | Gated (UTC) |\n'
            printf '|---|---|---|---|---|---|\n'
        } > "$GATE_LOG"
    fi
    printf '| %s | %s | `%s` | %s | %s | %s |\n' \
        "$VERSION" "$CHANNEL" "$TARGET_SHA" "$GATE_FILES" "$GATE_TESTS" \
        "$(date -u '+%Y-%m-%d %H:%M')" >> "$GATE_LOG"
    if [ -f "$RECEIPT_DIR/coverage-last.json" ]; then
        mkdir -p "$STAGE/dist/config"
        cp "$RECEIPT_DIR/coverage-last.json" "$STAGE/dist/config/coverage-last.json"
    fi

    # --- ONE release commit, on top of main ------------------------------------
    COMMIT_MSG="${STAGE}-release-commit.txt"
    {
        printf 'lazysite %s (%s): %s\n\n' "$VERSION" "$CHANNEL" "$SUBTITLE"
        printf 'The release material for %s, written by tools/release-material.pl on\n' "$VERSION"
        printf 'main at %s. Gated at %s: %s files, %s tests,\n' "${MAIN_SHA:0:12}" "${TARGET_SHA:0:12}" "$GATE_FILES" "$GATE_TESTS"
        printf 'coverage %s. The GATE-LOG row and the coverage record are the gate'"'"'s.\n\n' "$(receipt_field coverage)"
        git -C "$STAGE" status --porcelain | awk '{ print "  " $2 }'
        printf '\n%s\n' "$TRAILERS"
    } > "$COMMIT_MSG"
    git -C "$STAGE" add -A
    git -C "$STAGE" commit --quiet -F "$COMMIT_MSG"
    RELEASE_SHA=$(git -C "$STAGE" rev-parse HEAD)
    echo "==> Release commit $RELEASE_SHA on main $MAIN_SHA (not yet on main)"

    # NOTHING BUT RELEASE MATERIAL. A release commit is reviewed by nobody - the
    # release manager decided the cut, not its diff - so what it may touch is a
    # fixed list, checked rather than trusted.
    OUTSIDE=$(outside_of "$MAIN_SHA" "$RELEASE_SHA" "$(material_paths)")
    if [ -n "$OUTSIDE" ]; then
        abort_build "the release commit touches paths outside the release-material allowlist:" \
            "$(printf '%s ' $OUTSIDE)" "main is unchanged; nothing was tagged."
    fi
    echo "==> The release commit touches only release material"
fi

# --- precondition: sbom-deps.json exists at target ---

if [ ! -f "$STAGE/dist/config/sbom-deps.json" ]; then
    abort_build "dist/config/sbom-deps.json missing at $TARGET_SHA"
fi

# --- gate tooling must EXIST on a release host ---
# The lint gates skip cleanly on a minimal dev host, which is right for
# `prove` in general but wrong for a release: a missing tool would silently
# skip a quality gate (2026-07-10 review, D2). Refuse loudly instead.
for tool in perlcritic perltidy shellcheck; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        abort_build "gate tool '$tool' is not installed on this host; not releasing."
    fi
done

# --- compliance-record currency gate (eight-dimension review 2026-08-14) ---
#
# The review sorted its findings by whether the thing assessed was defended by a
# MECHANISM or maintained by a PERSON, and they separated perfectly: every gate,
# lint and enforced floor passed; every hand-kept compliance record was a
# finding. This gate applies to those records the move this project already made
# four times to hand-maintained lists in its own tests - it replaces a person
# remembering with a build failing.
#
# It runs FIRST because it is instant and it fails on things that take minutes
# to fix, rather than after a 15-minute coverage run. Blocking findings differ by
# channel: a Declaration of Conformity behind the version is advisory below
# certified and blocking on certified (ADR 0010) - the declaration attaches to
# a certified release; stable ships supported software.
echo "==> lazysite-compliance.pl --check (channel: $CHANNEL)"
if ! perl "$STAGE/tools/lazysite-compliance.pl" --check --channel "$CHANNEL"; then
    abort_build "compliance records are not current for this cut; not releasing."
fi

# --- build: the checks that read the release material, on the release commit -
#
# Every lint that names a release-material path, and the briefing's unit test
# (release-material.pl --lints; t/lint/214 keeps the list complete). Seconds to
# a minute, against the gate's hour: the gate already ran them on the same
# material with a placeholder subtitle, and this is the check that the notes'
# prose, the GATE-LOG row and the coverage record broke nothing.
#
# Lint 113 waits for a stable cut's download commit: the GATE-LOG row makes the
# new version the newest stable, and download/ is replaced only after the
# packages exist.
if [ "$MODE" = build ]; then
    MATERIAL_LINTS=$(perl "$STAGE/tools/release-material.pl" --lints --dir "$STAGE") \
        || abort_build "the release-material checks could not be listed (above)."
    if [ "$CHANNEL" = stable ]; then
        MATERIAL_LINTS=$(printf '%s\n' "$MATERIAL_LINTS" | grep -v '^t/lint/113-')
    fi
    LINT_LOG="${STAGE}-material-lints.txt"
    echo "==> the release-material checks on $RELEASE_SHA ($(printf '%s\n' "$MATERIAL_LINTS" | wc -l) files)"
    # shellcheck disable=SC2086  # one argument per file name
    if ! ( cd "$STAGE" && detached prove -l $MATERIAL_LINTS > "$LINT_LOG" 2>&1 ); then
        grep -E '^#   Failed test|\(Wstat|^Failed|not ok' "$LINT_LOG" | head -20 >&2
        abort_build "a check on the release material failed (log: $LINT_LOG)." \
            "main is unchanged; nothing was tagged."
    fi
    grep -E '^Files=' "$LINT_LOG"
fi

# --- the gate: the suite, the bench and coverage (gate only) -------------------
if [ "$MODE" = gate ]; then



# SM950 (3): EVERY PASSING COVERAGE RUN IS KEPT, BY ITS INPUTS DIGEST.
#
# coverage.sh already skips when its inputs match a recorded pass (SM736), but
# the only record it read was the one committed in the tree - written at the
# last release and committed with it. So two gates between
# releases both measured, even when nothing coverage reads had changed: 74
# minutes each on 0.15.2. The store is outside any clone (tmp/ in the origin,
# never committed), one file per digest, and a gate OFFERS coverage.sh the
# record for its own digest; coverage.sh still makes the decision (a pass, and
# a digest equal to the one it computes) and still refuses on anything else.
COV_STORE="$STATE_ROOT/tmp/release-gate/coverage-passes"

# The record to offer for a digest, or nothing.
coverage_offer() {
    local store=$1 digest=$2
    [ -n "$digest" ] || return 0
    [ -f "$store/$digest.json" ] || return 0
    printf '%s\n' "$store/$digest.json"
}

# Where a record's pass was measured, in one line, for the output and receipt.
coverage_origin() {
    perl -MJSON::PP -e '
        local $/; open my $f, "<", $ARGV[0] or exit 1;
        my $j = eval { JSON::PP->new->decode(<$f>) } or exit 1;
        printf "sha=%s version=%s captured=%s digest=%s\n",
            $j->{measured_at_sha} // "unknown(committed-record)", $j->{measured_for_version} // "unknown",
            $j->{captured} // "unknown", $j->{inputs_digest} // "none";
    ' "$1" 2>/dev/null || echo "unreadable record $1"
}

# Keep a passing record, stamped with the gate that measured it - and only one
# whose digest is the one this gate computed, so a stale committed record is
# never kept under this gate's name.
coverage_store() {
    local record=$1 store=$2 sha=$3 version=$4 digest=$5
    mkdir -p "$store"
    perl -MJSON::PP -e '
        my ( $rec, $store, $sha, $ver, $want ) = @ARGV;
        local $/; open my $f, "<", $rec or die "$rec: $!\n";
        my $j = JSON::PP->new->decode(<$f>);
        die "not a pass\n" unless ( $j->{result} // "" ) eq "pass" && $j->{inputs_digest};
        die "record digest $j->{inputs_digest} is not this gate'"'"'s ($want)\n"
            unless $j->{inputs_digest} eq ( $want // "" );
        $j->{measured_at_sha}      = $sha;
        $j->{measured_for_version} = $ver;
        my $out = "$store/$j->{inputs_digest}.json";
        open my $o, ">", "$out.$$" or die "$out: $!\n";
        print {$o} JSON::PP->new->canonical->pretty->encode($j);
        close $o or die "$out: $!\n";
        rename "$out.$$", $out or die "$out: $!\n";
        print "$out\n";
    ' "$record" "$store" "$sha" "$version" "$digest"
}

mkdir -p "$RECEIPT_DIR"
rm -f "$RECEIPT"

# --- run tests ---

# `cd "$STAGE" && prove -lr t/`, and BOTH halves are load-bearing.
#
# -l is not cosmetic. Without it PERL5LIB is never set, so a test's own
# `use lib "$FindBin::Bin/../lib"` covers the test process and NOT the
# subprocesses it spawns - and several tests drive tools/lazysite-check.pl or a
# dev server as children. Those children searched only the system @INC and died
# on "Can't locate Lazysite/Paths.pm". Five files failed this way, and they
# failed identically at v0.10.8, so the gate has been running the suite in a
# configuration the suite does not support rather than the one every other
# caller uses.
#
# The `cd` is what makes -l safe. -l adds ./lib RELATIVE TO CWD, so running it
# from the invoking directory would put the ORIGIN's lib on @INC while running
# the STAGED tests - a gate quietly testing the developer's working copy
# against the release candidate's tests. That is a worse failure than the one
# being fixed, because it passes.
# SM400: CAPTURE WHAT THE GATE ACTUALLY SAID, not just whether it passed.
#
# The gate's own summary line - files, tests, result - went to the terminal and
# nowhere else, so nothing durable recorded WHICH COMMIT had been validated. A
# promotion review three days later found the only record was tmp/gate-result.txt,
# which is gitignored, and had to reconstruct the answer from commit dates. The
# counts are captured here, carried into the manifest below so the ARTEFACT
# attests its own gate, and appended to a tracked log at the end.
#
# tee, and then PIPESTATUS - `if ! ( ... | tee f )` tests TEE's exit status, and
# tee succeeds whatever prove did. That is the failure mode this whole gate
# exists to prevent, one layer up: a check that reports success without checking.
GATE_OUT="$STAGE/.gate-output.txt"
echo "==> Running full test suite"
# SM950 (1): -j4, as the handoff runs it - 17 minutes serial, about 6 parallel.
# The suite is parallel-safe (SM269 phase 1); the host has the memory since
# 2026-10-07. prove's summary line is the same either way.
if ! ( cd "$STAGE" && set -o pipefail && detached prove -lr -j4 t/ 2>&1 | tee "$GATE_OUT" ); then
    abort_build "test suite failed; not releasing."
fi

# "Files=455, Tests=8266, ..." - prove's own summary, read rather than recomputed.
GATE_FILES=$(sed -n 's/^Files=\([0-9]*\),.*/\1/p' "$GATE_OUT" | tail -1)
GATE_TESTS=$(sed -n 's/^Files=[0-9]*, Tests=\([0-9]*\),.*/\1/p' "$GATE_OUT" | tail -1)
if [ -z "$GATE_FILES" ] || [ -z "$GATE_TESTS" ]; then
    abort_build "could not read the gate summary from prove output." \
        "refusing to record a release as validated without it."
fi
echo "==> Gate: $GATE_FILES files, $GATE_TESTS tests, at $TARGET_SHA"

# --- performance gate (eight-dimension review D4) ---
# Committed baseline in dist/config/bench-baseline.json; fails on a gross
# regression. Costs ~5 seconds, so it runs before the slow coverage gate.

echo "==> bench.pl --check"
if ! ( set -o pipefail && detached perl "$STAGE/tools/bench.pl" --check 2>&1 | tee "$RECEIPT_DIR/bench.txt" ); then
    abort_build "benchmark regression; not releasing."
fi

# --- coverage gate (eight-dimension review D3) ---
# Instrumented re-run of the suite against the declared floors in
# dist/config/coverage-floor. Slow - about an hour on the 0.11.8 suite, not
# the 10-15 minutes this said for years;
# converts the recorded coverage evidence from "stale until someone
# remembers" into a per-release fact.

# SM444: DO NOT NAME A CAUSE THIS GATE HAS NOT MEASURED.
#
# This used to map every non-zero exit from coverage.sh onto one sentence:
# "coverage below the declared floor". The 0.10.20 build failed that way and
# coverage was never the problem - coverage.sh had exited BEFORE reaching the
# floor comparison, so no per-file table and no COVERAGE BELOW FLOOR marker
# were printed, and the message asserted a cause nobody had established. It
# cost a 45-minute instrumented re-run and then a second full build to find
# that all eight files were comfortably above their floors.
#
# coverage.sh already says which case it is: it prints a per-file table before
# it decides, and COVERAGE BELOW FLOOR when a floor is genuinely missed. So
# capture the output, key on the marker, and report the two differently. A
# run that DIED is a different problem with a different fix from a run that
# MEASURED something too low, and telling them apart is the whole of this.
#
# The output is captured to a FILE and echoed, not piped through tee: `if !
# ( ... | tee f )` tests tee's exit status, which succeeds whatever the child
# did. t/tools/34 asserts that trap against a failing stand-in, and this gate
# must not reintroduce it.
# The estimate is MEASURED, and was wrong by roughly 4x until 0.11.8: the
# uninstrumented suite takes ~10 minutes and Devel::Cover multiplies that
# several times over. An estimate that understates by 4x is worse than none -
# during the 0.11.8 cut it led to a healthy run being diagnosed as a hang, and
# the next person to look would have reached for the kill.
echo "==> coverage.sh --check (instrumented run; ~1 hour - Devel::Cover is several times the uninstrumented ~10 min)"
# SM444 follow-up: BESIDE the stage, never inside it.
#
# The first version wrote this to $STAGE/coverage-check.txt and the next step
# refused: build-manifest.pl classifies every file in the staged tree and will
# not ship an unclassified one. So the honest-reporting change broke the build
# it was meant to make diagnosable - caught by the manifest gate, and reported
# by the very message this commit added ("manifest build failed", naming the
# file, rather than a sentence about coverage).
#
# A sibling keeps it findable - beside the stage, which the EXIT trap removes
# on failure unless --keep-stage was given (SM560) - without putting it in
# the payload.
COV_LOG="${STAGE}-coverage-check.txt"

# THE SUITE LOG HAS TO OUTLIVE THE STAGE. coverage.sh writes the instrumented
# suite's own output beside its database, which lives INSIDE the staging clone
# - and the clone is removed when the build ends. So the one file that says why
# a coverage gate refused disappeared at exactly the moment it was needed:
# the run reported "the suite did not pass" and then deleted the evidence.
# Alongside COV_LOG, which is already outside the stage for the same reason.
export LAZYSITE_COVER_SUITE_LOG="${STAGE}-coverage-suite.txt"

# SM950 (3): offer coverage.sh a pass an earlier gate recorded for this exact
# input set. Computed here (the stage is quiet: the suite has finished) and
# again by coverage.sh, which decides; LAZYSITE_COVER_FORCE=1 still measures.
COV_DIGEST=$(perl "$STAGE/tools/coverage-inputs.pl" 2>/dev/null | awk '{print $1}')
COV_OFFER=$(coverage_offer "$COV_STORE" "$COV_DIGEST")
if [ -n "$COV_OFFER" ]; then
    # A COPY, beside the stage: a run that measures after all writes its own
    # record to the path it was given, and the store must keep its file.
    cp "$COV_OFFER" "${STAGE}-coverage-offer.json"
    export LAZYSITE_COVER_RECORD="${STAGE}-coverage-offer.json"
    echo "==> coverage inputs digest $COV_DIGEST matches a recorded pass: $(coverage_origin "$COV_OFFER")"
else
    echo "==> coverage inputs digest ${COV_DIGEST:-(none)}: no recorded pass in $COV_STORE"
fi
# SM552: CAPTURED ON THE SAME LINE. Under `set -e` a bare `cmd` followed by
# `STATUS=$?` never reaches the second statement when cmd fails - the script
# died here and the whole verdict block below was unreachable. Not `if !`
# (58 forbids it: that form asserted a cause nobody had measured).
COV_STATUS=0
detached bash "$STAGE/tools/coverage.sh" --check > "$COV_LOG" 2>&1 || COV_STATUS=$?
cat "$COV_LOG"
if [ "$COV_STATUS" -ne 0 ]; then
    # Q14d: THE MARKERS ARE MATCHED AS coverage.sh PRINTS THEM, whole and
    # anchored. The log also holds cover's source listing, which quotes every
    # measured file - including the tests that name these markers - so a bare
    # substring match called a failed SUITE a floor breach (measured on the
    # 2026-10-08 gate of main: three flaky tool tests, "coverage below the
    # declared floor"). That is the SM444 misdiagnosis this block exists to stop.
    if grep -qx 'COVERAGE BELOW FLOOR' "$COV_LOG"; then
        echo "release.sh: coverage below the declared floor; not releasing." >&2
        grep -E 'BELOW' "$COV_LOG" >&2
    elif grep -q '^coverage: THE REPORT STEP FAILED' "$COV_LOG"; then
        # SM895: the suite PASSED and cover(1) could not report on it. Twice
        # on 0.14.3 this was announced as "the instrumented run did not
        # finish", inferred from the absence of a string - and the cause was
        # in the stderr coverage.sh had thrown away. It is kept now, beside
        # the suite log, and the message names the stage that failed.
        echo "release.sh: the instrumented suite PASSED; the coverage REPORT failed." >&2
        echo "release.sh: not a shortfall, not a suite failure - cover's own words:" >&2
        grep -A20 '^coverage: THE REPORT STEP FAILED' "$COV_LOG" >&2
    else
        echo "release.sh: coverage gate FAILED (exit $COV_STATUS) WITHOUT reaching" >&2
        echo "release.sh: the floor comparison - so this is NOT a coverage" >&2
        echo "release.sh: shortfall. The instrumented run did not finish." >&2
        echo "release.sh: last lines of $COV_LOG:" >&2
        tail -15 "$COV_LOG" >&2
    fi
    stage_disposition
    echo "release.sh: coverage output kept at: $COV_LOG" >&2
    exit 1
fi

# SM736b: CARRY THE COVERAGE RECORD BACK, or the feature is inert.
#
# coverage.sh writes dist/config/coverage-last.json relative to ITS OWN root,
# which during a release is the staging clone - and the staging clone is deleted
# when the build finishes. So the record was written into a directory that no
# longer exists, and the skip it exists to license could never fire. Measured
# after the 0.11.12 cut: the file was simply not in the origin repo.
#
# The same shape as the GATE-LOG row, and for the same reason: a fact
# established inside the staging clone is worth nothing unless it is carried
# out of it. It goes to the receipt directory, and build commits it into the
# release commit with the row (SM971).
#
# SM950 (3): which record that is depends on whether coverage was measured.
# Measured: the one coverage.sh just wrote, which also goes into the store for
# the next gate. Reused: the record that licensed the skip - the offered one, or
# the committed one - and the receipt names where its pass came from.
COV_RECORD="$STAGE/dist/config/coverage-last.json"
COV_RECORD="${LAZYSITE_COVER_RECORD:-$COV_RECORD}"
if grep -q '^coverage: SKIPPED' "$COV_LOG"; then
    COV_MODE=reused
    COV_FROM=$(coverage_origin "$COV_RECORD")
    echo "==> coverage REUSED, not re-measured: the pass at $COV_FROM"
else
    COV_MODE=measured
    COV_FROM="sha=$TARGET_SHA version=$VERSION (this gate)"
    if [ -f "$COV_RECORD" ]; then
        coverage_store "$COV_RECORD" "$COV_STORE" "$TARGET_SHA" "$VERSION" "$COV_DIGEST" \
            || echo "release.sh: WARNING - the coverage pass was not kept for reuse" >&2
    fi
fi
if [ -f "$COV_RECORD" ]; then
    # Beside the receipt, never into a working tree: build commits it into the
    # release commit from here.
    cp "$COV_RECORD" "$RECEIPT_DIR/coverage-last.json"
fi


fi    # gate

# --- build the release manifest ---
# release-manifest.json is generated, not tracked (SM065), so the fresh
# clone has none. Build it from the staged tree before the SBOM gate
# (which reads it) and the tarball (which ships it).

echo "==> build-manifest.pl (channel: $CHANNEL)"
if ! perl "$STAGE/tools/build-manifest.pl" \
        --staged  "$STAGE" \
        --out     "$STAGE/release-manifest.json" \
        --version "$VERSION" \
        --channel "$CHANNEL" \
        --commit      "$TARGET_SHA" \
        --gate-files  "$GATE_FILES" \
        --gate-tests  "$GATE_TESTS" ; then
    abort_build "manifest build failed; not releasing."
fi

# --- SBOM strictness gate ---

echo "==> manifest-to-sbom.pl --strict"
if ! perl "$STAGE/tools/manifest-to-sbom.pl" --strict \
        --manifest "$STAGE/release-manifest.json" \
        --deps     "$STAGE/dist/config/sbom-deps.json" \
        --out      "$STAGE/sbom.json" \
        --version  "$VERSION" \
        --staged   "$STAGE" ; then
    abort_build "SBOM strictness check failed; not releasing."
fi

# --- man pages (generated artefact; the tarball must ship them - review D7) ---

echo "==> Generating man pages"
if ! perl "$STAGE/tools/gen-manpages.pl" "$STAGE/man/man1"; then
    abort_build "man-page generation failed; not releasing."
fi
MAN_ADD=()
for m in "$STAGE"/man/man1/*.1; do
    [ -f "$m" ] || continue
    # --add-file stores only the BASENAME; an interleaved --prefix places
    # each page under man/man1/ (restored to the plain prefix afterwards).
    MAN_ADD+=("--prefix=lazysite-$VERSION/man/man1/" "--add-file=man/man1/$(basename "$m")")
done
# SM561: TEST FIRST, THEN APPEND. The trailing --prefix used to be added
# before this test, so the array was never empty and a generator that
# produced nothing shipped a package with no manual pages.
if [ "${#MAN_ADD[@]}" -eq 0 ]; then
    abort_build "gen-manpages.pl produced no pages; not releasing."
fi
MAN_ADD+=("--prefix=lazysite-$VERSION/")


if [ "$MODE" = gate ]; then
# THE RECEIPT, written last: it exists only when every gate step passed - the
# suite, the bench, the coverage run AND the manifest, SBOM and man-page checks
# above, which are cheap but can still refuse a release. The 0.15.2 build was
# refused by the SBOM check (Net::DNS undeclared) after the gate had passed,
# because those checks ran only in the build: the person running it found out,
# not the agent running the gate. The logs go beside the receipt so a warning
# in any of them can be read after the stage is gone.
#
# SM971: it names the release material the gate tested - the generator's digest
# (build refuses a different one) and the stage commit that held its output.
cp "$GATE_OUT" "$RECEIPT_DIR/suite.txt"
cp "$COV_LOG" "$RECEIPT_DIR/coverage.txt"
[ -f "$LAZYSITE_COVER_SUITE_LOG" ] && cp "$LAZYSITE_COVER_SUITE_LOG" "$RECEIPT_DIR/coverage-suite.txt"
git -C "$STAGE" show --stat --format='%H %s' "$MATERIAL_SHA" > "$RECEIPT_DIR/material.txt"
{
    echo "sha=$TARGET_SHA"
    echo "version=$VERSION"
    echo "channel=$CHANNEL"
    echo "files=$GATE_FILES"
    echo "tests=$GATE_TESTS"
    echo "result=pass"
    echo "coverage=$COV_MODE"
    echo "coverage_from=$COV_FROM"
    echo "material_tool=$MATERIAL_TOOL"
    echo "material_commit=$MATERIAL_SHA"
    echo "material_date=$REL_DATE"
    echo "finished=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "host=$(hostname)"
} > "$RECEIPT"
echo "==> Gate receipt: $RECEIPT"
echo "==> Gate passed for $TARGET_SHA ($VERSION, $CHANNEL); coverage $COV_MODE."
echo "==> When the cut is called: tools/release.sh build $VERSION --notes FILE"
exit 0
fi

# --- build tarball ---

DIST_DIR="$STAGE/dist"
TARBALL="$DIST_DIR/lazysite-$VERSION.tar.gz"

mkdir -p "$DIST_DIR"

# Use git archive against the release commit. This captures the COMMIT
# state exactly - staging dir edits (if any) don't leak in.
echo "==> Building tarball $TARBALL"
# release-manifest.json + sbom.json are generated (untracked, SM065), so
# git archive would omit them; --add-file injects them at the tarball
# root (after --prefix, so they land under lazysite-VERSION/). The
# installer reads release-manifest.json from there.
git -C "$STAGE" archive --format=tar.gz \
    --prefix="lazysite-$VERSION/" \
    --add-file=release-manifest.json \
    --add-file=sbom.json \
    "${MAN_ADD[@]}" \
    -o "$TARBALL" "$RELEASE_SHA"

SHA256=$(sha256sum "$TARBALL" | awk '{print $1}')
printf "%s  lazysite-%s.tar.gz\n" "$SHA256" "$VERSION" > "$TARBALL.sha256"

echo "==> Tarball sha256: $SHA256"

# --- packages -----------------------------------------------------------------
#
# SM372: the .deb set is built HERE, from the same staging clone as the tarball,
# because remembering to build it separately did not work: packages exist for
# every release up to 0.10.8 and then stop. 0.10.9 through 0.10.13 have none,
# and nobody noticed for five releases - which is what a manual step attached to
# a process that already succeeds without it always does.
#
# THE VERSION IS STAMPED, NOT READ. dpkg takes it from debian/changelog, and
# that file sat at 0.10.8-1 while the tree moved on - so building it by hand
# today would have produced a package labelled 0.10.8 from 0.10.13 source. A
# package whose version contradicts its contents is worse than a missing one:
# apt will decline to upgrade to it, and an operator reading `dpkg -l` is told
# something false about what is installed.
#
# So the entry is generated in the STAGE, from $VERSION, and the repo's own
# debian/changelog is left alone. That makes the mislabelling IMPOSSIBLE rather
# than merely detectable, and it means the package version cannot disagree with
# the tag by construction. The existing changelog is kept as the entry's tail,
# so `dpkg -c` still shows the history.
#
# BEFORE THE TAG, deliberately. A failure here aborts a release that has not yet
# burned a version - and burned versions are never reused (SM064).
if [ "${LAZYSITE_SKIP_DEB:-0}" = 1 ]; then
    echo "==> Skipping .deb build (LAZYSITE_SKIP_DEB=1)"
elif ! command -v dpkg-buildpackage >/dev/null; then
    echo "release.sh: dpkg-buildpackage not installed, and the .deb set is part" >&2
    echo "release.sh: of a release. Install dpkg-dev + debhelper, or pass" >&2
    echo "release.sh: LAZYSITE_SKIP_DEB=1 to cut a tarball-only release and say" >&2
    echo "release.sh: so out loud." >&2
    exit 1
else
    echo "==> Stamping debian/changelog at $VERSION-1"
    DEB_ENTRY="$STAGE/.deb-changelog"
    {
        printf 'lazysite (%s-1) unstable; urgency=medium

' "$VERSION"
        printf '  * %s release %s. See CHANGELOG.md in the payload for the
' \
            "$CHANNEL" "$VERSION"
        printf '    full entry; this file is generated at release time so the
'
        printf '    package version cannot disagree with the tag.

'
        printf ' -- lazysite release <releases@lazysite.io>  %s

' \
            "$(date -R)"
        cat "$STAGE/debian/changelog"
    } > "$DEB_ENTRY"
    mv "$DEB_ENTRY" "$STAGE/debian/changelog"

    echo "==> build-deb.sh"
    if ! ( cd "$STAGE" && PACKAGES_DIR="$DIST_DIR" BUILD_AREA="$STAGE_BASE" \
            bash "$STAGE/tools/build-deb.sh" ); then
        echo "release.sh: .deb build FAILED - no tag was created." >&2
        exit 1
    fi

    # POSITIVE CHECK. A build that produced nothing, or produced packages under
    # the old version, must not read as success - which is the failure this
    # whole release line keeps finding. Every package named in debian/control
    # has to be present AT THIS VERSION.
    missing=
    for pkg in $(awk '/^Package:/ {print $2}' "$STAGE/debian/control"); do
        [ -f "$DIST_DIR/${pkg}_${VERSION}-1_all.deb" ] || missing="$missing $pkg"
    done
    if [ -n "$missing" ]; then
        echo "release.sh: the .deb build reported success and did not produce:" >&2
        echo "release.sh:  $missing" >&2
        echo "release.sh: at version $VERSION. No tag was created." >&2
        exit 1
    fi
    echo "==> Packages built at $VERSION-1:"
    for pkg in $(awk '/^Package:/ {print $2}' "$STAGE/debian/control"); do
        printf '    %s_%s-1_all.deb  %s\n' "$pkg" "$VERSION" \
            "$(sha256sum "$DIST_DIR/${pkg}_${VERSION}-1_all.deb" | awk '{print $1}')"
    done

    # --- SM887 D2: the claude.ai skill zip, WITH THE ENGINE INSIDE IT ---------
    #
    # Built here rather than beside the tarball because it needs the .deb that
    # was just produced: the whole design is that the skill CARRIES the engine,
    # so nothing is fetched from a host this project owns. An editor's network
    # allowlist is theirs, not ours, and a skill that reached lazysite.io would
    # work for the person who specified it and fail for everyone else.
    #
    # ONE DEB, NOT TWO. The filing said common + nginx; nginx ships vhost
    # templates and a vhost-writing command, and the container has no web
    # server to wire them into. It would be weight with no use.
    #
    # The version is in the FILENAME rather than only inside, because the one
    # thing an editor has to be able to see is whether the skill they uploaded
    # is older than their site.
    SKILL_SRC="$STAGE/skills/claude-ai/lazysite"
    if [ -d "$SKILL_SRC" ] && command -v zip >/dev/null 2>&1; then
        SKILL_STAGE="$STAGE/.skill-zip/lazysite"
        rm -rf "$STAGE/.skill-zip"
        mkdir -p "$SKILL_STAGE"
        cp -a "$SKILL_SRC"/. "$SKILL_STAGE/"
        cp "$DIST_DIR/lazysite-common_${VERSION}-1_all.deb" "$SKILL_STAGE/"
        ( cd "$STAGE/.skill-zip" && zip -qr "$DIST_DIR/lazysite-skill-$VERSION.zip" lazysite )
        if [ -f "$DIST_DIR/lazysite-skill-$VERSION.zip" ]; then
            printf '    lazysite-skill-%s.zip  %s\n' "$VERSION" \
                "$(sha256sum "$DIST_DIR/lazysite-skill-$VERSION.zip" | awk '{print $1}')"
        else
            echo "release.sh: the skill zip was not produced - the release is" >&2
            echo "release.sh: incomplete for claude.ai editors. No tag created." >&2
            exit 1
        fi
    elif [ -d "$SKILL_SRC" ]; then
        # NAMED, not skipped silently. An editor whose release has no skill zip
        # has no way to tell that from a release that never had one.
        echo "release.sh: zip(1) is not installed, so lazysite-skill-$VERSION.zip" >&2
        echo "release.sh: was NOT built. Install zip and re-cut, or ship without" >&2
        echo "release.sh: the claude.ai skill deliberately." >&2
        exit 1
    fi
fi

# --- a stable cut: download/ holds the new stable set -------------------------
#
# download/ is the current STABLE release, tracked so it can be downloaded
# without a build (lint 113), and export-ignored so no tarball carries it. It can
# only be filled once the packages exist, so it is a second commit on top of the
# release commit, touching download/ and nothing else; the tag stays on the
# release commit. Lint 113, held back from the release commit, runs here.
NEW_MAIN="$RELEASE_SHA"
if [ "$CHANNEL" = stable ]; then
    DL="$STAGE/download"
    OLD_DL=$(find "$DL" -maxdepth 1 -name 'lazysite-*.tar.gz' 2>/dev/null \
        | sed -n 's|.*/lazysite-\([0-9][0-9.]*[0-9]\)\.tar\.gz$|\1|p' | head -1)
    mkdir -p "$DL"
    find "$DL" -maxdepth 1 -type f ! -name README.md -delete
    cp "$TARBALL" "$TARBALL.sha256" "$DL/"
    for deb in "$DIST_DIR"/*_"$VERSION"-1_all.deb "$DIST_DIR/lazysite-skill-$VERSION.zip"; do
        [ -f "$deb" ] && cp "$deb" "$DL/"
    done
    if [ -n "$OLD_DL" ] && [ -f "$DL/README.md" ]; then
        sed -i "s/$(printf '%s' "$OLD_DL" | sed 's/\./\\./g')/$VERSION/g" "$DL/README.md"
    fi
    {
        printf 'download/: the %s stable set\n\n' "$VERSION"
        printf 'The tarball, its checksum, the packages and the claude.ai skill built from\n'
        printf 'the %s release commit %s, replacing %s.\n\n' "$VERSION" "${RELEASE_SHA:0:12}" "${OLD_DL:-nothing}"
        printf '%s\n' "$TRAILERS"
    } > "${STAGE}-download-commit.txt"
    git -C "$STAGE" add -A download
    git -C "$STAGE" commit --quiet -F "${STAGE}-download-commit.txt"
    NEW_MAIN=$(git -C "$STAGE" rev-parse HEAD)
    OUTSIDE=$(outside_of "$RELEASE_SHA" "$NEW_MAIN" "download/")
    if [ -n "$OUTSIDE" ]; then
        abort_build "the download commit touches more than download/: $(printf '%s ' $OUTSIDE)" \
            "main is unchanged; nothing was tagged."
    fi
    if ! ( cd "$STAGE" && detached prove -l t/lint/113-*.t > "${STAGE}-download-lint.txt" 2>&1 ); then
        cat "${STAGE}-download-lint.txt" >&2
        abort_build "lint 113 refused the download set; main is unchanged; nothing was tagged."
    fi
    echo "==> download/ commit $NEW_MAIN (the $VERSION stable set)"
fi

# --- tag the release commit, then move main to it ------------------------------
#
# The LAST step, after every check and every package: until here main and the
# tags are exactly as they were, whatever failed. The tag goes first because a
# local tag is free to remove; if main cannot move, it is removed again.
#
# Main moves by fast-forward only. Where a worktree has main checked out (the
# developer's, after a handoff), that worktree moves with it - it was checked
# clean before anything started; elsewhere the ref moves, and only if it still
# names the commit this build started from.
ANNOT_FILE="${STAGE}-annotation.txt"
perl "$STAGE/tools/release-material.pl" --notes "$NOTES_FILE" --print annotation > "$ANNOT_FILE"

land_main() {
    if [ "$(git -C "$ORIGIN" rev-parse refs/heads/main)" != "$MAIN_SHA" ]; then
        echo "release.sh: main moved while this build ran" >&2
        return 1
    fi
    if [ -n "$MAIN_WT" ]; then
        git -C "$MAIN_WT" merge --ff-only --quiet "$NEW_MAIN"
    else
        git -C "$ORIGIN" update-ref refs/heads/main "$NEW_MAIN" "$MAIN_SHA"
    fi
}

echo "==> Tagging $TAG on the release commit $RELEASE_SHA"
git -C "$ORIGIN" tag -a "$TAG" -F "$ANNOT_FILE" "$RELEASE_SHA"
if ! land_main; then
    git -C "$ORIGIN" tag -d "$TAG" >/dev/null
    abort_build "main could not be moved to $NEW_MAIN; the tag was removed again" \
        "and main is still $MAIN_SHA."
fi
echo "==> main is now $NEW_MAIN (was $MAIN_SHA)"

# --- final artefact copy ---

# Copy the tarball + sha out of staging so the operator has it
# locally after the staging dir is cleaned up.
FINAL_DIST="$ORIGIN/dist"
mkdir -p "$FINAL_DIST"
cp "$TARBALL" "$FINAL_DIST/"
cp "$TARBALL.sha256" "$FINAL_DIST/"

# SM372: and the packages, which were built into $DIST_DIR inside the stage and
# would otherwise be deleted with it two lines below.
for deb in "$DIST_DIR"/*_"$VERSION"-1_all.deb; do
    [ -f "$deb" ] && cp "$deb" "$FINAL_DIST/"
done

# SM887 D2: and the claude.ai skill zip, for the same reason - it is built
# inside the stage and would go with it.
[ -f "$DIST_DIR/lazysite-skill-$VERSION.zip" ] \
    && cp "$DIST_DIR/lazysite-skill-$VERSION.zip" "$FINAL_DIST/"

# --- cleanup ---

# SM895 G3: --keep-stage means "even on success"; a failed stage is kept by the
# trap regardless, and the next run removes it (prune_dead_stages).
if [ "$KEEP_STAGE" != 1 ]; then
    git -C "$ORIGIN" worktree remove --force "$STAGE" 2>/dev/null || rm -rf "$STAGE"
    git -C "$ORIGIN" worktree prune 2>/dev/null || true
fi

echo ""
echo "==> Built $TAG"
printf "    release commit: %s (on main)\n" "$RELEASE_SHA"
printf "    gated commit:   %s\n" "$TARGET_SHA"
printf "    main:           %s\n" "$NEW_MAIN"
printf "    tag:            %s (LOCAL)\n" "$TAG"
printf "    tarball:        %s\n" "$FINAL_DIST/lazysite-$VERSION.tar.gz"
printf "    sha256:         %s\n" "$SHA256"
for deb in "$FINAL_DIST"/*_"$VERSION"-1_all.deb; do
    [ -f "$deb" ] && printf "    package:        %s\n" "$(basename "$deb")"
done
[ -f "$FINAL_DIST/lazysite-skill-$VERSION.zip" ] \
    && printf "    skill:          lazysite-skill-%s.zip (claude.ai, carries the deb)\n" "$VERSION"
printf "    gate:           %s files, %s tests\n" "$GATE_FILES" "$GATE_TESTS"
echo ""
echo "==> The release manager's step - pushes main and $TAG together:"
echo "    tools/release.sh publish $VERSION"
