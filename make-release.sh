#!/bin/bash
# make-release.sh - build a versioned release tarball, manifest, and
# CycloneDX SBOM for lazysite. Structure modelled on the reference
# template from OpenDigitalCC/ctrl-exec, Python replaced with Perl.
#
# Usage:
#   ./make-release.sh           print guidance, exit 0
#   ./make-release.sh --auto    commit and push after build
#   ./make-release.sh --force   alias for --auto
#   ./make-release.sh --help    usage
set -euo pipefail

# --- colour helpers ---

if [ -t 1 ]; then
    C_INFO="\033[1;34m"
    C_WARN="\033[1;33m"
    C_ERR="\033[1;31m"
    C_OK="\033[1;32m"
    C_RESET="\033[0m"
else
    C_INFO=""; C_WARN=""; C_ERR=""; C_OK=""; C_RESET=""
fi

info() { printf "${C_INFO}==>${C_RESET} %s\n" "$*"; }
warn() { printf "${C_WARN}!!${C_RESET} %s\n" "$*" >&2; }
err()  { printf "${C_ERR}ERROR:${C_RESET} %s\n" "$*" >&2; exit 1; }
ok()   { printf "${C_OK}OK${C_RESET} %s\n" "$*"; }

# --- arg parse ---

AUTO=0
ALLOW_DIRTY=0
NOTES_FILE=""
usage() {
    cat <<'USAGE'
make-release.sh - build a lazysite release tarball.

Run with no arguments to see planned version and command summary.

Options:
  --auto, --force    Full automated release: build, commit, tag,
                     bump NEXT_VERSION, push. Prompts for release
                     notes unless --notes-file is given.
                     Without this, prints the exact git commands
                     and leaves the working tree for manual use.
  --notes-file PATH  Read release notes from PATH instead of
                     prompting. Must be used with --auto. Format:
                     first line is the summary, remaining lines
                     are the body. A blank line between them is
                     optional.
  --allow-dirty      Permit release from a dirty git tree. Intended
                     only for the first release (D021a/b bootstrap).
                     WARNING: a release built from a dirty tree
                     cannot be reproduced from git alone.
                     Incompatible with --auto.
  --help             Show this help.

Reads NEXT_VERSION for the build target.
USAGE
}

if [ $# -eq 0 ]; then
    info "lazysite release builder"
    if [ -f NEXT_VERSION ]; then
        NV=$(cat NEXT_VERSION | tr -d ' \t\n\r')
        info "NEXT_VERSION = $NV"
    fi
    if [ -f VERSION ]; then
        CV=$(cat VERSION | tr -d ' \t\n\r')
        info "VERSION      = $CV (current release)"
    fi
    info "Run './make-release.sh --auto' for a full release."
    info "(prompts for notes, then commits, tags, bumps, pushes)"
    info "Or './make-release.sh --auto --notes-file PATH' for unattended."
    info "Or './make-release.sh --help' for all options."
    exit 0
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --auto|--force) AUTO=1; shift ;;
        --allow-dirty)  ALLOW_DIRTY=1; shift ;;
        --notes-file)   NOTES_FILE="$2"; shift 2 ;;
        --help) usage; exit 0 ;;
        *) err "Unknown option: $1" ;;
    esac
done

if [ "$AUTO" -eq 1 ] && [ "$ALLOW_DIRTY" -eq 1 ]; then
    err "--auto and --allow-dirty are mutually exclusive. --auto requires a clean tree."
fi

if [ -n "$NOTES_FILE" ] && [ "$AUTO" -ne 1 ]; then
    err "--notes-file requires --auto"
fi

# SM030 + amendment: notes-source detection.
#
# Precedence in --auto:
#   (a) --notes-file PATH explicitly given: use it
#   (b) .release-notes.md exists at repo root: implicit use
#   (c) Neither: interactive prompt after build
#
# DELETE_NOTES_ON_SUCCESS is set to the file path when that file
# is the conventional .release-notes.md (implicit or explicit);
# the file is deleted after a successful push so stale notes
# cannot silently carry into the next release.
DELETE_NOTES_ON_SUCCESS=""
if [ "$AUTO" -eq 1 ]; then
    if [ -n "$NOTES_FILE" ]; then
        :   # explicit --notes-file: validated below
    elif [ -f .release-notes.md ]; then
        NOTES_FILE=".release-notes.md"
        info "Using .release-notes.md"
    fi
fi

if [ -n "$NOTES_FILE" ]; then
    [ -r "$NOTES_FILE" ] || err "Cannot read notes file: $NOTES_FILE"
    [ -s "$NOTES_FILE" ] || err "Notes file is empty: $NOTES_FILE"
    NOTES_BODY=$(cat "$NOTES_FILE")
    # Reject effectively-empty files (whitespace-only).
    if [ -z "$(printf '%s' "$NOTES_BODY" | tr -d '[:space:]')" ]; then
        err "Notes file $NOTES_FILE contains only whitespace."
    fi
    # If the consumed file is the convention file, mark for cleanup
    # on happy-path success. Path comparison handles both implicit
    # and an explicit --notes-file .release-notes.md.
    case "$NOTES_FILE" in
        .release-notes.md|./.release-notes.md)
            DELETE_NOTES_ON_SUCCESS="$NOTES_FILE" ;;
    esac
fi

# --- preflight ---

[ -f NEXT_VERSION ] || err "NEXT_VERSION not found. Run from repo root."
[ -f VERSION ]      || err "VERSION not found. Run from repo root."

VERSION=$(cat NEXT_VERSION | tr -d ' \t\n\r')
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    err "NEXT_VERSION '$VERSION' is not semver (n.n.n)."
fi
info "Building release $VERSION"

# Clean tree check
if [ "$ALLOW_DIRTY" -eq 1 ]; then
    warn "--allow-dirty: skipping clean-tree check"
elif ! git diff --quiet || ! git diff --cached --quiet; then
    err "Working tree has uncommitted changes. Commit or stash first."
fi

# Untracked files check (strict - any new file will be absent from a
# stage built via git ls-files)
if [ -n "$(git ls-files --others --exclude-standard)" ]; then
    warn "Untracked files present (they will not be included in the tarball):"
    git ls-files --others --exclude-standard | sed 's/^/    /'
fi

COMMIT=$(git rev-parse HEAD)
info "HEAD = $COMMIT"

REPO_ROOT=$(pwd)
STAGE=$(mktemp -d "/tmp/lazysite-$VERSION-stage-XXXXXX")
STAGE_INNER="$STAGE/lazysite-$VERSION"
mkdir -p "$STAGE_INNER"
trap 'rm -rf "$STAGE"' EXIT

info "Staging tree into $STAGE_INNER"

# Use git ls-files so untracked working-tree files do not leak into
# the release. Then build-manifest.pl classifies + filters against
# the classification config (exclude patterns drop test dirs, docs/
# architecture, the release tooling itself, etc.).
git ls-files | while read -r f; do
    dir=$(dirname "$f")
    mkdir -p "$STAGE_INNER/$dir"
    cp -p "$f" "$STAGE_INNER/$f"
done

# Restore executable mode on shipped scripts. Git tracks them as
# 100644 in this repo (historical), but operators extracting the
# tarball expect to be able to invoke them directly. Globs fail
# soft: a release that doesn't ship a category is silently OK.
info "Setting executable mode on shipped scripts"
chmod +x "$STAGE_INNER"/lazysite-*.pl 2>/dev/null || true
chmod +x "$STAGE_INNER"/tools/lazysite-*.pl 2>/dev/null || true
chmod +x "$STAGE_INNER"/tools/*.sh 2>/dev/null || true
chmod +x "$STAGE_INNER"/install.sh 2>/dev/null || true
chmod +x "$STAGE_INNER"/installers/hestia/install-hestia.sh 2>/dev/null || true

# Drop files that the manifest excludes, directly - otherwise they
# sit in the tarball but aren't in the manifest, which is confusing.
# build-manifest's exclude list is the source of truth; we mirror it
# by deleting the matching paths from the stage. The simplest way is
# to run build-manifest in scan-only mode: its own scan ignores
# excluded paths, and we use its reported paths to prune.
info "Generating manifest"

"$REPO_ROOT/tools/build-manifest.pl" \
    --staged "$STAGE_INNER" \
    --version "$VERSION" \
    --config "$REPO_ROOT/dist/config/classification.json" \
    --out "$STAGE_INNER/release-manifest.json"

# Prune everything not in the manifest (except the manifest/sbom
# themselves, which we're about to add).
info "Pruning files not in the manifest"
perl -MFile::Find -MJSON::PP -e '
    my ($stage, $manifest_path) = @ARGV;
    open my $fh, "<:raw", $manifest_path or die "open manifest: $!";
    my $m = decode_json(do { local $/; <$fh> });
    close $fh;
    my %keep = map { $_->{path} => 1 } @{$m->{files}};
    # Also keep the manifest + sbom files themselves at the tarball root.
    $keep{"release-manifest.json"} = 1;
    $keep{"sbom.json"}             = 1;
    my @to_remove;
    find({
        no_chdir => 1,
        wanted => sub {
            return unless -f $_;
            my $rel = $_;
            $rel =~ s{^\Q$stage\E/?}{};
            return if $rel eq "";
            push @to_remove, $_ unless $keep{$rel};
        },
    }, $stage);
    unlink $_ for @to_remove;
    # Remove empty directories bottom-up.
    finddepth({
        no_chdir => 1,
        wanted => sub {
            return unless -d $_;
            rmdir $_;   # silently skips non-empty
        },
    }, $stage);
' "$STAGE_INNER" "$STAGE_INNER/release-manifest.json"

# Stamp $VERSION into shipped .pl files if any of them declare one.
# Currently none do; noop unless a future release adds a version
# string to a shipped script.
info "Stamping \$VERSION into shipped scripts (if any)"
find "$STAGE_INNER" -name '*.pl' -type f -print0 | while IFS= read -r -d '' f; do
    if grep -q "^our \$VERSION = " "$f"; then
        sed -i "s/^our \$VERSION = .*/our \$VERSION = '$VERSION';/" "$f"
        info "  stamped: ${f#$STAGE_INNER/}"
    fi
done

# Copy the manifest back to the repo root so it's committable.
cp "$STAGE_INNER/release-manifest.json" "$REPO_ROOT/release-manifest.json"

# Generate SBOM from the STAGED manifest against the STAGED tree so
# the strict grep check sees exactly what shipped.
info "Generating SBOM (strict grep mode)"
"$REPO_ROOT/tools/manifest-to-sbom.pl" \
    --manifest "$STAGE_INNER/release-manifest.json" \
    --deps     "$REPO_ROOT/dist/config/sbom-deps.json" \
    --version  "$VERSION" \
    --staged   "$STAGE_INNER" \
    --strict \
    --out      "$STAGE_INNER/sbom.json"

cp "$STAGE_INNER/sbom.json" "$REPO_ROOT/sbom.json"

# --- tarball ---

mkdir -p "$REPO_ROOT/dist"
# Remove any earlier release tarballs and checksums.
find "$REPO_ROOT/dist" -maxdepth 1 -type f \
    \( -name 'lazysite-*.tar.gz' -o -name 'lazysite-*.tar.gz.sha256' \) \
    -delete 2>/dev/null || true

TARBALL="$REPO_ROOT/dist/lazysite-$VERSION.tar.gz"
info "Building tarball $TARBALL"
tar -czf "$TARBALL" -C "$STAGE" "lazysite-$VERSION"

SHA=$(sha256sum "$TARBALL" | cut -d' ' -f1)
echo "$SHA  $(basename "$TARBALL")" > "$TARBALL.sha256"
info "  sha256: $SHA"

# --- evaluation-ramp smoke test ---

info "Running evaluation-ramp smoke test"

EVAL_DIR=$(mktemp -d "/tmp/lazysite-$VERSION-eval-XXXXXX")
SMOKE_PID=""
cleanup_smoke() {
    if [ -n "${SMOKE_PID:-}" ]; then
        kill "$SMOKE_PID" 2>/dev/null || true
        wait "$SMOKE_PID" 2>/dev/null || true
    fi
    rm -rf "$STAGE" "$EVAL_DIR"
}
trap cleanup_smoke EXIT

tar -xzf "$TARBALL" -C "$EVAL_DIR"
EVAL_ROOT="$EVAL_DIR/lazysite-$VERSION"

if [ ! -f "$EVAL_ROOT/tools/lazysite-server.pl" ]; then
    err "Smoke test: tools/lazysite-server.pl missing from tarball"
fi
if [ ! -d "$EVAL_ROOT/starter" ]; then
    err "Smoke test: starter/ missing from tarball"
fi

SMOKE_PORT=18739
SMOKE_LOG="$EVAL_DIR/server.log"
perl "$EVAL_ROOT/tools/lazysite-server.pl" \
    --port "$SMOKE_PORT" \
    --docroot "$EVAL_ROOT/starter" \
    > "$SMOKE_LOG" 2>&1 &
SMOKE_PID=$!

# Wait up to 5s for the server to become ready.
for _ in 1 2 3 4 5; do
    sleep 1
    if curl -fs -m 2 -o /dev/null "http://127.0.0.1:$SMOKE_PORT/"; then
        break
    fi
done

SMOKE_BODY="$EVAL_DIR/body.html"
SMOKE_CODE=$(curl -fs -m 5 -o "$SMOKE_BODY" \
    -w '%{http_code}' "http://127.0.0.1:$SMOKE_PORT/" || echo 000)

if [ "$SMOKE_CODE" != "200" ]; then
    warn "Smoke test: HTTP $SMOKE_CODE (expected 200)"
    warn "server log:"
    sed 's/^/    /' "$SMOKE_LOG" | tail -20 >&2
    err "Smoke test failed: root page not 200"
fi

if ! grep -qi "lazysite" "$SMOKE_BODY"; then
    warn "Smoke test: response body does not contain 'lazysite'"
    warn "body head:"
    head -20 "$SMOKE_BODY" | sed 's/^/    /' >&2
    err "Smoke test failed: body check"
fi

ok "Smoke test passed (HTTP 200, body contains 'lazysite')"

kill "$SMOKE_PID" 2>/dev/null || true
wait "$SMOKE_PID" 2>/dev/null || true

IFS='.' read -r MAJ MIN PAT <<< "$VERSION"
NEXT_PATCH=$((PAT + 1))
NEXT="$MAJ.$MIN.$NEXT_PATCH"

# --- SM030: collect release notes (auto mode only) ---
#
# Happens BEFORE VERSION / NEXT_VERSION are touched so that a
# Ctrl-C during the prompt leaves those files unchanged and the
# only side-effect is the just-built tarball, which we delete.
#
# For --notes-file, the file has already been validated during arg
# parse, so NOTES_SUMMARY and NOTES_BODY are populated.

notes_interrupt() {
    printf "\n"
    warn "Release aborted at notes prompt."
    rm -f "$TARBALL" "$TARBALL.sha256"
    exit 130
}

collect_notes_interactive() {
    info "Enter release notes for $VERSION"
    # SIGINT during read fires this trap. The main EXIT trap still
    # cleans up temp dirs.
    trap notes_interrupt INT
    printf "Release notes (markdown; end with Ctrl-D):\n"
    # cat on stdin reads until EOF. Ctrl-D on an empty line yields "".
    NOTES_BODY=$(cat || true)
    if [ -z "$(printf '%s' "$NOTES_BODY" | tr -d '[:space:]')" ]; then
        warn "Release notes cannot be empty."
        rm -f "$TARBALL" "$TARBALL.sha256"
        exit 1
    fi
    trap - INT
}

if [ "$AUTO" -eq 1 ] && [ -z "$NOTES_FILE" ]; then
    collect_notes_interactive
fi

# --- write VERSION / NEXT_VERSION ---
#
# The pristine release tree has VERSION == NEXT_VERSION. The bump
# to the next patch happens as a separate follow-up commit
# (auto mode) or via operator-run command (manual mode), so the
# tagged release commit contains a pristine release tree AND
# remains the direct ancestor of the bump commit (linear main
# history).

echo "$VERSION" > "$REPO_ROOT/VERSION"
echo "$VERSION" > "$REPO_ROOT/NEXT_VERSION"

info "VERSION set to $VERSION (NEXT_VERSION will bump to $NEXT in a follow-up commit)"

# --- commit / tag / bump / push or print commands ---

if [ "$AUTO" -eq 1 ]; then
    info "Auto-committing release $VERSION"

    # Build the commit message: title-only subject plus the full
    # notes as the body. The first line of the notes file shows up
    # as the first body line (and in GitHub's release-page preview).
    MSG_FILE=$(mktemp "/tmp/lazysite-relmsg-$VERSION-XXXXXX")
    printf 'release: %s\n\n%s\n' "$VERSION" "$NOTES_BODY" > "$MSG_FILE"

    # git add -A picks up the release-manifest.json, sbom.json,
    # VERSION, NEXT_VERSION, plus any other change since the clean-
    # tree check at the start. The tarball is gitignored so needs -f.
    git add -A
    git add -f "$TARBALL" "$TARBALL.sha256"

    if ! git commit -F "$MSG_FILE"; then
        rm -f "$MSG_FILE"
        err "git commit failed. Resolve and rerun."
    fi
    rm -f "$MSG_FILE"

    if ! git tag -a "v$VERSION" -m "Release $VERSION"; then
        warn "git tag failed. Commit is in place. To recover:"
        warn "  git tag -a v$VERSION -m 'Release $VERSION'"
        warn "  echo $NEXT > NEXT_VERSION && git add NEXT_VERSION &&"
        warn "    git commit -m 'chore: bump NEXT_VERSION to $NEXT'"
        warn "  git push && git push origin v$VERSION"
        err "Aborting after tag failure."
    fi

    # Bump NEXT_VERSION as a follow-up commit. Linear history on
    # main; tag stays anchored to the release commit.
    echo "$NEXT" > "$REPO_ROOT/NEXT_VERSION"
    git add NEXT_VERSION
    git commit -m "chore: bump NEXT_VERSION to $NEXT"

    # Push. Failure leaves commits + tag local; operator retries.
    PUSH_OK=1
    if ! git push; then
        PUSH_OK=0
    elif ! git push origin "v$VERSION"; then
        PUSH_OK=0
    fi

    RELEASE_SHA=$(git rev-parse "v$VERSION^{commit}")

    if [ "$PUSH_OK" -eq 0 ]; then
        warn "Push failed. Commits and tag are local. Retry with:"
        warn "  git push && git push origin v$VERSION"
        ok "Release $VERSION committed, tagged, bumped (NOT pushed)"
    else
        ok "Release $VERSION pushed"
        # Happy path: if the consumed notes were .release-notes.md
        # (CC convention file), remove it so the next release
        # cannot silently reuse the now-shipped notes. Preserved on
        # any failure path so the operator can retry without
        # re-authoring.
        if [ -n "$DELETE_NOTES_ON_SUCCESS" ] \
            && [ -f "$DELETE_NOTES_ON_SUCCESS" ]; then
            rm -f "$DELETE_NOTES_ON_SUCCESS"
            info "Removed $DELETE_NOTES_ON_SUCCESS (consumed by release)"
        fi
    fi
    printf "    Tag:       v%s\n"   "$VERSION"
    printf "    Commit:    %s\n"    "$RELEASE_SHA"
    printf "    Tarball:   dist/lazysite-%s.tar.gz\n" "$VERSION"
    if [ "$PUSH_OK" -eq 1 ]; then
        printf "    Pushed:    origin/main, origin v%s\n" "$VERSION"
    else
        printf "    Pushed:    NO (local only, retry required)\n"
    fi
else
    info "Not auto-committing. Two commits form the release:"
    cat <<CMDS

    # 1. Release commit (tagged):
    git add VERSION NEXT_VERSION release-manifest.json sbom.json
    git add -f dist/lazysite-$VERSION.tar.gz dist/lazysite-$VERSION.tar.gz.sha256
    git commit -m "release: $VERSION"
    git tag -a v$VERSION -m "Release $VERSION"

    # 2. Follow-up commit bumping NEXT_VERSION for the next release:
    echo "$NEXT" > NEXT_VERSION
    git add NEXT_VERSION
    git commit -m "chore: bump NEXT_VERSION to $NEXT"

    # Push:
    git push
    git push origin v$VERSION

Or run with --auto for one-command release.
CMDS
fi

info "Summary"
printf "  version:     %s\n"  "$VERSION"
printf "  next:        %s\n"  "$NEXT"
printf "  commit:      %s\n"  "$COMMIT"
printf "  tarball:     dist/lazysite-%s.tar.gz\n"       "$VERSION"
printf "  sha256:      %s\n"                            "$SHA"
printf "  manifest:    release-manifest.json (%s entries)\n" \
    "$(perl -MJSON::PP -e 'print scalar @{decode_json(do { local $/; <STDIN> })->{files}}' < "$REPO_ROOT/release-manifest.json")"
printf "  sbom:        sbom.json\n"

trap - EXIT
rm -rf "$STAGE" "$EVAL_DIR"
