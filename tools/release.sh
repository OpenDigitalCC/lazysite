#!/bin/bash
# tools/release.sh - cut a tagged release from any commit on main.
#
# SM063 split: this script DOES NOT touch main. It clones the repo
# fresh into a staging dir, checks out the target commit, runs the
# full Perl test suite, verifies the SBOM strictness gate, packages
# a tarball, and tags the commit. The tag is pushed; no commit is
# made on main. Main is unstable; tags are the stable identifiers.
#
# Usage:
#   tools/release.sh build   VERSION [--notes NOTES_FILE] [--commit COMMIT]
#   tools/release.sh publish VERSION
#
#   SM303: two jobs sharing only a version number. BUILD gates, packages and
#   tags locally and never touches the remote - so it runs on the host with the
#   toolchain, which is not the host with the credentials. PUBLISH confirms the
#   tag upstream and pushes it, and does nothing else.
#
#   Builds the tarball AND the .deb set (SM372). LAZYSITE_SKIP_DEB=1 cuts a
#   tarball-only release and says so; without it a missing dpkg-buildpackage is
#   an error, because packages that nobody remembers to build stop existing -
#   which is what happened between 0.10.8 and 0.10.13.
#
#   VERSION         optional, e.g. 0.2.19 (semver X.Y.Z). When
#                   omitted, release.sh proposes the next patch bump
#                   from the most recent v*.*.* tag and prompts for
#                   confirmation (SM064). Pass VERSION explicitly to
#                   skip the prompt - useful for non-interactive
#                   runs.
#   --notes FILE    release-notes file. Default: use the target
#                   commit's own commit message.
#   --commit REF    SHA or ref to release. Default: origin/main HEAD.
#   --beta          mark the release 'beta' on the channel ladder
#                   (edge < beta < stable < certified): a bedded-in
#                   candidate for sites that want tested builds.
#   --final         mark the release 'stable' (alias: --stable) - the
#                   supported customer-rollout channel. Default: 'edge'.
#   --certified     mark the release 'certified' (ADR 0010): a stable
#                   build whose compliance records have been WALKED -
#                   the signed declaration, restore rehearsal and pentest
#                   posture gates block THIS cut, not a stable one.
#   --no-fetch      declares that this host has no remote. Its original
#                   job - skipping the two ORIGIN tag checks - became the
#                   only behaviour at SM303, so that part is inert and the
#                   flag is still accepted rather than removed. What it
#                   STILL does: it downgrades the "commit is on no branch"
#                   refusal to a warning (a host without a remote may
#                   legitimately have an incomplete branch set), and it
#                   makes the closing summary say the tag is local and
#                   unpushed. It is an explicit flag and never
#                   an automatic fallback, because a precondition that
#                   silently downgrades itself when it cannot run is the
#                   defect class this project keeps removing.
#
# Preconditions:
#   - VERSION (provided or proposed) is a semver string.
#   - Tag vVERSION does not already exist on origin.
#   - dist/config/sbom-deps.json exists in the target commit.
#
# On abort: the staging dir is REMOVED by the EXIT trap (SM328) and the
# abort message says so. Pass --keep-stage to retain it for inspection;
# the printed path is then real (SM560). Clean up a kept stage with
#   rm -rf $STAGE_BASE/lazysite-release-$$  (PID is in the printed path).
set -e

ORIGIN=/srv/projects/lazysite

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
COMMIT_REF="origin/main"
CHANNEL="edge"          # ladder: edge (default) < beta < stable < certified
NO_FETCH=0              # inert for the origin checks since SM303; still
                        # gates the no-branch refusal and the closing summary

# SM303: TWO OPERATIONS THAT SHARE ONLY A VERSION NUMBER.
#
#   build    the tree, the toolchain, CPU. Gate, manifest, SBOM, man pages,
#            tarball, packages, LOCAL tag. Needs no remote access at all.
#   publish  remote credentials, and the judgement that this tag should exist
#            upstream. Needs nothing else.
#
# Conflating them cost two flags and two failures pointing opposite ways. The
# build host has no remote credentials by design, so `git fetch --tags origin`
# under `set -e` aborted before a single gate step ran - asking the one person
# who COULD reach the remote to supervise a fifty-minute test run needing none.
# The repair was --no-fetch, and the run then died at the LAST step on
# `git push`, killing the artefact copy and leaving a fully gated, built and
# tagged release reporting exit 128 with its tarball stranded in staging.
#
# One command doing two jobs, failing at either end for reasons belonging to
# the other. Naming the job removes the flag that had to remember which host it
# was on.
MODE=""
case "${1:-}" in
    build|publish) MODE=$1; shift ;;
    -h|--help)     ;;
    *)
        # Not a silent fallback to either. The old form's failure modes are the
        # reason this split exists, so guessing which half was meant would
        # preserve them.
        if [ $# -gt 0 ]; then
            echo "release.sh: say which job. Building needs no remote access;" >&2
            echo "release.sh: publishing needs nothing else." >&2
            echo "release.sh:" >&2
            echo "release.sh:   tools/release.sh build   VERSION [--commit REF]" >&2
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
        --no-fetch)
            NO_FETCH=1
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
            sed -n '2,27p' "$0" | sed 's/^# \?//'
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

# --- publish: a short path sharing only the version number --------------------
#
# SM303. Everything below is BUILD and none of it runs here. Publish needs the
# tag to exist locally (so it cannot invent one), needs the remote (so it fails
# honestly on a host without credentials rather than half way through), and does
# nothing else.
if [ "$MODE" = publish ]; then
    if [ -z "$VERSION" ]; then
        echo "release.sh: publish needs a version, e.g. release.sh publish 0.10.14" >&2
        exit 2
    fi
    TAG="v$VERSION"

    if ! git -C "$ORIGIN" rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null; then
        echo "release.sh: $TAG not found locally. Build it first:" >&2
        echo "release.sh:   tools/release.sh build $VERSION" >&2
        exit 1
    fi

    # SM325 still applies at publish: a tag on no branch is a release whose
    # provenance cannot be reconstructed, and pushing one makes that permanent.
    if [ -z "$(git -C "$ORIGIN" branch --contains "$TAG" 2>/dev/null)" ]; then
        echo "release.sh: $TAG is on no branch. Pushing it would make a" >&2
        echo "release.sh: release nobody can trace back to a line of work." >&2
        exit 1
    fi

    echo "==> Fetching origin tags"
    if ! git -C "$ORIGIN" fetch --tags origin; then
        echo "release.sh: cannot reach origin. Publishing is the half that" >&2
        echo "release.sh: needs credentials - run it where they are." >&2
        exit 1
    fi
    if git -C "$ORIGIN" ls-remote --tags origin "refs/tags/$TAG" | grep -q .; then
        echo "release.sh: $TAG is ALREADY on origin. A burned version is never" >&2
        echo "release.sh: reused (SM064) - cut a new one." >&2
        exit 1
    fi

    echo "==> Pushing $TAG"
    git -C "$ORIGIN" push origin "$TAG"
    echo ""
    echo "==> Published $TAG"
    exit 0
fi

# SM064: when VERSION is omitted, propose the next patch bump from
# the most recent v*.*.* tag and prompt. Explicit VERSION argument
# bypasses the prompt for non-interactive use.
if [ -z "$VERSION" ]; then
    # Need the repo's tags available. Origin is our source of truth.
    if [ ! -d "$ORIGIN/.git" ]; then
        echo "release.sh: no git repo at $ORIGIN" >&2
        exit 1
    fi
    # SM303: no fetch. This proposes a version from LOCAL tags, and the build
    # host has nothing to fetch with. Local is the right source anyway - it
    # names the last version this tree actually built.

    # `tag -l 'v*.*.*' | sort -V | tail -1` is deterministic across
    # mixed-tag repos in a way `git describe --tags` isn't.
    LAST_TAG=$(git -C "$ORIGIN" tag -l 'v*.*.*' | sort -V | tail -1)
    if [ -z "$LAST_TAG" ]; then
        echo "release.sh: no v*.*.* tags on origin; cannot propose a version." >&2
        echo "release.sh: pass VERSION explicitly for the first release." >&2
        exit 1
    fi

    # Strip leading 'v', split on '.', bump the patch field.
    LAST_VER="${LAST_TAG#v}"
    IFS='.' read -r _M _m _p <<< "$LAST_VER"
    if ! [[ "$_M" =~ ^[0-9]+$ && "$_m" =~ ^[0-9]+$ && "$_p" =~ ^[0-9]+$ ]]; then
        echo "release.sh: latest tag '$LAST_TAG' doesn't look like vX.Y.Z" >&2
        echo "release.sh: pass VERSION explicitly." >&2
        exit 1
    fi
    PROPOSED="$_M.$_m.$((_p + 1))"

    echo "Latest tag: $LAST_TAG"
    read -r -p "Release as $PROPOSED [Y/n/edit]? " ans
    case "$ans" in
        ''|y|Y|yes|YES)
            VERSION="$PROPOSED"
            ;;
        n|N|no|NO)
            echo "release.sh: aborted."
            exit 0
            ;;
        e|E|edit|EDIT)
            read -r -p "Enter version: " edited
            # Strip any leading 'v' to be kind.
            edited="${edited#v}"
            if ! [[ "$edited" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo "release.sh: '$edited' is not a valid semver (X.Y.Z). Aborted." >&2
                exit 2
            fi
            VERSION="$edited"
            ;;
        *)
            echo "release.sh: unrecognised response '$ans'. Aborted." >&2
            exit 2
            ;;
    esac
fi

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "release.sh: '$VERSION' is not a valid semver (X.Y.Z)" >&2
    exit 2
fi

TAG="v$VERSION"

# --- precondition: tag not already on origin ---

if [ ! -d "$ORIGIN/.git" ]; then
    echo "release.sh: no git repo at $ORIGIN" >&2
    exit 1
fi

# SM303: BUILD NEVER TOUCHES THE REMOTE. Not "skips when asked" - never. The
# origin check belongs to publish, where the credentials and the judgement are.
# --no-fetch is still accepted and ignored, so invocations carrying it keep
# working rather than erroring on a flag that has become the only behaviour.
echo "==> Building locally; origin is not consulted (publish does that)"

# The LOCAL check runs either way - it is the one this host can answer.
if git -C "$ORIGIN" rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null; then
    echo "release.sh: tag $TAG already exists locally" >&2
    exit 1
fi

# SM303: the origin check lives in `publish`, which refuses a burned version
# (SM064). Said here once so a build is never mistaken for a publication.
echo "release.sh: NOTE - origin not consulted; release.sh publish checks it." >&2

# --- precondition: notes file readable if specified ---

if [ -n "$NOTES_FILE" ]; then
    if [ ! -f "$NOTES_FILE" ]; then
        echo "release.sh: notes file '$NOTES_FILE' not found" >&2
        exit 1
    fi
fi

# --- stage: fresh clone ---

# SM328: the staging path, and a trap that removes it however this run ends.
#
# Cleanup used to be `rm -rf "$STAGE"` as the last line of the happy path, so any
# failure - a failing test, a refused gate, an interrupt, a power cut, the disk
# filling - left the whole clone behind. Four cuts in a day was enough to exhaust
# a tmpfs, and nothing reclaimed them.
#
# --keep-stage opts out, because a gate failure is exactly when someone wants to
# look inside.
STAGE="$STAGE_BASE/lazysite-release-$$"
cleanup_stage() { [ "$KEEP_STAGE" = 1 ] || rm -rf "$STAGE"; }
trap cleanup_stage EXIT

# SM560: every abort names what became of the stage - and it must be TRUE.
# Eleven abort paths printed "staging dir retained" while the trap above
# removed it, so the first diagnostic step after any gate failure was a dead
# end. The trap stays (SM328); the sentence now matches it.
stage_disposition() {
    if [ "$KEEP_STAGE" = 1 ]; then
        echo "release.sh: staging dir retained: $STAGE" >&2
    else
        echo "release.sh: staging dir removed (re-run with --keep-stage to inspect): $STAGE" >&2
    fi
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

# Refuse EARLY if the staging filesystem cannot hold a gate run. Inodes as well
# as bytes: bytes were never what ran out, and checking only those would repeat
# the failure this guards against.
mkdir -p "$STAGE_BASE"
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

if [ -n "$_free_inodes" ] && [ "$_free_inodes" -gt 0 ] \
   && [ "$_free_inodes" -lt 1200000 ]; then
    echo "release.sh: $STAGE_BASE has only $_free_inodes free inodes." >&2
    echo "  A gate run needs roughly 1.1M: Devel::Cover writes a directory per" >&2
    echo "  instrumented subprocess and this suite spawns them constantly." >&2
    echo "  Point somewhere with more: --stage-dir /srv/tmp, or LAZYSITE_STAGE_DIR." >&2
    exit 5
fi
case "${_free_kb:-}" in ''|*[!0-9]*) _free_kb="" ;; esac
if [ -n "$_free_kb" ] && [ "$_free_kb" -lt 2000000 ]; then
    echo "release.sh: $STAGE_BASE has only $((_free_kb/1024))MB free; ~2GB wanted." >&2
    echo "  Point somewhere larger: --stage-dir /srv/tmp, or LAZYSITE_STAGE_DIR." >&2
    exit 5
fi

echo "==> Staging clone at $STAGE"
git clone --quiet "$ORIGIN" "$STAGE"

# Resolve the target commit inside the staging clone so refs like
# origin/main resolve correctly.
TARGET_SHA=$(git -C "$STAGE" rev-parse "$COMMIT_REF")
echo "==> Target commit: $TARGET_SHA ($COMMIT_REF)"

git -C "$STAGE" checkout --quiet --detach "$TARGET_SHA"

# --- VERSION is STAMPED, NOT READ (SM375) ---
#
# The same defect SM372 fixed for debian/changelog, in the file next to it, and
# missed at the time because only one of the two was being looked at. VERSION
# sat at 0.10.9 while 0.10.10 through 0.10.14 were released.
#
# WHY IT DRIFTED, AND WHY IT WILL AGAIN IF LEFT TO A PERSON. tools/bump-version.pl
# exists precisely for this - its own header records that a 2026 review found
# VERSION "stuck at 0.2.18 while releases were at 0.3.x" - and it says "the
# release process should call this AFTER a tag is cut". The release process never
# did. So the fix for the defect was written, committed, and never wired in, and
# the defect recurred identically five releases later.
#
# WHAT IT AFFECTED. The compliance gate below reads this file and compares
# records against it, so for five releases it asked whether records were current
# as of 0.10.9. build-manifest.pl and manifest-to-sbom.pl DEFAULT to it and were
# saved only by release.sh passing --version explicitly - authoritative by
# accident of invocation rather than by design. And the file ships INSIDE the
# tarball, where those same tools have no --version to be passed.
#
# Stamped in the STAGE, from $VERSION, leaving the repo's own copy alone -
# release.sh does not touch main (SM063). t/lint/63 fails when the repo's copy
# falls behind the newest tag, which is what makes the post-release bump happen
# rather than be remembered.
echo "==> Stamping VERSION at $VERSION (was $(cat "$STAGE/VERSION" 2>/dev/null || echo none))"
printf '%s\n' "$VERSION" > "$STAGE/VERSION"

# SM383: NEXT_VERSION MOVES WITH IT, or the stage contradicts itself.
#
# VERSION and NEXT_VERSION are a PAIR - "the last released version" and "the one
# after it" - and tools/bump-version.pl advances both together for that reason.
# SM375 taught this script to stamp VERSION and left NEXT_VERSION alone, so a
# stage cutting 0.10.15 had VERSION=0.10.15 and NEXT_VERSION=0.10.15: the next
# release would propose a version already cut, and burned versions are never
# reused (SM064).
#
# t/lint/63 caught it by failing the release, which is the gate working - but it
# is worth being precise about what went wrong. The defect was not the lint. It
# was stamping one half of a pair and leaving the other, in the very change that
# existed because the pair had drifted.
STAGE_NEXT=$(printf '%s' "$VERSION" | awk -F. '{ printf "%d.%d.%d", $1, $2, $3 + 1 }')
echo "==> Stamping NEXT_VERSION at $STAGE_NEXT (the pair moves together)"
printf '%s\n' "$STAGE_NEXT" > "$STAGE/NEXT_VERSION"

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
if ! ( cd "$STAGE" && set -o pipefail && prove -lr t/ 2>&1 | tee "$GATE_OUT" ); then
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
if ! perl "$STAGE/tools/bench.pl" --check; then
    abort_build "benchmark regression; not releasing."
fi

# --- coverage gate (eight-dimension review D3) ---
# Instrumented re-run of the suite against the declared floors in
# dist/config/coverage-floor. Slow (~10-15 minutes at release cadence);
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
echo "==> coverage.sh --check (instrumented run; ~10-15 minutes)"
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
# SM552: CAPTURED ON THE SAME LINE. Under `set -e` a bare `cmd` followed by
# `STATUS=$?` never reaches the second statement when cmd fails - the script
# died here and the whole verdict block below was unreachable. Not `if !`
# (58 forbids it: that form asserted a cause nobody had measured).
COV_STATUS=0
bash "$STAGE/tools/coverage.sh" --check > "$COV_LOG" 2>&1 || COV_STATUS=$?
cat "$COV_LOG"
if [ "$COV_STATUS" -ne 0 ]; then
    if grep -q 'COVERAGE BELOW FLOOR' "$COV_LOG"; then
        echo "release.sh: coverage below the declared floor; not releasing." >&2
        grep -E 'BELOW' "$COV_LOG" >&2
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

# --- build tarball ---

DIST_DIR="$STAGE/dist"
TARBALL="$DIST_DIR/lazysite-$VERSION.tar.gz"

mkdir -p "$DIST_DIR"

# Use git archive against the target SHA. This captures the COMMIT
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
    -o "$TARBALL" "$TARGET_SHA"

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
fi

# --- tag ---

# Annotation source: --notes file if given, otherwise the target
# commit's own message. git tag -a -F reads the annotation from a
# file, so we stage the message into a temp file either way for
# consistency.
ANNOT_FILE="$STAGE/.release-annotation"
if [ -n "$NOTES_FILE" ]; then
    cp "$NOTES_FILE" "$ANNOT_FILE"
else
    git -C "$ORIGIN" log -1 --format=%B "$TARGET_SHA" > "$ANNOT_FILE"
fi

# SM325: refuse to tag a commit that is on no branch.
#
# 0.10.10 was cut twice. The first tag named a branch tip; vcs-review then landed
# that branch onto main with new SHAs, and the tag was left pointing at a commit
# no branch contained. Nothing had been pushed so it cost only a re-cut - but a
# re-cut is a full gate run, and `git branch --contains` answers the question in
# a second.
#
# It matters beyond tidiness: a tag on no branch is a release whose provenance
# cannot be followed from any branch history, and if the tag were ever deleted
# the commit becomes unreachable. Anyone auditing later runs --contains, gets
# nothing, and has to work out whether that is a problem.
#
# A warning rather than a refusal when --no-fetch is set, because on a build host
# with no remote the local branch set may legitimately be incomplete.
if ! git -C "$ORIGIN" branch --contains "$TARGET_SHA" 2>/dev/null | grep -q .; then
    echo "==> WARNING: $TARGET_SHA is on no branch." >&2
    echo "    A tag here records a release whose history no branch contains." >&2
    echo "    This is what a rebase (vcs-review landing a branch) leaves behind:" >&2
    echo "    tag AFTER the branch lands, not before." >&2
    if [ "$NO_FETCH" != 1 ]; then
        echo "    Refusing. Re-run against a commit on a branch, or pass --no-fetch" >&2
        echo "    if this host legitimately has an incomplete branch set." >&2
        exit 4
    fi
    echo "    --no-fetch is set, so continuing - this host may not have every branch." >&2
fi

echo "==> Tagging $TAG on $TARGET_SHA in origin repo"
# Tag is created in the ORIGIN working tree so it's immediately
# pushable. The staging clone is throwaway.
git -C "$ORIGIN" tag -a "$TAG" -F "$ANNOT_FILE" "$TARGET_SHA"

# --no-fetch means this host has no remote credentials, so it cannot push
# either. Skipping it here rather than letting `set -e` kill the run at the last
# step: the previous behaviour left the tarball stranded in the staging
# directory with the artefact copy and cleanup unreached, and reported failure
# for a release that had in fact been built and tagged.
# SM303: a build does not push, on any host, under any flag.
echo "==> $TAG is local and unpushed. To publish it:"
echo "    tools/release.sh publish $VERSION"

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

# --- the tracked gate record (SM400) ---
#
# The manifest inside the artefact already attests the gate. This is the copy
# that answers the same question WITHOUT the artefact, because the question is
# always asked later and by someone who has the repo rather than the tarball.
#
# APPENDED, NEVER COMMITTED. This script does not commit and does not push
# (SM303), and a release is the worst moment to start churning git. The operator
# lands it with everything else; the reminder below is deliberately the last
# thing printed after the summary so it is not scrolled past.
GATE_LOG="$ORIGIN/docs/releases/GATE-LOG.md"
mkdir -p "$ORIGIN/docs/releases"
if [ ! -f "$GATE_LOG" ]; then
    {
        printf -- '---\n'
        printf 'title: "lazysite - release gate record"\n'
        printf 'subtitle: "Which commit each release was validated at, newest last. Appended by tools/release.sh."\n'
        printf 'brand: plain\n'
        printf 'standard-margins: true\n'
        printf -- '---\n\n'
        printf '# Why this file exists\n\n'
        printf 'A promotion review could establish which VERSION was being proposed and not\n'
        printf 'which COMMIT had been validated: the gate summary went to a terminal and to\n'
        printf '`tmp/gate-result.txt`, which is gitignored. "The build that would go to beta is\n'
        printf 'not the build that was validated" was a reasonable conclusion and nothing cheap\n'
        printf 'could disprove it.\n\n'
        printf 'Every row is written by `tools/release.sh` after its gate passed and before it\n'
        printf 'tagged, so a row exists only for a build that was actually gated. The same facts\n'
        printf 'travel inside the artefact, in `release-manifest.json` under `validated`.\n\n'
        printf '| Version | Channel | Commit | Files | Tests | Gated (UTC) |\n'
        printf '|---|---|---|---|---|---|\n'
    } > "$GATE_LOG"
fi
printf '| %s | %s | `%s` | %s | %s | %s |\n' \
    "$VERSION" "$CHANNEL" "$TARGET_SHA" "$GATE_FILES" "$GATE_TESTS" \
    "$(date -u '+%Y-%m-%d %H:%M')" >> "$GATE_LOG"

# --- cleanup ---

rm -rf "$STAGE"

echo ""
echo "==> Released $TAG"
printf "    commit:  %s\n" "$TARGET_SHA"
printf "    tag:     %s\n" "$TAG"
printf "    tarball: %s\n" "$FINAL_DIST/lazysite-$VERSION.tar.gz"
printf "    sha256:  %s\n" "$SHA256"
for deb in "$FINAL_DIST"/*_"$VERSION"-1_all.deb; do
    [ -f "$deb" ] && printf "    package: %s\n" "$(basename "$deb")"
done
if [ "$NO_FETCH" = 1 ]; then
    printf "    tag:     LOCAL AND UNPUSHED - tools/release.sh publish $VERSION\n"
fi
printf "    gate:    %s files, %s tests\n" "$GATE_FILES" "$GATE_TESTS"
echo ""
echo "==> UNCOMMITTED: docs/releases/GATE-LOG.md gained a row for $VERSION."
echo "    Commit it, or the next promotion review has no record of what was gated."
