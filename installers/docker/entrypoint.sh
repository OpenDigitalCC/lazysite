#!/bin/bash
# shellcheck disable=SC2016  # the single-quoted strings are Perl programs, expanded by Perl
# lazysite container entrypoint (SM1233; SM1361, rulings 201, 205, 206, 208, 210).
#
# ONE CONTAINER, MANY SITES. The image is the engine, read-only. The sites are
# folders in one parent volume, listed in its sites.conf:
#
#   /srv/sites/sites.conf                  one line per site: NAME DOMAIN [ALIAS...]
#   /srv/sites/NAME/html                   the site's docroot
#   /srv/sites/NAME/html-lazysite          its settings, accounts, stores, keys,
#                                          logs, backups and install state
#   /srv/sites/NAME/html-lazysite-private  its protected content
#
#   entrypoint.sh run   bring every listed site up to this image, then run nginx
#                       and each site's pool and runtime until told to stop (the
#                       default). SIGHUP re-reads sites.conf: a site added is
#                       started, a site removed is stopped, a refused or crashed
#                       site is tried again - no restart (lazysite-sites).
#   entrypoint.sh <cmd>...  anything else is exec'd (a shell, a lazysite tool)
#
# EACH SITE ON ITS OWN, decided by its own install state, never by the others:
#
#   no state                  provision   a fresh site, seeded with its domain
#   older than this image     upgrade     the operator chose the image, so the
#                                         site's update channel does not veto it
#                                         (--force, in the site's audit log)
#   at this image's version   reinstall   the engine's templates, manager pages
#                                         and assets are copied in again
#                                         (ruling 205)
#   NEWER than this image     REFUSED     an older engine on newer state is a
#                                         downgrade nobody chose (ruling 205);
#                                         the restore command is printed
#
# A site whose install fails, or whose health check names a failure, is REFUSED
# too (ruling 206): it is not started, it answers 503, and `lazysite-sites
# status` and the log name it. The other sites serve. Every process runs as
# www-data (ruling 210) and the engine runs from the image (install.pl --engine
# shared): nothing of the engine is copied into a site.
#
# A crashed pool is restarted for that site alone, with backoff; five crashes in
# ten minutes leave it `crashed` (503) until `lazysite-sites restart NAME`. The
# container ends only when nginx or this supervisor does (ruling 208).
#
# The paths and binaries are variables only so that the test can run this
# script against stubs; the defaults are the image's.
set -u

ENGINE=${LAZYSITE_ENGINE:-/usr/share/lazysite}
SITES=${LAZYSITE_SITES:-/srv/sites}
CONF=$SITES/sites.conf
RUN=${LAZYSITE_RUN_DIR:-/run/lazysite}
STATUS=$RUN/status
NGINX_DIR=${LAZYSITE_NGINX_DIR:-/tmp/nginx/sites}
PERL=${LAZYSITE_PERL:-perl}
NGINX=${LAZYSITE_NGINX:-nginx}
SITE_USER=${LAZYSITE_USER:-www-data}
PORT=${LAZYSITE_PORT_INTERNAL:-8080}
WORKERS=${LAZYSITE_WORKERS:-2}
DAEMON_RETRY=${LAZYSITE_DAEMON_RETRY:-300}
BACKOFF=${LAZYSITE_BACKOFF:-5}
CRASH_LIMIT=${LAZYSITE_CRASH_LIMIT:-5}
CRASH_WINDOW=${LAZYSITE_CRASH_WINDOW:-600}
TEMPLATE=$ENGINE/installers/nginx/vhost-one-rule-pool.conf.example

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

# -1, 0 or 1: is version A below, at or above version B (numeric, dot by dot;
# a pre-release suffix is ignored).
vercmp() {
    "$PERL" -e '
        my @a = map { /^(\d+)/ ? $1 : 0 } split /\./, $ARGV[0];
        my @b = map { /^(\d+)/ ? $1 : 0 } split /\./, $ARGV[1];
        for my $i ( 0 .. ( $#a > $#b ? $#a : $#b ) ) {
            my $c = ( $a[$i] // 0 ) <=> ( $b[$i] // 0 );
            if ($c) { print $c; exit 0 }
        }
        print 0;
    ' "$1" "$2"
}

status_set() {    # NAME STATE [WHY]
    mkdir -p "$STATUS"
    printf '%s\t%s\n' "$2" "${3:-}" > "$STATUS/$1.tmp"
    mv "$STATUS/$1.tmp" "$STATUS/$1"
    log "site $1: $2${3:+ - $3}"
}

# The sites.conf lines, as "NAME DOMAIN [ALIAS...]". A malformed line is named
# and left out; it never stops the other sites.
read_sites() {
    [ -f "$CONF" ] || return 0
    local name domains
    while read -r name domains; do
        case "$name" in '' | '#'*) continue ;; esac
        if ! [[ $name =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || [ -z "$domains" ] \
            || ! [[ $domains =~ ^[A-Za-z0-9.\ -]+$ ]]; then
            log "sites.conf: '$name $domains' is not NAME DOMAIN [ALIAS...] - left out"
            continue
        fi
        printf '%s %s\n' "$name" "$domains"
    done < "$CONF"
}

# The version of the install state a backup holds, or nothing. A backup's name
# says the version it was taken BEFORE; a reinstall's backup holds that same
# version, so only what is inside says whether this image can run it. The
# installer writes its members with their absolute names (create_backup).
backup_version() {    # BACKUP STATE_PATH
    tar --absolute-names -xzOf "$1" "$2" 2> /dev/null | "$PERL" -MJSON::PP -e '
        local $/; my $d = eval { JSON::PP::decode_json(<STDIN>) } or exit 0;
        print $d->{version} // "";'
}

# The restore command for a site refused as newer than this image: each backup
# that holds a version this image can run, the newest last.
restore_hint() {    # NAME STATE_VERSION IMAGE_VERSION
    local b v found=0 state=$SITES/$1/html-lazysite/.install-state.json
    for b in "$SITES/$1/html-lazysite/backups"/lazysite-backup-*.tar.gz; do
        [ -f "$b" ] || continue
        v=$(backup_version "$b" "$state")
        [ -n "$v" ] || continue
        [ "$(vercmp "$v" "$3")" -le 0 ] || continue
        found=1
        log "  restore it with:  lazysite-sites restore $1 $b   (it holds $v)"
    done
    if [ "$found" -eq 0 ]; then
        log "  no backup in $SITES/$1/html-lazysite/backups holds a version this image ($3) can run;"
        log "  run the site on an image at $2 or later"
    fi
}

# Bring one site to this image. 0 = serve it; 1 = refused (the status says why).
install_site() {    # NAME DOMAIN
    local name=$1 domain=$2 dir=$SITES/$1
    local docroot=$dir/html state=$dir/html-lazysite/.install-state.json
    local image installed mode cmp rc
    image=$(image_version)
    if [ -z "$image" ]; then
        status_set "$name" refused "this image's version cannot be read from $ENGINE"
        return 1
    fi
    mkdir -p "$docroot" "$dir/html-lazysite" "$dir/html-lazysite-private"
    chmod 2775 "$docroot" "$dir/html-lazysite" 2> /dev/null
    chmod 2770 "$dir/html-lazysite-private" 2> /dev/null
    if [ ! -f "$state" ]; then
        mode=provision
    else
        installed=$(json_version "$state")
        if [ -z "$installed" ]; then
            status_set "$name" refused "its install state cannot be read ($state) - run: lazysite-sites check $name"
            return 1
        fi
        cmp=$(vercmp "$installed" "$image")
        case "$cmp" in
            -1) mode=upgrade ;;
            0) mode=reinstall ;;
            *)
                # The hint first: the state is what a reader waits on.
                log "site $name: at $installed, newer than this image ($image)"
                restore_hint "$name" "$installed" "$image"
                status_set "$name" refused "it is at $installed and this image is $image - an older engine is never run on newer state"
                return 1
                ;;
        esac
    fi
    local args=(--docroot "$docroot" --cgibin "$ENGINE" --mode "$mode" --engine shared
        --serving-group "$(id -gn)")
    if [ "$mode" = provision ]; then
        args+=(--domain "$domain")
    fi
    if [ "$mode" = upgrade ]; then
        args+=(--force)
    fi
    log "site $name: $mode"
    "$PERL" "$ENGINE/install.pl" "${args[@]}" >&2
    rc=$?
    case "$rc" in
        0) ;;
        4)
            status_set "$name" refused "installed, and its health check named a failure - run: lazysite-sites check $name"
            return 1
            ;;
        *)
            status_set "$name" refused "install.pl $mode failed (exit $rc) - see the lines above, and run: lazysite-sites check $name"
            return 1
            ;;
    esac
    if [ "$mode" = provision ]; then
        log "site $name has no account yet: lazysite-sites sysop $name NAME"
    fi
    return 0
}

# nginx: one server block per site, from the one-rule pool template, or a 503
# for a site that is not serving.
vhost_serve() {    # NAME DOMAIN [ALIAS...]
    local name=$1
    shift
    # The template's comments are its documentation, and name the placeholders.
    sed -e '/^[[:space:]]*#/d' \
        -e "s#server_name __DOMAIN__;#server_name $*;#" \
        -e "s#/run/lazysite/__DOMAIN__\.sock#$RUN/$name.sock#" \
        -e "s#/var/log/nginx/__DOMAIN__\.access\.log#/dev/stdout#" \
        -e "s#/var/log/nginx/__DOMAIN__\.error\.log#stderr#" \
        -e "s#__DOCROOT__#$SITES/$name/html#g" \
        -e "s#__PORT__#$PORT#g" \
        "$TEMPLATE" > "$NGINX_DIR/$name.conf.tmp" || return 1
    if grep -q '__[A-Z]*__' "$NGINX_DIR/$name.conf.tmp"; then
        log "site $name: the vhost template left a placeholder unfilled"
        rm -f "$NGINX_DIR/$name.conf.tmp"
        return 1
    fi
    mv "$NGINX_DIR/$name.conf.tmp" "$NGINX_DIR/$name.conf"
}

vhost_refuse() {    # NAME DOMAIN [ALIAS...]
    local name=$1
    shift
    printf 'server {\n    listen %s;\n    server_name %s;\n    default_type text/plain;\n    return 503 "This site is not serving. Its operator: lazysite-sites status\\n";\n}\n' \
        "$PORT" "$*" > "$NGINX_DIR/$name.conf"
}

vhost_default() {
    printf 'server {\n    listen %s default_server;\n    server_name _;\n    location = /lazysite-health { return 204; }\n    location / { return 404; }\n    access_log /dev/stdout;\n    error_log stderr;\n}\n' \
        "$PORT" > "$NGINX_DIR/00-default.conf"
}

nginx_reload() {
    local pid
    pid=$(cat "$RUN/nginx.pid" 2> /dev/null) || return 0
    kill -HUP "$pid" 2> /dev/null || true
}

# One site's pool and runtime, supervised. Runs in its own background process
# (its pid is $RUN/sites/NAME.pid); TERM stops both.
site_supervisor() {    # NAME DOMAIN [ALIAS...]
    local name=$1
    local docroot=$SITES/$1/html
    local pool=0 daemon=0 stopping=0 rc now
    local -a crashes=()
    trap 'stopping=1; [ "$pool" -gt 0 ] && kill -TERM "$pool" 2>/dev/null; [ "$daemon" -gt 0 ] && kill -TERM "$daemon" 2>/dev/null' TERM INT

    (
        trap 'kill -TERM "$child" 2>/dev/null; exit 0' TERM INT
        child=0
        while :; do
            "$PERL" "$ENGINE/tools/lazysited.pl" --docroot "$docroot" --user "$SITE_USER" &
            child=$!
            wait "$child"
            rc=$?
            if [ "$rc" -eq 0 ]; then sleep "$DAEMON_RETRY" & else sleep 5 & fi
            child=$!
            wait "$child"
        done
    ) &
    daemon=$!

    local delay=$BACKOFF
    while :; do
        ( GROUP=$(id -gn)
          export DOCROOT="$docroot" USER="$SITE_USER" GROUP FRONT_DOOR=1 \
              CGIBIN="$ENGINE" WORKERS="$WORKERS"
          exec "$PERL" "$ENGINE/tools/lazysite-pool.pl" --instance "$name" --run-dir "$RUN" ) &
        pool=$!
        status_set "$name" serving
        wait "$pool"
        rc=$?
        pool=0
        [ "$stopping" -eq 1 ] && break
        now=$(date +%s)
        crashes+=("$now")
        local recent=() t
        for t in "${crashes[@]}"; do
            [ $((now - t)) -lt "$CRASH_WINDOW" ] && recent+=("$t")
        done
        crashes=("${recent[@]}")
        if [ "${#crashes[@]}" -ge "$CRASH_LIMIT" ]; then
            status_set "$name" crashed "its pool exited $rc, ${#crashes[@]} times in ${CRASH_WINDOW}s - run: lazysite-sites check $name, then lazysite-sites restart $name"
            shift
            vhost_refuse "$name" "$@"
            nginx_reload
            break
        fi
        status_set "$name" restarting "its pool exited $rc; starting it again in ${delay}s"
        sleep "$delay" &
        wait $!
        [ "$stopping" -eq 1 ] && break
        delay=$((delay * 2))
        [ "$delay" -gt 300 ] && delay=300
    done
    kill -TERM "$daemon" 2> /dev/null
    wait "$daemon" 2> /dev/null
}

site_running() {    # NAME
    local pid
    pid=$(cat "$RUN/sites/$1.pid" 2> /dev/null) || return 1
    kill -0 "$pid" 2> /dev/null
}

site_stop() {    # NAME
    local pid
    pid=$(cat "$RUN/sites/$1.pid" 2> /dev/null) || return 0
    kill -TERM "$pid" 2> /dev/null
    wait "$pid" 2> /dev/null
    rm -f "$RUN/sites/$1.pid"
}

# Bring the running set to what sites.conf lists. A site held for a restore
# (lazysite-sites restore) is left stopped until the hold is lifted.
reconcile() {
    mkdir -p "$RUN/sites" "$RUN/hold" "$STATUS" "$NGINX_DIR"
    local name domains listed=" " f
    while read -r name domains; do
        [ -n "$name" ] || continue
        listed+="$name "
        # shellcheck disable=SC2086  # the domains are words by construction (read_sites)
        if [ -e "$RUN/hold/$name" ]; then
            site_stop "$name"
            status_set "$name" held "held for a restore"
            vhost_refuse "$name" $domains
            continue
        fi
        site_running "$name" && continue
        # shellcheck disable=SC2086
        if install_site "$name" "${domains%% *}" && vhost_serve "$name" $domains; then
            site_supervisor "$name" $domains &
            echo $! > "$RUN/sites/$name.pid"
        else
            vhost_refuse "$name" $domains
        fi
    done < <(read_sites)
    for f in "$RUN"/sites/*.pid; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .pid)
        case "$listed" in *" $name "*) continue ;; esac
        site_stop "$name"
        rm -f "$NGINX_DIR/$name.conf" "$STATUS/$name"
        log "site $name: removed (its folder is left in $SITES)"
    done
    for f in "$STATUS"/*; do
        [ -f "$f" ] || continue
        name=$(basename "$f")
        case "$listed" in *" $name "*) continue ;; esac
        rm -f "$f" "$NGINX_DIR/$name.conf"
    done
    nginx_reload
}

STOPPING=0
NGINX_PID=0

stop_all() {
    STOPPING=1
    local f
    for f in "$RUN"/sites/*.pid; do
        [ -f "$f" ] && site_stop "$(basename "$f" .pid)"
    done
    [ "$NGINX_PID" -gt 0 ] && kill -TERM "$NGINX_PID" 2> /dev/null
}

run_all() {
    mkdir -p "$RUN" "$NGINX_DIR" "$RUN/sites" "$STATUS"
    rm -f "$RUN"/sites/*.pid "$STATUS"/*
    echo $$ > "$RUN/supervisor.pid"
    vhost_default
    [ -f "$CONF" ] || log "no sites yet: add one with  lazysite-sites add NAME DOMAIN"

    trap stop_all TERM INT
    trap 'reconcile' HUP

    "$NGINX" -g 'daemon off;' &
    NGINX_PID=$!
    echo "$NGINX_PID" > "$RUN/nginx.pid"
    reconcile

    local rc
    while :; do
        wait "$NGINX_PID"
        rc=$?
        [ "$STOPPING" -eq 1 ] && break
        # A signal (SIGHUP's reconcile) interrupts the wait; nginx is still up.
        kill -0 "$NGINX_PID" 2> /dev/null && continue
        log "nginx exited ($rc); stopping every site"
        stop_all
        wait
        return 1
    done
    wait
    return 0
}

cmd=${1:-run}
case "$cmd" in
    run)
        run_all
        exit $?
        ;;
    *)
        exec "$@"
        ;;
esac
