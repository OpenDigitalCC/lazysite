#!/usr/bin/env bash
#
# Watch the lazysite dist directory and deploy each new version bump to the
# Hestia host as it appears. Detects the latest lazysite-X.Y.Z.tar.gz, and
# on any strictly-higher version, scp/extract/run the Hestia updater.
#
set -euo pipefail

# No defaults that name anyone's infrastructure: this ships in the repository,
# and a hostname baked into a released artefact is a detail about the operator
# rather than about lazysite. Both are required.
HOST=${LAZYSITE_HOST:-}
DIST=${LAZYSITE_DIST:-}
if [ -z "$HOST" ] || [ -z "$DIST" ]; then
    printf 'Set LAZYSITE_HOST and LAZYSITE_DIST.\n' >&2
    printf '  LAZYSITE_HOST  the Hestia host to deploy to\n' >&2
    printf '  LAZYSITE_DIST  the dist/ directory to watch\n' >&2
    exit 2
fi
POLL=${LAZYSITE_POLL:-4}

# True if $1 exists and sits on a fuse (sshfs) filesystem that is responding.
# Fails when the sshfs mount is absent or its transport has dropped.
mount_ok() {
    local dir=$1 fstype
    fstype=$(findmnt -no FSTYPE --target "$dir" 2>/dev/null) || return 1
    case $fstype in fuse.sshfs|fuse*) ;; *) return 1 ;; esac
    ls "$dir" >/dev/null 2>&1
}

# True if $1 is a strictly higher version than $2 (sort -V semantics).
version_gt() {
    [ "$1" != "$2" ] &&
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

# Print the highest lazysite-X.Y.Z.tar.gz version present in $1 (empty if none).
# Ignores the -nginx_*.deb artifacts and any non-plain-numeric versions.
latest_version() {
    local dist=$1 f v best=
    for f in "$dist"/lazysite-[0-9]*.tar.gz; do
        [ -e "$f" ] || continue
        v=${f##*/lazysite-}; v=${v%.tar.gz}
        case $v in *[!0-9.]*) continue ;; esac
        if [ -z "$best" ] || version_gt "$v" "$best"; then
            best=$v
        fi
    done
    [ -n "$best" ] && printf '%s\n' "$best"
}

# True if the tarball for version $1 in dir $2 is non-empty and a complete gzip.
# Guards against racing a build that is still writing the file.
tarball_ready() {
    local f="$2/lazysite-$1.tar.gz"
    [ -s "$f" ] && gzip -t "$f" 2>/dev/null
}

# The flags the updater must be given for a given target version.
#
# SM345 - WHAT CHANGED, AND WHY: this passed `--rebuild` on EVERY deploy.
# `--rebuild` implies `--templates`, so every edge cut refreshed the SHARED
# Hestia web template and rebuilt every domain's vhost - including sites sitting
# on beta and stable, which the release was never meant to reach. That is a
# template change applied to sites running older code, arriving at whatever
# moment their vhost next rebuilds. A channel ladder that gates the code and not
# the template is only half a ladder.
#
# So the default is now a PLAIN deploy. The updater itself is channel-scoped
# (SM345): it works out which sites accept this build and touches only those -
# no repair, no probe, no rebuild on anything else.
#
# --rebuild / --templates are PROMOTION-TIME flags now, passed deliberately:
#   * when the release actually changes the web template, or
#   * when promoting to the channel the affected sites are on.
# Pass them with LAZYSITE_DEPLOY_FLAGS, e.g.
#   LAZYSITE_DEPLOY_FLAGS='--rebuild' ./lazysite-deploy.sh
# The SM270 ordering they exist for still holds inside the updater: refresh,
# rebuild, THEN deploy, so the deploy's permission sweep repairs what Hestia's
# rebuild resets. That ordering is why they must not be run as a separate step.
#
# --reapply-acls re-issues every stored access rule so its content actually
# MOVES out of the document root. From 0.10.8 protecting content moves it, but
# only on the act of protecting - so any section protected on an earlier version
# still has its files in the served tree, with the rule honoured for pages and
# the files public. It changes no rule, and it must run AFTER the upgrade.
# It is per-site and the updater applies it only to sites that actually
# upgraded, so it cannot reach an out-of-scope site.
#
# Version-gated because this watcher deploys whatever appears in dist: passing a
# flag to a release that predates it fails the whole run on an unknown option.
updater_flags() {
    local ver=$1 flags="${LAZYSITE_DEPLOY_FLAGS:-}"
    # An `if`, not `a && b`: this script runs under `set -e` unattended, and a
    # bare AND-list whose left side fails is exactly the construct whose -e
    # behaviour people disagree about. Not worth being clever in a deploy loop.
    if version_gt "$ver" '0.10.8'; then
        flags="$flags --reapply-acls"
    fi
    printf '%s\n' "$flags"
}

# scp + extract + run the Hestia updater for version $1. Streams remote stdout.
#
# RETURNS the updater's own exit status, which SM344 made meaningful:
#   0  rollout succeeded, in-scope fleet clean
#   2  rollout SUCCEEDED and the fleet has findings a human must look at
#   *  the rollout failed
deploy() {
    local ver=$1 src="$DIST/lazysite-$1.tar.gz" flags rc=0
    flags=$(updater_flags "$ver")
    printf '\n=== Deploying %s -> %s (%s) ===\n' "$ver" "$HOST" "${flags:-plain deploy}"
    scp "$src" "$HOST:/tmp" || return 1
    ssh "$HOST" "cd /tmp; tar -xzf lazysite-$ver.tar.gz" || return 1

    # `|| rc=$?` RATHER THAN `set +e` / `set -e` AROUND IT.
    #
    # set -e is a SHELL option, not a function-local one. This used to do
    # `set +e; ssh ...; rc=$?; set -e; return "$rc"` - and that final `set -e`
    # takes effect immediately, so the function returned a non-zero status with
    # -e freshly re-enabled. The caller's own `set +e` had already been undone
    # from underneath it, so the failing command was the CALL to this function
    # and the whole watcher exited.
    #
    # It exited with the updater's own status, which made it invisible: status 2
    # is SM344's "rollout succeeded, fleet has findings" - a SUCCESSFUL deploy.
    # So the watcher deployed, printed the success text, and died, every time
    # the fleet had findings. From outside that is "it deployed once and
    # stopped", and the next release then sat in dist with nothing watching it.
    # 0.10.14 was missed exactly this way, after 0.10.13's deploy returned 2.
    #
    # `|| rc=$?` never trips -e in the first place, so no option needs saving
    # or restoring and there is nothing to leave in the wrong state.
    ssh "$HOST" "cd /tmp; sudo bash /tmp/lazysite-$ver/installers/hestia/lazysite-hestia-update-all.sh $flags /tmp/lazysite-$ver" || rc=$?
    return "$rc"
}

# Watch $DIST and deploy every new version bump as it appears.
watch_and_deploy() {
    local current next rc tick=0 mount_lost=0
    if ! mount_ok "$DIST"; then
        printf 'Error: %s is not on a mounted sshfs filesystem\n' "$DIST" >&2
        exit 1
    fi
    current=$(latest_version "$DIST" || true)
    printf 'Watching %s (baseline: %s)\n' "$DIST" "${current:-none}" >&2
    while true; do
        # A LOST MOUNT IS A PAUSE, NOT AN END. This used to exit, so a transient
        # sshfs drop - which a long deploy is very good at producing, since the
        # transport sits idle while the remote updater runs for minutes - ended
        # the watcher. From the outside that looks like "it deployed once and
        # stopped", because that is exactly what it did.
        #
        # Waiting instead cannot cause a deploy that would not otherwise have
        # happened: the version comparison below is unchanged, and a version
        # already deployed is not deployed again.
        if ! mount_ok "$DIST"; then
            if [ "$mount_lost" -eq 0 ]; then
                printf '\nsshfs mount at %s is not responding - waiting for it\n' \
                    "$DIST" >&2
                mount_lost=1
            fi
            sleep "$POLL"
            continue
        fi
        if [ "$mount_lost" -eq 1 ]; then
            printf 'sshfs mount at %s is back; resuming\n' "$DIST" >&2
            mount_lost=0
        fi
        next=$(latest_version "$DIST" || true)
        if [ -n "$next" ] && { [ -z "$current" ] || version_gt "$next" "$current"; } &&
           tarball_ready "$next" "$DIST"; then
            # Same reasoning as inside deploy(): no option juggling, so
            # nothing can leave -e in a state the other side did not expect.
            rc=0
            deploy "$next" || rc=$?
            case $rc in
                0)
                    printf '\nVersion %s deployed\n\n' "$next" >&2
                    ;;
                2)
                    # SM344: the rollout WORKED. The findings are conditions the
                    # fleet was already in - out-of-scope sites on older lines,
                    # sites needing a repair nobody has run. Re-deploying does
                    # not change them and neither does cutting another version,
                    # so do NOT tell the operator to bump. Saying "failed" here
                    # is what made a working release look broken, and it teaches
                    # the reader to ignore the word when it is true.
                    printf '\nVersion %s deployed - FLEET HAS FINDINGS (see above).\n' "$next" >&2
                    printf 'The deploy succeeded. The findings need a human, not a retry\n' >&2
                    printf 'and not a version bump.\n\n' >&2
                    ;;
                *)
                    printf '\nDeploy of %s FAILED (status %s); skipping (bump again to retry)\n\n' \
                        "$next" "$rc" >&2
                    ;;
            esac
            current=$next
            continue
        fi
        case $((tick % 2)) in 0) printf -- '-\r' >&2 ;; *) printf '|\r' >&2 ;; esac
        tick=$((tick + 1))
        sleep "$POLL"
    done
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    watch_and_deploy
fi
