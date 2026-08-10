#!/bin/bash
# lazysite-hestia-update-all.sh - update EVERY lazysite site on this Hestia
# host from one staged release. RUN AS ROOT.
#
#   lazysite-hestia-update-all.sh [--list] [--templates] [STAGE_DIR]
#
# It discovers lazysite sites Hestia-authoritatively, via lazysite-hestia-list.sh
# --template-only: a domain is updated only when its Hestia web template is
# lazysite-app. It then runs the normal per-site deploy (install.pl + perms) for
# each - i.e. the code, starter content and permissions are updated everywhere
# from one release. The per-site deploy treats each as an UPGRADE and leaves the
# Hestia web template assignment untouched (it does not re-run
# v-change-web-domain-tpl). A domain that carries an install marker but is NO
# longer on the lazysite-app template (template deliberately changed away, or an
# anomaly) is NOT updated - it is reported as excluded so the operator can
# reconcile it, never silently deployed to.
#
#   --list        discover and report only; make no changes.
#   --templates   ALSO refresh the shared lazysite-app Hestia web template FILES
#                 from STAGE before deploying, so a later vhost change (e.g. the
#                 SSI options) is staged. This only updates the shared template
#                 files; existing domains keep their generated vhost until they
#                 are rebuilt - run `v-rebuild-web-domain USER DOMAIN` (or deploy
#                 with LAZYSITE_APPLY_TEMPLATE=1) on the domains you want to pick
#                 up the change, having confirmed they use lazysite-app.
#   --rebuild     SM270: refresh the template, REBUILD each domain's vhost, and
#                 then deploy - in that order. Implies --templates.
#
#                 The order is the whole point. Hestia's v-rebuild-web-domain
#                 re-applies its own docroot permissions (2751: setgid, NO group
#                 write), and the deploy's permission sweep is what repairs that.
#                 Rebuilding AFTER the deploy - which is what the manual
#                 instructions ask for - leaves the docroot unwritable by the
#                 CGI, and nothing notices until the manager fails to save. A
#                 live 0.10.5 upgrade hit exactly this.
#
#   STAGE_DIR     the unpacked release (default: this script's release root).
#
# A per-site failure is reported and the run continues; the exit status is
# non-zero if any site failed.
set -u
shopt -s nullglob

LIST=0
DO_TPL=0
DO_REBUILD=0
ARGS=()
for a in "$@"; do
    case "$a" in
        --list)       LIST=1 ;;
        --templates)  DO_TPL=1 ;;
        --rebuild)    DO_REBUILD=1; DO_TPL=1 ;;
        *)            ARGS+=("$a") ;;
    esac
done
STAGE="${ARGS[0]:-$(cd "$(dirname "$0")/../.." && pwd)}"

[ "$(id -u)" = 0 ] || { echo "$0: must run as root" >&2; exit 1; }
DEPLOY="$STAGE/installers/hestia/lazysite-hestia-deploy.sh"
[ -f "$DEPLOY" ] || { echo "$0: no deploy script under STAGE '$STAGE'" >&2; exit 2; }

HESTIA=/usr/local/hestia
TPLDIR="$HESTIA/data/templates/web/apache2/php-fpm"

ver_of() {   # print the "version" from an install-state.json, or "?"
    # (perl -ne exits 0 on a missing file, so test first rather than ||)
    [ -f "$1" ] || { echo '?'; return; }
    perl -MJSON::PP -0777 -ne 'my $d=eval{decode_json($_)}; print(($d && $d->{version}) ? $d->{version} : "?")' "$1" 2>/dev/null || echo '?'
}

# --- discover lazysite sites -------------------------------------------------
# Preferred: lazysite-hestia-list.sh --template-only - the Hestia web template
# (lazysite-app) is the sole authority for what we update. A marker-only domain
# (marker present, template changed away) is deliberately excluded here and
# reported below, so we never re-deploy over a domain the operator has moved off
# lazysite. Fallback (older STAGE without the lister): the original marker glob,
# which cannot see the template and so updates every marked tree.
USERS=(); DOMAINS=(); VERS=(); EXCLUDED=()
LISTER="$STAGE/installers/hestia/lazysite-hestia-list.sh"
if [ -f "$LISTER" ]; then
    while IFS=$'\t' read -r u d doc; do
        [ -n "$d" ] || continue
        USERS+=( "$u" ); DOMAINS+=( "$d" )
        VERS+=( "$(ver_of "$doc/lazysite/.install-state.json")" )
    done < <(bash "$LISTER" --plain --template-only)
    # Marker-only domains = the union minus the template set: excluded from the
    # update, but surfaced so the operator can reconcile template vs marker.
    declare -A _IN_TPL=()
    for i in "${!DOMAINS[@]}"; do _IN_TPL["${USERS[$i]}/${DOMAINS[$i]}"]=1; done
    while IFS=$'\t' read -r u d doc; do
        [ -n "$d" ] || continue
        [ "${_IN_TPL[$u/$d]:-0}" = 1 ] || EXCLUDED+=( "$d (user $u)" )
    done < <(bash "$LISTER" --plain)
else
    for state in /home/*/web/*/public_html/lazysite/.install-state.json; do
        USERS+=(   "$(echo "$state" | cut -d/ -f3)" )
        DOMAINS+=( "$(echo "$state" | cut -d/ -f5)" )
        VERS+=(    "$(ver_of "$state")" )
    done
fi

n=${#DOMAINS[@]}
NEWVER="$(ver_of "$STAGE/release-manifest.json")"
[ "$NEWVER" = '?' ] && NEWVER="$( [ -f "$STAGE/VERSION" ] && cat "$STAGE/VERSION" || echo unknown )"

echo "lazysite sites on this host: $n   (staged release: $NEWVER)"
for i in "${!DOMAINS[@]}"; do
    printf '  %-44s user=%-12s %s\n' "${DOMAINS[$i]}" "${USERS[$i]}" "${VERS[$i]}"
done
if [ "${#EXCLUDED[@]}" -gt 0 ]; then
    echo
    printf 'EXCLUDED %d domain(s): install marker present but NOT on the lazysite-app template - not updated:\n' "${#EXCLUDED[@]}"
    printf '  %s\n' "${EXCLUDED[@]}"
    echo '  (run lazysite-hestia-list.sh to review; re-set the template or remove the stale marker to reconcile.)'
fi
[ "$LIST" = 1 ] && exit 0
[ "$n" -gt 0 ] || { echo "Nothing to update."; exit 0; }

# --- refresh the shared Hestia web template (so vhost changes propagate) -----
if [ "$DO_TPL" = 1 ] && [ -d "$TPLDIR" ]; then
    echo "==> refreshing the lazysite-app web template in $TPLDIR"
    cp "$STAGE/installers/hestia/lazysite-app.tpl"  "$TPLDIR/lazysite-app.tpl"
    cp "$STAGE/installers/hestia/lazysite-app.stpl" "$TPLDIR/lazysite-app.stpl"
    cp "$STAGE/installers/hestia/lazysite-app.sh"   "$TPLDIR/lazysite-app.sh"
    chmod 755 "$TPLDIR/lazysite-app.sh"
fi

# --- rebuild each vhost, BEFORE deploying (SM270) ----------------------------
# Deliberately between the template refresh and the deploy: the refresh puts the
# new template in place, the rebuild renders it (resetting docroot permissions
# on the way), and the deploy's permission sweep then repairs what the rebuild
# reset. Any other order leaves the site unwritable.
if [ "$DO_REBUILD" = 1 ]; then
    echo "==> rebuilding vhosts (picks up the refreshed template)"
    for i in "${!DOMAINS[@]}"; do
        d="${DOMAINS[$i]}"; u="${USERS[$i]}"
        if "$HESTIA/bin/v-rebuild-web-domain" "$u" "$d" >/dev/null 2>&1; then
            echo "    rebuilt: $d"
        else
            echo "    REBUILD FAILED: $d (user $u) - deploy will still run" >&2
        fi
    done
fi

# --- deploy each -------------------------------------------------------------
# Per-site exit: 0 = updated, 4 = skipped by the site's update channel (stable
# site, edge release), anything else = failed.
ok=0; SKIPPED=(); FAILED=()
for i in "${!DOMAINS[@]}"; do
    d="${DOMAINS[$i]}"; u="${USERS[$i]}"
    echo; echo "################ $d (user $u) ################"
    bash "$DEPLOY" "$u" "$d" "$STAGE"; rc=$?
    if   [ "$rc" = 0 ]; then ok=$(( ok + 1 ))
    elif [ "$rc" = 4 ]; then SKIPPED+=( "$d" )
    else                     FAILED+=( "$d" )
    fi
done

echo
echo "Updated $ok/$n site(s) to $NEWVER.  Skipped ${#SKIPPED[@]} (stable channel).  Failed ${#FAILED[@]}."
[ "${#SKIPPED[@]}" -gt 0 ] && printf 'SKIPPED (stable site, edge release not installed): %s\n' "${SKIPPED[*]}"
[ "${#FAILED[@]}" -gt 0 ]  && printf 'FAILED to upgrade: %s\n' "${FAILED[*]}"

# --- consolidated health summary: warnings + failures grouped by site --------
# Re-run the doctor read-only per site so the operator sees what (if anything) is
# still outstanding in one place, without scrolling each site's block.
CHK="$STAGE/tools/lazysite-check.pl"
if [ -f "$CHK" ]; then
    echo
    echo "==> health summary (warnings + failures by site)"
    dirty=0
    for i in "${!DOMAINS[@]}"; do
        d="${DOMAINS[$i]}"; u="${USERS[$i]}"
        doc="/home/$u/web/$d/public_html"
        [ -d "$doc" ] || continue
        issues="$(perl "$CHK" --docroot "$doc" --cgibin "/home/$u/web/$d/cgi-bin" 2>/dev/null \
                  | grep -E '\[ (warn|FAIL) \]')"
        if [ -n "$issues" ]; then
            dirty=$(( dirty + 1 ))
            echo "  $d:"
            echo "$issues" | sed 's/^[[:space:]]*/    /'
        fi
    done
    [ "$dirty" = 0 ] && echo "  all sites clean - no warnings or failures."
fi

# --- final summary: every site, the version it is on NOW, and its channel ------
chan_of() {   # update_channel from a lazysite.conf, default 'all'
    perl -ne 'if(/^\s*update_channel\s*:\s*(\S+)/){print lc $1; exit}' "$1" 2>/dev/null
}
in_list() { local x="$1"; shift; for e in "$@"; do [ "$e" = "$x" ] && return 0; done; return 1; }

echo
echo "==> site versions (staged release: $NEWVER)"
for i in "${!DOMAINS[@]}"; do
    d="${DOMAINS[$i]}"; u="${USERS[$i]}"
    base="/home/$u/web/$d/public_html/lazysite"
    now="$(ver_of "$base/.install-state.json")"
    ch="$(chan_of "$base/lazysite.conf")"; [ -z "$ch" ] && ch="all"
    status="updated"
    in_list "$d" "${SKIPPED[@]}" && status="SKIPPED (stable)"
    in_list "$d" "${FAILED[@]}"  && status="FAILED"
    printf '  %-44s %-9s channel=%-7s %s\n' "$d" "$now" "$ch" "$status"
done

[ "${#FAILED[@]}" -gt 0 ] && exit 1
exit 0
