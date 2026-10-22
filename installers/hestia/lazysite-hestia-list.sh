#!/bin/bash
# lazysite-hestia-list.sh - list every lazysite site on this Hestia host.
# RUN AS ROOT (reads Hestia's per-user registry).
#
#   lazysite-hestia-list.sh [--plain] [--template-only] [--tpl NAME]
#
# Discovery is Hestia-authoritative: a domain is a lazysite site when Hestia's
# own record of what serves it names a lazysite template - a web template
# lazysite-app, lazysite-cgi, lazysite-fcgi or the older lazysite, or the
# lazysite-proxy nginx proxy template (/usr/local/hestia/data/users/<user>/
# web.conf, TPL='...' and PROXY_TPL='...'). That is more robust
# than globbing /home for install markers: it cannot miss a site whose tree
# moved or whose marker was lost, and it cannot pick up a stray copied tree.
# The install marker (public_html/lazysite/.install-state.json) is still read
# as a CROSS-CHECK: by default the listing is the UNION of both signals, with a
# flag when they disagree, so a template-set-but-never-installed domain and a
# marker-without-template domain are both visible instead of silently skipped.
#
#   --plain          machine output for bulk operations, one site per line:
#                    user<TAB>domain<TAB>docroot
#                    (no header, no flags - pipe it into a while read -r loop)
#   --template-only  drop the marker union: list ONLY domains on a lazysite
#                    template. Use this when the template is the authority
#                    (e.g. bulk update), so a marker-without-template domain is
#                    not acted on. Marker-only domains are then simply absent
#                    (the default report still flags them for review).
#   --tpl NAME       match only this template, as a web template or a proxy
#                    template (default: every lazysite template - SM1249). The
#                    batch updater passes --tpl lazysite-app: it deploys the
#                    tarball flow, which is that template's.
#
# Environment (tests / non-standard layouts):
#   LAZYSITE_HESTIA_USERS   Hestia per-user data dir (default
#                           /usr/local/hestia/data/users)
#   LAZYSITE_HOME_BASE      home base holding <user>/web/<domain>/ (default /home)
#
# SM283: the report also flags the FRONT END. On Hestia the path is nginx ->
# Apache and the ACL rules live in the Apache template, so a domain left on a
# stock nginx proxy template has its gated images, PDFs and archives served
# straight off the docroot. A domain that also has an ACL store is flagged
# ACL-BYPASSED-BY-PROXY(SM283) - that one is exposed now; the rest are shown
# with their proxy template so the gap is visible before someone protects a
# folder. Fix with: lazysite-hestia-update-all.sh --proxy
#
# Exit: 0 with sites found (or --plain), 1 on usage error. A discrepancy flag
# does not change the exit status - this tool reports, it never judges.
set -u
shopt -s nullglob

PLAIN=0
TPL_ONLY=0
# SM1249: EVERY LAZYSITE TEMPLATE, by default. This defaulted to lazysite-app
# alone, so on a host whose sites are on the other templates - the deb flow's
# lazysite-cgi / lazysite-fcgi, with lazysite-proxy in front - it reported "0
# sites" for a host full of them. --tpl NAME still narrows it to one.
TPL=''
WEB_TPLS='lazysite lazysite-app lazysite-cgi lazysite-fcgi'
PROXY_TPLS='lazysite-proxy'
while [ $# -gt 0 ]; do
    case "$1" in
        --plain)         PLAIN=1 ;;
        --template-only) TPL_ONLY=1 ;;
        --tpl)   shift; TPL="${1:-}"; [ -n "$TPL" ] || { echo "$0: --tpl needs a name" >&2; exit 1; } ;;
        -h|--help) sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "$0: unknown argument '$1'" >&2; exit 1 ;;
    esac
    shift
done

USERS_DIR="${LAZYSITE_HESTIA_USERS:-/usr/local/hestia/data/users}"
HOME_BASE="${LAZYSITE_HOME_BASE:-/home}"
# The nginx proxy template that carries lazysite's ACL branch (SM283).
PROXY_TPL_WANTED='lazysite-proxy'

# ---- collect: template-declared domains (Hestia registry) -------------------
# web.conf: one line per domain, shell-style KEY='VALUE' fields.
TPL_KEYS=()      # "user/domain" declared by template
declare -A SEEN_TPL=() SUSPENDED=() PROXY_ON=() PROXY_TPL_OF=() WEB_TPL_OF=()

# field LINE KEY - the value of KEY='...' in a web.conf line, or empty. The
# space before KEY is load-bearing: TPL= is also the tail of PROXY_TPL= and
# BACKEND_TPL=, and matching the bare substring read a proxy template as the
# web template.
field() {
    local v
    case " $1" in *" $2='"*) ;; *) return 0 ;; esac
    v=" $1"; v="${v#*" $2='"}"; printf '%s\n' "${v%%\'*}"
}

# is_lazysite_tpl WEB PROXY - does this domain use a template that is matched?
is_lazysite_tpl() {
    local t
    if [ -n "$TPL" ]; then
        [ "$1" = "$TPL" ] || [ "$2" = "$TPL" ]
        return
    fi
    for t in $WEB_TPLS;   do [ "$1" = "$t" ] && return 0; done
    for t in $PROXY_TPLS; do [ "$2" = "$t" ] && return 0; done
    return 1
}

for wc in "$USERS_DIR"/*/web.conf; do
    u="${wc%/web.conf}"; u="${u##*/}"
    while IFS= read -r line; do
        wt=$(field "$line" TPL); pt=$(field "$line" PROXY_TPL)
        is_lazysite_tpl "$wt" "$pt" || continue
        d="${line#DOMAIN=\'}"; d="${d%%\'*}"
        [ -n "$d" ] || continue
        TPL_KEYS+=("$u/$d"); SEEN_TPL["$u/$d"]=1
        WEB_TPL_OF["$u/$d"]="$wt"
        case "$line" in *"SUSPENDED='yes'"*) SUSPENDED["$u/$d"]=1 ;; esac
        # SM283: which front end actually answers a static request. On Hestia
        # the path is nginx -> Apache, and the ACL rules live in the Apache
        # template; a stock nginx proxy serves a fixed list of static
        # EXTENSIONS off the docroot and Apache never sees those requests. So
        # the proxy template assignment is a security property of the site,
        # not a performance one, and it belongs in this report.
        case "$line" in *"PROXY='yes'"*) PROXY_ON["$u/$d"]=1 ;; esac
        [ -n "$pt" ] && PROXY_TPL_OF["$u/$d"]="$pt"
    done < "$wc"
done

# ---- collect: marker-detected trees (cross-check) ---------------------------
MARK_KEYS=()
declare -A SEEN_MARK=()
# SM850: a site whose engine tree was moved out of the docroot keeps its marker
# beside it, in public_html-lazysite/ - read both, or every migrated site reads
# as NO-INSTALL-MARKER.
for state in "$HOME_BASE"/*/web/*/public_html/lazysite/.install-state.json \
             "$HOME_BASE"/*/web/*/public_html-lazysite/.install-state.json; do
    rel="${state#"$HOME_BASE"/}"
    u="${rel%%/*}"
    d="${rel#*/web/}"; d="${d%%/*}"
    [ "${SEEN_MARK[$u/$d]:-0}" = 1 ] && continue    # a tree in BOTH places counts once
    MARK_KEYS+=("$u/$d"); SEEN_MARK["$u/$d"]=1
done

# ---- union, template-declared first, then marker-only -----------------------
# --template-only drops the marker union: the template is the sole authority.
ALL=("${TPL_KEYS[@]}")
if [ "$TPL_ONLY" != 1 ]; then
    for k in "${MARK_KEYS[@]}"; do
        [ "${SEEN_TPL[$k]:-0}" = 1 ] || ALL+=("$k")
    done
fi

# SM850: where a site's engine tree is - <docroot>-lazysite once it has been
# moved out of the document root (SM293), <docroot>/lazysite before. The rule
# Lazysite::Paths::lazysite_dir states; t/lint/37 runs this copy against it.
lazysite_dir() {
    local d="$1"
    while [ "${d%/}" != "$d" ]; do d="${d%/}"; done
    if [ -d "$d-lazysite" ]; then printf '%s\n' "$d-lazysite"; else printf '%s\n' "$d/lazysite"; fi
}

# SM850: inside, outside (migrated), BOTH - a half-finished migration, always a
# fault: the engine reads the outside copy while the front end can still serve
# the inside one - or none.
engine_state() {
    local d="$1" i=0 o=0
    while [ "${d%/}" != "$d" ]; do d="${d%/}"; done
    [ -d "$d/lazysite" ] && i=1
    [ -d "$d-lazysite" ] && o=1
    case "$i$o" in
        10) echo inside ;;
        01) echo outside ;;
        11) echo BOTH ;;
        *)  echo none ;;
    esac
}

ver_of() {    # version from an install-state.json, or "-"
    # (perl -ne exits 0 on a missing file, so test first rather than ||)
    [ -f "$1" ] || { echo '-'; return; }
    perl -MJSON::PP -0777 -ne \
        'my $d=eval{decode_json($_)}; print(($d && $d->{version}) ? $d->{version} : "-")' \
        "$1" 2>/dev/null || echo '-'
}
chan_of() {   # update_channel from lazysite.conf, default "all"
    local c
    c=$(perl -ne 'if(/^\s*update_channel\s*:\s*(\S+)/){print lc $1; exit}' "$1" 2>/dev/null)
    echo "${c:-all}"
}

if [ "$PLAIN" = 1 ]; then
    for k in "${ALL[@]}"; do
        u="${k%%/*}"; d="${k#*/}"
        printf '%s\t%s\t%s\n' "$u" "$d" "$HOME_BASE/$u/web/$d/public_html"
    done
    exit 0
fi

if [ -n "$TPL" ]; then
    _tpls="$TPL"
else
    _tpls="$(printf '%s,' $WEB_TPLS)proxy:$PROXY_TPLS"
fi
if [ "$TPL_ONLY" = 1 ]; then
    echo "lazysite sites on this host: ${#ALL[@]}   (template: $_tpls; template-declared only)"
else
    echo "lazysite sites on this host: ${#ALL[@]}   (template: $_tpls; union with install markers)"
fi
for k in "${ALL[@]}"; do
    u="${k%%/*}"; d="${k#*/}"
    doc="$HOME_BASE/$u/web/$d/public_html"
    lz=$(lazysite_dir "$doc")
    ver=$(ver_of "$lz/.install-state.json")
    ch=$(chan_of "$lz/lazysite.conf")
    flags=''
    # SM850: where the engine tree is. Inside is the default and says nothing;
    # a migrated tree is noted, and one in BOTH places is the fault it always is.
    case "$(engine_state "$doc")" in
        outside) flags="$flags engine=outside" ;;
        BOTH)    flags="$flags ENGINE-IN-BOTH-PLACES(SM293)" ;;
    esac
    # SM1249: which template, now that more than one counts.
    [ -n "${WEB_TPL_OF[$k]:-}" ] && flags="$flags tpl=${WEB_TPL_OF[$k]}"
    [ "${SUSPENDED[$k]:-0}" = 1 ]  && flags="$flags SUSPENDED"
    [ "${SEEN_TPL[$k]:-0}" = 1 ]  || flags="$flags NO-TEMPLATE(marker only)"
    [ "${SEEN_MARK[$k]:-0}" = 1 ] || flags="$flags NO-INSTALL-MARKER"
    # SM283. Two levels, because they are two different statements. A site
    # with an ACL store and a stock proxy IS serving gated files to anyone who
    # knows their path, now. A site without one is not exposed yet and will be
    # the moment someone protects a folder, with nothing to warn them.
    if [ "${PROXY_ON[$k]:-0}" = 1 ] \
        && [ "${PROXY_TPL_OF[$k]:-}" != "$PROXY_TPL_WANTED" ]; then
        if [ -f "$lz/auth/acls.json" ]; then
            flags="$flags ACL-BYPASSED-BY-PROXY(SM283)"
        else
            flags="$flags proxy-tpl=${PROXY_TPL_OF[$k]:-none}"
        fi
    fi
    printf '  %-44s user=%-12s %-9s channel=%-7s%s\n' "$d" "$u" "$ver" "$ch" "$flags"
done
exit 0
