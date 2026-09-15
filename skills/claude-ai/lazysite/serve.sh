#!/bin/sh
# serve.sh start|stop|status - the local dev server.
#
# SM887. Separate from setup.sh because a conversation restarts it more often
# than it installs: the background process lives only as long as the
# conversation, and a page that used to render and now does not is usually a
# server that went away rather than a page that broke.
#
# 127.0.0.1 ONLY, and that is not a hardening flourish - the container has no
# inbound network, so the editor cannot open this in a browser. Every result
# has to be text you fetch and read.
set -e

SKILL_DIR=$(cd "$(dirname "$0")" && pwd)
LAZYSITE_HOME=${LAZYSITE_HOME:-/root/lazysite-local}
SITE=${LAZYSITE_SITE:-$LAZYSITE_HOME/site}
PORT=${LAZYSITE_PORT:-8080}
PIDFILE="$LAZYSITE_HOME/server.pid"
LOG="$LAZYSITE_HOME/server.log"

running() {
    [ -f "$PIDFILE" ] || return 1
    pid=$(cat "$PIDFILE" 2>/dev/null) || return 1
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null
}

case "${1:-start}" in
start)
    if running; then
        echo "lazysite: dev server already on http://127.0.0.1:$PORT/ (pid $(cat "$PIDFILE"))"
        exit 0
    fi
    [ -d "$SITE" ] || {
        echo "lazysite: no site at $SITE - run setup.sh first" >&2
        exit 1
    }
    mkdir -p "$LAZYSITE_HOME"
    # --cache is deliberately NOT passed: a cached render is the wrong answer
    # to "does my edit work", and the whole point here is the edit.
    perl /usr/share/lazysite/tools/lazysite-server.pl \
        --docroot "$SITE" --port "$PORT" --host 127.0.0.1 \
        >"$LOG" 2>&1 &
    echo $! >"$PIDFILE"

    # Wait for it to answer rather than sleeping a guess: the instance endpoint
    # is no-store and cheap, and it reports the engine that is actually running.
    #
    # fetch.pl, not curl: ubuntu:24.04 does not ship curl, and a readiness probe
    # that is missing reads exactly like a server that never came up.
    i=0
    while [ "$i" -lt 60 ]; do
        if perl "$SKILL_DIR/fetch.pl" "http://127.0.0.1:$PORT/.well-known/lazysite-instance.json" >/dev/null 2>&1; then
            echo "lazysite: dev server on http://127.0.0.1:$PORT/ serving $SITE"
            exit 0
        fi
        i=$((i + 1))
        sleep 0.25
    done
    echo "lazysite: the dev server did not answer within 15s - see $LOG" >&2
    tail -5 "$LOG" >&2 2>/dev/null || true
    exit 1
    ;;
stop)
    if running; then
        kill "$(cat "$PIDFILE")" 2>/dev/null || true
        rm -f "$PIDFILE"
        echo "lazysite: dev server stopped"
    else
        echo "lazysite: no dev server running"
    fi
    ;;
status)
    if running; then
        echo "lazysite: running on http://127.0.0.1:$PORT/ (pid $(cat "$PIDFILE")) serving $SITE"
    else
        echo "lazysite: not running"
        exit 1
    fi
    ;;
*)
    echo "Usage: serve.sh [start|stop|status]" >&2
    exit 2
    ;;
esac
