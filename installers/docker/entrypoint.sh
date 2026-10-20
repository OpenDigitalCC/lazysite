#!/bin/bash
# lazysite container entrypoint (SM1233).
#
#   entrypoint.sh run       install or bring the site up to this image, then run
#                           the pool, lazysited and nginx until told to stop
#                           (the default)
#   entrypoint.sh install   the install step alone
#   entrypoint.sh <cmd>...  anything else is exec'd (a shell, a lazysite tool)
#
# THE INSTALL STEP is install.pl, the one install path, and what it does is
# decided by the site's own install state in the volume, never by the container:
#
#   no state                    provision  a fresh site, into the empty volumes
#   state at this image's       nothing    the volumes' data is left alone; the
#   version                                engine's copy (cgi-bin, tools, lib,
#                                          plugins) lives in the container
#                                          layer, so a RECREATED container lays
#                                          it again with reinstall, which keeps
#                                          content
#   state at another version    upgrade    the sysop chose this image, so the
#                                          site's update channel does not veto it
#                                          (--force, recorded in the audit log)
#
# The paths and the binaries are variables only so that the test can run this
# script against stubs; the defaults are the image's.
set -u

ENGINE=${LAZYSITE_ENGINE:-/usr/share/lazysite}
SITE_ROOT=${LAZYSITE_SITE_ROOT:-/srv/lazysite}
DOCROOT=$SITE_ROOT/html
CGIBIN=$SITE_ROOT/cgi-bin
STATE=$DOCROOT/lazysite/.install-state.json
SITE_USER=${LAZYSITE_USER:-www-data}
SITE_DOMAIN=${SITE_DOMAIN:-localhost}
PERL=${LAZYSITE_PERL:-perl}
NGINX=${LAZYSITE_NGINX:-nginx}
SOCKET_DIR=${LAZYSITE_RUN_DIR:-/run/lazysite}
# lazysited exits 0 when the daemon plugin is off; the timer unit re-runs it
# every five minutes so that switching the plugin on is picked up. The same
# interval, here.
DAEMON_RETRY=${LAZYSITE_DAEMON_RETRY:-300}

log() { printf 'lazysite: %s\n' "$*" >&2; }

# The version of a JSON file's top-level "version" key, or nothing.
json_version() {
    "$PERL" -MJSON::PP -e '
        local $/; open my $fh, "<", $ARGV[0] or exit 0;
        my $d = eval { JSON::PP::decode_json(<$fh>) } or exit 0;
        print $d->{version} // "";
    ' "$1"
}

image_version() {
    local v=""
    if [ -f "$ENGINE/release-manifest.json" ]; then
        v=$(json_version "$ENGINE/release-manifest.json")
    fi
    if [ -z "$v" ] && [ -f "$ENGINE/VERSION" ]; then
        v=$(tr -d '[:space:]' < "$ENGINE/VERSION")
    fi
    printf '%s' "$v"
}

# provision | upgrade | reinstall | none
choose_mode() {
    local installed image
    image=$(image_version)
    if [ -z "$image" ]; then
        log "cannot read this image's version from $ENGINE"
        return 1
    fi
    if [ ! -f "$STATE" ]; then
        echo provision
        return 0
    fi
    installed=$(json_version "$STATE")
    if [ "$installed" != "$image" ]; then
        echo upgrade
    elif [ ! -f "$SITE_ROOT/tools/lazysite-users.pl" ]; then
        echo reinstall
    else
        echo none
    fi
}

install_site() {
    local mode rc
    mode=$(choose_mode) || return 1
    case "$mode" in
        none)
            log "the site is at this image's version; the volumes are left as they are"
            return 0
            ;;
        provision) log "first start: provisioning a new site into the volumes" ;;
        upgrade)   log "the site is at another version: upgrading it to this image's" ;;
        reinstall) log "new container: laying the engine's copy again, keeping content" ;;
    esac

    local args=(--docroot "$DOCROOT" --cgibin "$CGIBIN" --mode "$mode"
        --serving-group "$(id -gn)")
    if [ "$mode" = provision ]; then
        args+=(--domain "$SITE_DOMAIN")
    fi
    if [ "$mode" = upgrade ]; then
        args+=(--force)
    fi

    "$PERL" "$ENGINE/install.pl" "${args[@]}"
    rc=$?
    case "$rc" in
        0) ;;
        4) log "installed, and the health check named a failure (above); the container will run" ;;
        *) log "install.pl $mode failed (exit $rc)"; return 1 ;;
    esac
    if [ "$mode" = provision ]; then
        log "there is no account yet: run  docker compose exec lazysite" \
            "perl $SITE_ROOT/tools/lazysite-users.pl --docroot $DOCROOT setup-sysop --user NAME"
    fi
    return 0
}

PIDS=()
STOPPING=0

stop_all() {
    STOPPING=1
    local p
    for p in "${PIDS[@]}"; do
        kill -TERM "$p" 2>/dev/null
    done
}

# The persistent runtime, restarted the way the timer unit restarts it. Its own
# TERM handler takes the child with it, so a stop leaves nothing behind.
daemon_loop() {
    local rc child=0
    trap '[ "$child" -gt 0 ] && kill -TERM "$child" 2>/dev/null; exit 0' TERM INT
    while :; do
        "$PERL" "$ENGINE/tools/lazysited.pl" --docroot "$DOCROOT" --user "$SITE_USER" &
        child=$!
        wait "$child"
        rc=$?
        child=0
        if [ "$rc" -eq 0 ]; then
            sleep "$DAEMON_RETRY" &
        else
            log "lazysited exited $rc; starting it again"
            sleep 5 &
        fi
        child=$!
        wait "$child"
        child=0
    done
}

run_services() {
    mkdir -p "$SOCKET_DIR"

    trap stop_all TERM INT

    # The pool: one-rule mode (FRONT_DOOR) on the socket the nginx vhost names.
    # Started as www-data, so the launcher skips its privilege drop.
    ( export DOCROOT USER="$SITE_USER" GROUP="$(id -gn)" FRONT_DOOR=1 CGIBIN
      exec "$PERL" "$ENGINE/tools/lazysite-pool.pl" --instance lazysite \
          --run-dir "$SOCKET_DIR" ) &
    PIDS+=($!)

    daemon_loop &
    local daemon_pid=$!
    PIDS+=("$daemon_pid")

    "$NGINX" -g 'daemon off;' &
    PIDS+=($!)

    # Any of the pool or nginx going away ends the container: a container that
    # is up and serves nothing is worse than one the orchestrator restarts.
    local rc=0 pid
    while :; do
        wait -n "${PIDS[@]}"
        rc=$?
        if [ "$STOPPING" -eq 1 ]; then
            break
        fi
        # wait -n does not say which; the daemon loop never exits by itself.
        for pid in "${PIDS[@]}"; do
            if ! kill -0 "$pid" 2>/dev/null; then
                log "process $pid exited ($rc); stopping"
                stop_all
                break 2
            fi
        done
    done
    wait
    if [ "$STOPPING" -eq 1 ] && [ "$rc" -ge 128 ]; then
        rc=0
    fi
    return "$rc"
}

cmd=${1:-run}
case "$cmd" in
    run)
        install_site || exit 1
        run_services
        exit $?
        ;;
    install)
        install_site
        exit $?
        ;;
    *)
        exec "$@"
        ;;
esac
