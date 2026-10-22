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
#   --verbose     stream every phase's full output, as this script did before
#                 the report was trimmed. The default is QUIET: one table of
#                 what was discovered, then only warnings and failures, then a
#                 summary table. A rollout across a large fleet otherwise
#                 reports thousands of lines in which the two that matter are
#                 indistinguishable from the rest - the operator asked for the
#                 signal, not the transcript. A site that FAILS still prints its
#                 whole captured output regardless of this flag, because the
#                 detail of a failure is the one thing never worth suppressing.
#   (always)      SM1196: before anything is rebuilt, every lazysite template
#                 Hestia has installed (lazysite-proxy in nginx/, lazysite-app,
#                 lazysite-cgi, lazysite-fcgi in apache2/php-fpm/) is compared
#                 with the release's copy and replaced when it differs, the old
#                 one kept beside it as NAME.EXT.bak-TIMESTAMP; the domains on
#                 it are named, and --rebuild rebuilds them. Hestia renders from
#                 ITS copy, so a rebuild cannot help while that copy is old. A
#                 refresh that cannot write is a FAILURE line and exit status 1.
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
#                 SM270 RECURRED on edge in August 2026 all the same, three
#                 releases after the ordering was fixed - a rebuild driven
#                 through the control panel's own path never reaches this script
#                 at all. So the health summary at the end of EVERY run now
#                 repairs what it finds rather than only reporting it, and then
#                 re-checks. Ordering is still the right first answer; it just
#                 cannot be the only one, because not every rebuild comes
#                 through here.
#
#   --reapply-acls  SM286/SM296: after upgrading, re-issue every stored access
#                 rule on every site so its content actually moves out of the
#                 document root. Protecting content moves it only on the ACT of
#                 protecting, so ANY section protected before 0.10.9 still has
#                 its files in the served tree - the rule is honoured for pages
#                 and the files are public. On 0.10.8 the SM296 crash produced
#                 the same state on sites that DID protect something.
#                 Changes no rule; moves bytes. Opt-in, because it moves content
#                 on a live site.
#   --reapply-acls-dry-run  SM1238: the 0.16.0 ON UPGRADE "SM296 dry run",
#                 automated: `lazysite-acl.pl reapply` WITHOUT --apply, per site
#                 that upgraded, as the site's own user. Each "NOT MOVED: <path>"
#                 it prints - a rule stored with its files still in the document
#                 root - is a finding, and the run exits 2 if there is one.
#                 Changes nothing. With --reapply-acls as well it runs after the
#                 apply, so it reports what the apply left.
#   --proxy       SM283: ALSO stage the lazysite-proxy nginx templates and put
#                 every discovered domain on them (v-change-web-domain-proxy-tpl,
#                 which rebuilds the vhost). Implies --templates.
#
#                 This is the one thing here that changes a TEMPLATE ASSIGNMENT
#                 rather than a template file, and it is opt-in for that reason.
#                 It is also the only way an existing site gets the SM283 fix: a
#                 package upgrade cannot deliver it, because the layer at fault
#                 is nginx and lazysite shipped no template for it until now.
#                 Until a domain is moved, its gated images, PDFs and archives
#                 are served straight off the docroot by nginx and the correct
#                 Apache ACL rules never see the request.
#
#   STAGE_DIR     the unpacked release (default: this script's release root).
#
# SM317: every run ends with an OUTSIDE-IN ACL probe per site - it gates a probe
# folder, fetches it anonymously over https, and reports whether the FRONT END
# honoured the rule. Set DO_ACL_PROBE=0 to skip it.
#
# This is on by default because the tool existed and nothing ran it. The engine's
# report and the front end's behaviour are different claims, and they have now
# disagreed three times: SM283 for weeks across a live fleet, SM296's crash
# leaving the same state, and SM313's repair that looked complete. Measured on
# edge after a successful docroot repair, eight of ten extensions still served
# 200 anonymously from a folder with an active read list.
#
# It belongs here rather than in the release gate: the gate runs offline against
# a clean checkout of a tag, so there is no deployed site to fetch. The question
# is a property of a SITE, not of a build.
#
# A per-site failure is reported and the run continues; the exit status is
# non-zero if any site failed, if a proxy move failed, or if the probe found
# content served anonymously despite an ACL. The probe never aborts the rollout
# midway - leaving a fleet on mixed versions is worse than the condition it
# reports.
set -u
shopt -s nullglob

LIST=0
VERBOSE=0
DO_TPL=0
DO_REBUILD=0
DO_PROXY=0
ARGS=()
for a in "$@"; do
    case "$a" in
        --list)       LIST=1 ;;
        --verbose|-v) VERBOSE=1 ;;
        --templates)  DO_TPL=1 ;;
        --rebuild)    DO_REBUILD=1; DO_TPL=1 ;;
        --proxy)      DO_PROXY=1; DO_TPL=1 ;;
        --reapply-acls) DO_REAPPLY=1 ;;
        --reapply-acls-dry-run) DO_REAPPLY_DRY=1 ;;
        *)            ARGS+=("$a") ;;
    esac
done
STAGE="${ARGS[0]:-$(cd "$(dirname "$0")/../.." && pwd)}"

[ "$(id -u)" = 0 ] || { echo "$0: must run as root" >&2; exit 1; }
DEPLOY="$STAGE/installers/hestia/lazysite-hestia-deploy.sh"
# The release's own CLI: the health phase runs it, and every hint names it
# (SM1236). Set here, above every caller.
LZS="$STAGE/tools/lazysite-cli.pl"
[ -f "$DEPLOY" ] || { echo "$0: no deploy script under STAGE '$STAGE'" >&2; exit 2; }

HESTIA=/usr/local/hestia
# Where Hestia keeps <user>/web/<domain>/ and <user>/conf/web/<domain>/ - the
# lister's knob, so the two scripts agree on one host layout.
HOME_BASE="${LAZYSITE_HOME_BASE:-/home}"
TPLDIR="$HESTIA/data/templates/web/apache2/php-fpm"
# SM283: the nginx proxy layer. Hestia scans proxy templates here, one level
# up from the web templates above (nginx as PROXY, not as web server).
PROXYTPLDIR="$HESTIA/data/templates/web/nginx"
PROXY_TPL='lazysite-proxy'
# Hestia's per-user registry (web.conf: one TPL=/PROXY_TPL= line per domain) -
# the lister's knob again, so the scripts agree on one host layout.
USERS_DIR="${LAZYSITE_HESTIA_USERS:-$HESTIA/data/users}"

# SM324: defined HERE, above every caller.
#
# It lived near the bottom, below three call sites. Bash resolves a function at
# CALL time, so `in_list` at line 275 and 414 was `command not found` - which
# returns 127, so `in_list ... && continue` never continued.
#
# The consequence was not cosmetic and predates the probe that exposed it: the
# re-apply sweep's guards are
#
#     in_list "$d" "${SKIPPED[@]}" && continue
#     in_list "$d" "${FAILED[@]}"  && continue
#
# so --reapply-acls has been sweeping the sites it was written to skip - ones
# held back by their update channel, still on an old version where the store may
# not exist, and ones that FAILED to upgrade. The script's own comment says those
# must be excluded because sweeping them "would be meaningless at best".
#
# It stayed invisible because that block only runs with --reapply-acls. The SM317
# probe added the first UNCONDITIONAL caller, which is what surfaced it - on an
# operator's first rollout of 0.10.10.
in_list() { local x="$1"; shift; for e in "$@"; do [ "$e" = "$x" ] && return 0; done; return 1; }

# SM850: where a site's engine tree is - <docroot>-lazysite once it has been
# moved out of the document root (SM293), <docroot>/lazysite before. The rule
# Lazysite::Paths::lazysite_dir states; t/lint/37 runs this copy against it.
# Built by hand here, the table read a migrated site's version and channel from
# a directory that was no longer there and reported "?" and "(unset)".
lazysite_dir() {
    local d="$1"
    while [ "${d%/}" != "$d" ]; do d="${d%/}"; done
    if [ -d "$d-lazysite" ]; then printf '%s\n' "$d-lazysite"; else printf '%s\n' "$d/lazysite"; fi
}

# SM850: where the engine tree is, as the ENGINE column says it: inside, outside
# (migrated), BOTH - a half-finished migration, always a fault, because the
# engine reads the outside copy while the front end can still serve the inside
# one - or none.
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

# The template revision a file carries (`# lazysite-template-rev: X`), or empty.
template_rev() {
    [ -f "$1" ] || return 0
    sed -n 's/^[[:space:]]*#[[:space:]]*lazysite-template-rev:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$1" | head -1
}

# The VHOST column: is the vhost Hestia RENDERED for this domain from the
# template revision this release ships? A template change reaches a site only
# when its vhost is rebuilt, and nothing said which sites had been - SM797's
# re-render was an instruction in UPGRADE.md an operator had to apply by memory.
#   current  every lazysite-rendered file carries the staged revision
#   rebuild  one carries an older revision, or none (rendered before the marker)
#   -        no rendered vhost found where Hestia keeps them
# A rendered nginx file counts only when it is lazysite's (the lazysite-proxy
# template carries the marker; a stock proxy template does not, and the SM283
# flag is what reports that).
vhost_state() {
    local u="$1" d="$2" want="$3" dir f rev seen=0 stale=0
    dir="$HOME_BASE/$u/conf/web/$d"
    for f in "$dir/apache2.ssl.conf" "$dir/apache2.conf" "$dir/nginx.ssl.conf" "$dir/nginx.conf"; do
        [ -f "$f" ] || continue
        rev=$(template_rev "$f")
        case "$f" in
            */nginx*) [ -n "$rev" ] || continue ;;
        esac
        seen=1
        [ -n "$want" ] && [ "$rev" = "$want" ] || stale=1
    done
    if [ "$seen" = 0 ]; then echo '-'
    elif [ "$stale" = 1 ]; then echo rebuild
    else echo current
    fi
}

# SM1194: DOES THE RENDERED NGINX VHOST APPEND TO, OR PASS THROUGH, THE CLIENT'S
# X-Forwarded-For? The revision marker says a vhost is OLD; it does not say why
# that matters. Before SM929 (d93390469) lazysite-proxy.tpl/.stpl set no
# X-Forwarded-For, so nginx handed the client's own header to the engine
# unchanged; since SM929 they set `$proxy_add_x_forwarded_for`, which APPENDS the
# real peer. The engine reads the chain from the right, so an appended header is
# safe and a passed-through one is whatever the visitor typed (test plan 0.15.10,
# F-6: "a request sent with X-Forwarded-For: 192.0.2.55 is seen as 192.0.2.55").
#   appends  every lazysite-rendered nginx file sets it from the peer
#   passes   one has no (uncommented) X-Forwarded-For line, or sets it to the
#            client's own header
#   -        no lazysite-rendered nginx file (Apache appends it itself)
# A file counts only when it carries the lazysite marker, as in vhost_state.
vhost_xff_state() {
    local u="$1" d="$2" dir f line seen=0 bad=0 ok
    dir="$HOME_BASE/$u/conf/web/$d"
    for f in "$dir/nginx.ssl.conf" "$dir/nginx.conf"; do
        [ -f "$f" ] || continue
        [ -n "$(template_rev "$f")" ] || continue
        seen=1; ok=0
        while IFS= read -r line; do
            case "$line" in
                *'$http_x_forwarded_for'*) ok=0; break ;;
                *'$proxy_add_x_forwarded_for'*|*'$remote_addr'*) ok=1 ;;
            esac
        done < <(grep -E '^[[:space:]]*proxy_set_header[[:space:]]+X-Forwarded-For[[:space:]]' "$f")
        [ "$ok" = 1 ] || bad=1
    done
    if [ "$seen" = 0 ]; then echo '-'
    elif [ "$bad" = 1 ]; then echo passes
    else echo appends
    fi
}

# How does the site's lazysite.conf trust a front end's X-Forwarded-For?
# none | default (absent or empty: the private ranges) | list. Argument: the
# site's docroot.
site_trust_kind() {
    local conf v
    conf="$(lazysite_dir "$1")/lazysite.conf"
    [ -f "$conf" ] || { echo default; return 0; }
    v=$(sed -n 's/^trusted_proxies[[:space:]]*:[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$/\1/p' "$conf" | tail -1)
    if [ -z "$v" ]; then echo default
    elif [ "$v" = none ]; then echo none
    else echo list
    fi
}

# The words of the failure, without the site (the findings report groups by
# message and lists the sites itself). Argument: the trust kind.
xff_reason() {
    local why
    case "$1" in
        default) why='trusted_proxies is not set, so the private ranges are trusted by default' ;;
        *)       why='trusted_proxies is set to a list' ;;
    esac
    printf '%s\n' "the front end passes the client's X-Forwarded-For through, so trusted_proxies lets any visitor choose their address ($why); fix: rebuild the vhost (--rebuild, or v-rebuild-web-domain USER DOMAIN and then $(cli_cmd) repair --domain DOMAIN, which puts back the permissions a rebuild resets), then probe: a request with X-Forwarded-For: 192.0.2.55 must not be seen as 192.0.2.55; until then set trusted_proxies: none (do not remove the line - removing it restores the default trust)"
}

# xff_exposure USER DOMAIN DOCROOT - prints the FAILURE line when this site
# trusts forwarded addresses behind a front end that passes them through, and
# nothing otherwise. Only `none` trusts nothing; absent and empty mean the
# private ranges (Lazysite::Util parse_trusted_proxies), which include the
# address of an ordinary front end - edge's 10.2.30.177 is in 10/8.
xff_exposure() {
    local kind
    [ "$(vhost_xff_state "$1" "$2")" = passes ] || return 0
    kind=$(site_trust_kind "$3")
    [ "$kind" != none ] || return 0
    printf 'FAILURE: %s: %s\n' "$2" "$(xff_reason "$kind")"
}

# SM1196: HESTIA'S INSTALLED COPY OF A TEMPLATE FOLLOWS THE RELEASE.
#
# Edge, 2026-10-19 (F-6 re-test): after v-rebuild-web-domain the vhost still
# passed the client's X-Forwarded-For through, and `grep -n X-Forwarded-For
# /usr/local/hestia/data/templates/web/nginx/lazysite-proxy.*tpl` found nothing.
# Hestia renders a vhost from ITS copy of the template, and that copy was put
# there once, by hand (cp, README.Debian step 3), before SM929 (0.15.2) - so
# every rebuild re-rendered the old one and nothing said so. This script knew a
# vhost was old (the VHOST column) but could not help: a rebuild reads the very
# template that is old.
#
# The copy is now compared on EVERY run, with or without --templates, and an
# installed lazysite template that differs from the release's is replaced. The
# release's copy is $STAGE/installers/hestia (the unpacked tarball) or, on a
# host with only the debs, /usr/share/lazysite-hestia/templates.
#   TPL_SRC       the release's copy (set from the above, or by a test)
#   TPL_NEW       1 = also install a template Hestia does not have yet
#                 (--templates / --proxy / --rebuild, as before); 0 = refresh
#                 only what is installed, so a host that never copied the
#                 cgi/fcgi templates is not given them by a rollout
#   TPL_STAMP     the timestamp the backups carry
#   TPL_FAILURES  refreshes that did not take; the exit status reads it
#   TPL_CHANGED   the template names that were replaced
# The backup is NAME.EXT.bak-STAMP beside the original: Hestia lists a template
# by its .tpl/.stpl name, so a backup with another ending is not offered as one.
refresh_template() {
    local dir="$1" name="$2" ext s t bak tmp mode
    shift 2
    for ext in "$@"; do
        s="$TPL_SRC/$name.$ext"; t="$dir/$name.$ext"
        [ -f "$s" ] || continue
        if [ ! -f "$t" ]; then
            [ "${TPL_NEW:-0}" = 1 ] || continue
        elif cmp -s "$s" "$t"; then
            continue
        fi
        tmp="$t.tmp-$$"
        mode=644; [ "$ext" = sh ] && mode=755
        bak=''
        if [ -f "$t" ]; then
            bak="$t.bak-$TPL_STAMP"
            if ! cp -p "$t" "$bak" 2>/dev/null; then
                printf 'FAILURE: could not back up %s to %s - the template was NOT refreshed; copy %s over it by hand, then rebuild the domains on it\n' "$t" "$bak" "$s"
                TPL_FAILURES=$(( TPL_FAILURES + 1 )); continue
            fi
        fi
        if cp "$s" "$tmp" 2>/dev/null && chmod "$mode" "$tmp" 2>/dev/null && mv -f "$tmp" "$t" 2>/dev/null; then
            if [ -n "$bak" ]; then
                printf '    refreshed: %s (differed from the release; old copy kept as %s)\n' "$t" "$bak"
            else
                printf '    installed: %s\n' "$t"
            fi
            in_list "$name" "${TPL_CHANGED[@]:-}" || TPL_CHANGED+=( "$name" )
        else
            rm -f "$tmp" 2>/dev/null
            [ -z "$bak" ] || rm -f "$bak" 2>/dev/null
            printf 'FAILURE: could not write %s - the template was NOT refreshed, so a rebuild renders the old one; copy %s over it by hand, then rebuild the domains on it\n' "$t" "$s"
            TPL_FAILURES=$(( TPL_FAILURES + 1 ))
        fi
    done
}

# domain_uses_template USER DOMAIN NAME - succeeds when Hestia's registry has
# the domain on web template NAME or on proxy template NAME.
domain_uses_template() {
    local line
    [ -f "$USERS_DIR/$1/web.conf" ] || return 1
    while IFS= read -r line; do
        case "$line" in
            *"DOMAIN='$2'"*"TPL='$3'"*) return 0 ;;
        esac
    done < "$USERS_DIR/$1/web.conf"
    return 1
}

# domains_on_template NAME - every "user/domain" on this host that Hestia
# records as using template NAME (web or proxy), whatever its channel: a
# refreshed template reaches all of them at their next rebuild.
domains_on_template() {
    local wc u line d
    for wc in "$USERS_DIR"/*/web.conf; do
        u="${wc%/web.conf}"; u="${u##*/}"
        while IFS= read -r line; do
            case "$line" in *"TPL='$1'"*) ;; *) continue ;; esac
            d="${line#*DOMAIN=\'}"; d="${d%%\'*}"
            [ -n "$d" ] && printf '%s/%s\n' "$u" "$d"
        done < "$wc"
    done
    return 0
}

# The CHECK column: `lazysite check` for one site, after the rollout's repair -
# read-only - as clean, or its warning and failure counts. The lines behind the
# counts are the check's own report, one command away.
check_verdict() {
    local out ok w f
    out=$( perl "$LZS" check --domain "$1" 2>&1 ) || true
    read -r ok w f < <( printf '%s\n' "$out" \
        | sed -n 's/^\([0-9]*\) ok, \([0-9]*\) warning(s), \([0-9]*\) failure(s).*/\1 \2 \3/p' | tail -1 )
    if [ -z "${ok:-}" ]; then echo '?'
    elif [ "$f" = 0 ] && [ "$w" = 0 ]; then echo clean
    elif [ "$f" = 0 ]; then echo "$w warn"
    else echo "$f FAIL, $w warn"
    fi
}

# --- reporting -------------------------------------------------------------
#
# Defined here for the SM324 reason the block above records: bash resolves a
# function at CALL time, so one defined below its caller is `command not found`
# and returns 127 - which, in a guard written `f ... && continue`, silently
# means "did not match".
#
# THE REPORT IS QUIET BY DEFAULT. A rollout used to stream every phase of every
# site: the discovery list, then the same domains again with their channel,
# again in an out-of-scope block, then a banner and the full install transcript
# per site, then repair and probe per site. On a fleet of any size the two lines
# an operator needs are somewhere in several thousand. So: one table of what was
# found, only warnings and failures while it runs, and a summary table at the
# end. --verbose restores the transcript.

# ENGINE and VHOST (N13-41, N13-43): where each site's engine tree is, and
# whether its rendered vhost carries this release's template. CHECK (N13-42):
# what `lazysite check` says of each site after the rollout. All three used to
# be steps an operator had to remember to run; the table answers them.
TBL_FMT='  %-42s %-12s %-9s %-9s %-8s %-8s %s\n'

table_head() { printf "$TBL_FMT" DOMAIN USER VERSION CHANNEL ENGINE VHOST SCOPE; }
table_row()  { printf "$TBL_FMT" "$1" "$2" "$3" "$4" "$5" "$6" "$7"; }

SUM_FMT='  %-42s %-9s %-9s %-16s %-8s %s\n'
sum_head() { printf "$SUM_FMT" DOMAIN FROM TO CHECK VHOST RESULT; }
sum_row()  { printf "$SUM_FMT" "$1" "$2" "$3" "$4" "$5" "$6"; }

# SM1236: THE COMMAND THAT RUNS ON THIS HOST. Every hint said `lazysite ...`, and
# the tarball - the Hestia deploy shape - puts no `lazysite` on PATH (the .deb
# does). So a hint names `lazysite` when it is there and the release's own CLI by
# path otherwise, which runs from any directory. The child tools are told the
# same spelling through LAZYSITE_CLI, so their hints agree with this script's.
cli_cmd() {
    if command -v lazysite >/dev/null 2>&1; then
        echo lazysite
    else
        printf 'perl %s\n' "${LZS:-tools/lazysite-cli.pl}"
    fi
}

# SM1236: A REBUILD IS FOLLOWED BY A REPAIR. v-rebuild-web-domain re-applies
# Hestia's own permissions (docroot 2751, lazysite/git 2775 - SM270, seen again
# by hand on three sites after the 0.16.0 rollout), so a hint that sends an
# operator to it names the repair that puts them back. Argument: the lead-in.
rebuild_hint() {
    printf '%s: v-rebuild-web-domain USER DOMAIN, then %s repair --domain DOMAIN (a rebuild resets the docroot permissions, SM270)\n' "$1" "$(cli_cmd)"
}


# SM889: WHAT COUNTS AS A FINDING - and the old answer matched prose.
#
# This was deliberately broad on the argument that "a false positive costs one
# line". It does not. Measured on the 0.14.2 fleet update: about 200 lines to
# say 29 updated, 0 failed, and the two largest sources were bare words.
#
#   `missing` matched 71 per-file "backup: missing <path>" lines - one per
#   deleted demo page per site.
#
#   `missing` ALSO matched, once per site, this line from the installer's
#   fifteen-line Next steps block:
#
#       deliberate, not a missing step, and there is no default login:
#
#   which is a sentence saying nothing is wrong. grep printed that one line out
#   of the block, so it arrived ending in a colon with its continuation gone
#   and read as a truncated message. It was filed as a second defect; it is
#   this one.
#
# So the pattern now wants a finding to LOOK like a finding: a level marker, or
# a word at the start of its own clause - not any sentence containing "cannot"
# or "missing" somewhere in the middle.
#
# Still deliberately generous about real findings: a missed warning is the
# failure mode this filtering risks, and the grouping below means a genuine
# repeat now costs one line rather than twenty-nine.
# The case of the level markers is load-bearing: matching `warn`
# case-insensitively would match "warning" inside any sentence, which is how
# the old pattern caught prose. `Permission denied` is capitalised because that
# is what strerror produces, and lowercasing it cost a real match in testing.
NOISE_RE='(\[ *(warn|fail|error) *\]|^[[:space:]]*(WARN|WARNING|ERROR|FAIL|FAILED|CRITICAL|EXPOSED)\b|\b(WARN|ERROR|FAIL|FAILED|CRITICAL|EXPOSED):|not writable|[Pp]ermission denied|refused|refusing)'

# Findings are collected and reported TOGETHER at the end, grouped by what they
# say, rather than printed as they occur.
#
# The 0.14.2 run printed the same ~45-word probe warning 21 times and the same
# ~90-word ACL paragraph 8 times. Those are not 29 findings; they are two
# conditions with a set of sites each. Repeating identical prose per site also
# asserts a per-site result the report does not have - and it BURIES the cases
# that genuinely differ, which in that run was the extension list inside the
# probe warning, varying between sites and invisible inside twenty-one copies.
FINDINGS_FILE=$(mktemp -t lzs-findings.XXXXXX) || FINDINGS_FILE=''
cleanup_findings() { [ -n "$FINDINGS_FILE" ] && rm -f "$FINDINGS_FILE"; }
trap cleanup_findings EXIT

# group_findings - stdin is label<TAB>message lines; stdout is one record per
# distinct message: "[N] message" then "sites: a, b, c", N being the number of
# DISTINCT SITES. A function of its own so t/tools/80 can run exactly what
# ships rather than a copy of it.
#
# SM889's residue, seen on the 0.14.3 rollout - the first run of the grouped
# report against a real fleet - and every one of the three is a defect in the
# grouping rather than in the volume:
#
#   [123] for a warning that occurs at most once per site, on 29 sites.
#   The label carries the PHASE - "repair D", "probe D" - and repair checks a
#   site before and after, so one condition on one site arrived as four
#   labelled lines and was counted four times. The site is the LAST WORD of the
#   label, and a site is counted once per message whatever the phase.
#
#   sites: ... probe cloudient.net, repair cloudient.net, repair cloudient.net
#   The same leak, printed. The phase is stripped before grouping.
#
#   Every "sites:" line printed in a block AFTER every "[N]" line. The old awk
#   printed two lines per record and the pipeline then sorted ALL of them, so
#   the message lines and the site lines were sorted apart and no list could
#   be paired with its finding - which is the one thing the list is for. Records
#   are ordered on input (by message, then site) and printed in that order, and
#   nothing sorts the output.
#
# SM1235: A MESSAGE THAT DIFFERS ONLY BY A PATH IS ONE FINDING. The 0.16.0
# rollout gave sumaya.fund about seventy lines of "WARNING: both trees held
# 'docs/X.md': ... moved to <dir>/docs/X.md, where it can be recovered", one per
# file, and the report could no longer be copied. Each message is normalised
# before grouping: an absolute path, and a quoted name with a slash or an
# extension, become <path>. A group of more than one distinct message prints
# once: the count, the directories its paths are under per site (for that line,
# the displaced directory), three examples, and the file holding the full list
# ($FINDINGS_FULL, written only when a group needs it). A leading log timestamp
# is dropped for the same reason. A message with no path, or one copy of it,
# prints exactly as before.
group_findings() {
    local prog
    prog=$(cat <<'PERL'
    use strict;
    use warnings;
    my $full = shift // '';
    my ( %seen, %group, %msgs, %sites );
    while ( my $line = <STDIN> ) {
        chomp $line;
        my ( $label, $msg ) = split /\t/, $line, 2;
        next unless defined $msg && length $msg;
        # "phase site" -> "site": the site is the LAST word of the label.
        my $site = ( split / /, $label )[-1] // $label;
        $msg =~ s/\A\[\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\] //;
        next if $seen{"$site\t$msg"}++;
        my @v;
        ( my $key = $msg ) =~ s{(^|[\s"(=\[])(/[^\s'",;()\[\]]*[^\s'",;()\[\].:])|'([^'\s]*/[^'\s]*|[^'\s/]+\.[A-Za-z0-9]{1,8})'}{
            defined $2 ? do { push @v, $2; "$1<path>" } : do { push @v, $3; "'<path>'" } }ge;
        push @{ $group{$key} }, [ $site, $msg, \@v ];
        $msgs{$key}{$msg} = 1;
        $sites{$key}{$site} = 1;
    }
    # The longest common directory of a set of paths ("" when none).
    my $under = sub {
        my @p = @_;
        return $p[0] if !grep { $_ ne $p[0] } @p;
        my $c = $p[0];
        for my $x (@p) { chop $c while length $c && index( $x, $c ) != 0 }
        $c =~ s{[^/]*\z}{};
        return $c;
    };
    for my $key ( sort keys %group ) {
        my @rows  = sort { $a->[0] cmp $b->[0] || $a->[1] cmp $b->[1] } @{ $group{$key} };
        my @names = sort keys %{ $sites{$key} };
        my $n     = scalar @names;
        my @m     = keys %{ $msgs{$key} };
        if ( @m == 1 ) {
            printf "  [%d] %s\n      sites: %s\n", $n, $m[0], join( ', ', @names );
            next;
        }
        printf "  [%d] %s\n", $n, $key;
        printf "      %d instance(s); the paths named are under:\n", scalar @rows;
        for my $s (@names) {
            my @mine = grep { $_->[0] eq $s } @rows;
            my $slots = @{ $mine[0][2] };
            my @u;
            for my $i ( 0 .. $slots - 1 ) {
                my $d = $under->( map { $_->[2][$i] // '' } @mine );
                push @u, length $d ? $d : '(various)';
            }
            printf "        %s: %s\n", $s, join( ' | ', @u );
        }
        my ( %ex, @ex );
        for my $r (@rows) {
            my $e = $r->[2][0];
            next if !defined $e || $ex{$e}++;
            push @ex, $e;
            last if @ex == 3;
        }
        printf "      e.g. %s\n", join( ', ', @ex ) if @ex;
        if ( length $full && open my $fh, '>>', $full ) {
            print {$fh} "== $key\n";
            print {$fh} "$_->[0]\t$_->[1]\n" for @rows;
            close $fh;
            printf "      full list: %s\n", $full;
        }
        printf "      sites: %s\n", join( ', ', @names );
    }
PERL
)
    perl -e "$prog" "${FINDINGS_FULL:-}"
}

# report_findings - print every collected finding once, with the sites it
# affects. Silent when there is nothing, because a heading over an empty list
# is the kind of line this change exists to remove.
report_findings() {
    [ -n "$FINDINGS_FILE" ] && [ -s "$FINDINGS_FILE" ] || return 0
    # SM1235: where a finding that collapsed many paths keeps the full list. It
    # outlives the run (the findings file does not), and the finding names it.
    FINDINGS_FULL="${FINDINGS_FULL:-${LAZYSITE_FINDINGS_DIR:-${TMPDIR:-/tmp}}/lazysite-rollout-findings-$(date +%Y%m%d%H%M%S)-$$.txt}"
    echo
    echo '==> findings (one line per distinct message, with the sites it affects)'
    group_findings < "$FINDINGS_FILE"
}

# SM1194: record_xff_exposure USER DOMAIN DOCROOT - add the exposure, if any, to
# the findings (label = the site, message = the reason) and succeed when it was
# one, so the caller can count it and fail the rollout's exit status.
record_xff_exposure() {
    local out
    out=$(xff_exposure "$1" "$2" "$3")
    [ -n "$out" ] || return 1
    if [ -n "$FINDINGS_FILE" ]; then
        printf '%s\t%s\n' "$2" "FAILURE: ${out#FAILURE: $2: }" >> "$FINDINGS_FILE"
    else
        printf '%s\n' "$out"
    fi
    return 0
}

# The summary line for N exposed sites; silent for none.
xff_summary_line() {
    [ "${1:-0}" -gt 0 ] || return 0
    printf '  vhost:  %d site(s) FAILURE: a front end that passes the client'"'"'s X-Forwarded-For through trusts it by default (trusted_proxies is not "none") - any visitor can choose their address (see findings)\n' "$1"
}

# collect_findings LABEL OUTPUT - keep the lines of OUTPUT that look like a
# finding (NOISE_RE), for the report at the end.
#
# SM889: COLLECTED, not printed. Each finding is stored as label<TAB>message and
# reported once at the end with the sites it affects - see report_findings.
# Leading and trailing space is trimmed so the same message indented differently
# by two phases still groups. (SM1237: a function of its own, so the probe phase,
# which reads its output as well as filtering it, collects the same way.)
collect_findings() {
    local label="$1" out="$2" line
    if [ -n "$FINDINGS_FILE" ]; then
        printf '%s\n' "$out" | grep -E "$NOISE_RE" \
            | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
            | while IFS= read -r line; do
                [ -n "$line" ] && printf '%s\t%s\n' "$label" "$line" >> "$FINDINGS_FILE"
            done || true
    else
        printf '%s\n' "$out" | grep -E "$NOISE_RE" | sed "s/^/  [$label] /" || true
    fi
}

# run_quiet LABEL COMMAND...
#
# Runs the command with its output captured. On success, prints only the lines
# that look like a warning or a failure, each tagged with the site it came from
# so a filtered line is still attributable. On FAILURE, prints everything it
# captured - the detail of a failure is the one thing never worth suppressing,
# and a summary that says "failed" without saying why just moves the operator's
# work to a second run.
#
# Returns the command's own exit status, unchanged: every caller here branches
# on it, and this function must be invisible to that logic.
run_quiet() {
    local label="$1"; shift
    local out rc had_e
    if [ "$VERBOSE" = 1 ]; then
        "$@"
        return $?
    fi
    # SAVE AND RESTORE the caller's errexit rather than forcing it on. An
    # earlier draft ended with a bare `set -e`, which turned errexit ON even
    # when the caller had deliberately turned it off to inspect a status - so
    # `return $rc` with a non-zero rc killed the script at the call site, which
    # is the exact failure this function was added to stop happening in the
    # deploy loop. Caught by exercising it rather than reading it.
    case $- in *e*) had_e=1 ;; *) had_e=0 ;; esac
    set +e
    out=$( "$@" 2>&1 )
    rc=$?
    [ "$had_e" = 1 ] && set -e
    if [ "$rc" != 0 ]; then
        printf '\n--- %s: FAILED (status %s), full output ---\n' "$label" "$rc"
        printf '%s\n' "$out"
        printf -- '--- end %s ---\n' "$label"
    else
        collect_findings "$label" "$out"
    fi
    return "$rc"
}

# SM1237: probe_site DOMAIN - run `lazysite probe` for one site and say what it
# found: PROBE_VERDICT is ok, exposed or none, and for none the REASON is a
# finding of its own ("probe could not run: <why>"), grouped with the others.
#
# The 0.16.0 rollout said "probe: 16 clean, 0 exposed, 16 could not run" and
# never why. The probe knew - its output said ACL PROBE SKIPPED and the cause -
# but the summary read only the exit status, and in the quiet report a probe
# that exited 3 was dumped whole as FAILED, sixteen transcripts deep. Now the
# reason the probe gives (`<site>: NOT CONFIRMED: <reason>`) is what the report
# carries, and a probe that could not run is filtered like a success: its
# reason is the finding.
#
# The other non-pass is a probe COMMAND that did not finish - the CLI refused
# (exit 1 with no exposure, e.g. a site it cannot address) or died. That was
# counted as EXPOSED. It is counted as could-not-run, with its last line as the
# reason and its whole output printed, and it still marks the fleet for a human
# (PROBE_TOOL_FAILED), as the exposure count used to.
probe_site() {
    local d="$1" out rc had_e why last failed=0
    case $- in *e*) had_e=1 ;; *) had_e=0 ;; esac
    set +e
    out=$( perl "$LZS" probe --domain "$d" 2>&1 )
    rc=$?
    [ "$had_e" = 1 ] && set -e
    [ "$VERBOSE" = 1 ] && printf '%s\n' "$out"
    PROBE_VERDICT=none
    if [ "$rc" = 0 ]; then
        PROBE_VERDICT=ok
    elif [ "$rc" = 1 ] && printf '%s\n' "$out" | grep -q 'SERVED ANONYMOUSLY'; then
        PROBE_VERDICT=exposed
    fi
    why=''
    if [ "$PROBE_VERDICT" = none ]; then
        why=$(printf '%s\n' "$out" | sed -n 's/^  [^ ]*: NOT CONFIRMED: //p' | head -1)
        if [ "$rc" != 3 ] || [ -z "$why" ]; then
            last=$(printf '%s\n' "$out" | sed -e '/^[[:space:]]*$/d' -e 's/^[[:space:]]*//' | tail -1)
            why="the probe command did not finish (status $rc)${last:+: $last}"
            PROBE_TOOL_FAILED=1
            failed=1
        fi
    fi
    if [ "$VERBOSE" != 1 ]; then
        if [ "$PROBE_VERDICT" = exposed ] || [ "$failed" = 1 ]; then
            printf '\n--- probe %s: status %s, full output ---\n%s\n--- end probe %s ---\n' "$d" "$rc" "$out" "$d"
        else
            collect_findings "probe $d" "$out"
        fi
    fi
    if [ -n "$why" ]; then
        if [ -n "$FINDINGS_FILE" ]; then
            printf '%s\t%s\n' "$d" "probe could not run: $why" >> "$FINDINGS_FILE"
        else
            printf '  [probe %s] probe could not run: %s\n' "$d" "$why"
        fi
    fi
    return 0
}


# SM1238: acl_dry_run_site DOMAIN USER DOCROOT - the SM296 dry run for one site,
# as its own user. DRY_VERDICT is found (a NOT MOVED line), settled (none) or
# failed (the tool exited non-zero; its output is printed whole). Each
# "NOT MOVED: <path>" becomes a finding labelled with the site - which SM1235
# groups, so a site with forty of them is one finding with examples.
acl_dry_run_site() {
    local d="$1" u="$2" dr="$3" out rc had_e line n=0
    case $- in *e*) had_e=1 ;; *) had_e=0 ;; esac
    set +e
    out=$( sudo -u "$u" perl "$ACLTOOL" reapply --docroot "$dr" --actor local 2>&1 )
    rc=$?
    [ "$had_e" = 1 ] && set -e
    [ "$VERBOSE" = 1 ] && printf '%s\n' "$out"
    if [ "$rc" != 0 ]; then
        DRY_VERDICT=failed
        [ "$VERBOSE" = 1 ] || printf '\n--- acl dry run %s: FAILED (status %s), full output ---\n%s\n--- end acl dry run %s ---\n' "$d" "$rc" "$out" "$d"
        return 0
    fi
    while IFS= read -r line; do
        case "$line" in
            'NOT MOVED: '*)
                n=$(( n + 1 ))
                if [ -n "$FINDINGS_FILE" ]; then
                    printf '%s\t%s\n' "$d" "$line - its access rule is stored and its files are still in the document root (the SM296 state); --reapply-acls moves them" >> "$FINDINGS_FILE"
                else
                    printf '  [acl %s] %s\n' "$d" "$line"
                fi
                ;;
        esac
    done <<< "$out"
    if [ "$n" -gt 0 ]; then DRY_VERDICT=found; else DRY_VERDICT=settled; fi
    return 0
}


ver_of() {   # print the "version" from an install-state.json, or "?"
    # (perl -ne exits 0 on a missing file, so test first rather than ||)
    [ -f "$1" ] || { echo '?'; return; }
    perl -MJSON::PP -0777 -ne 'my $d=eval{decode_json($_)}; print(($d && $d->{version}) ? $d->{version} : "?")' "$1" 2>/dev/null || echo '?'
}

# SM1236: the child tools spell their hints the way this script does.
LAZYSITE_CLI="${LAZYSITE_CLI:-$(cli_cmd)}"
export LAZYSITE_CLI

# --- discover lazysite sites -------------------------------------------------
# Preferred: lazysite-hestia-list.sh --template-only - the Hestia web template
# (lazysite-app) is the sole authority for what we update. A marker-only domain
# (marker present, template changed away) is deliberately excluded here and
# reported below, so we never re-deploy over a domain the operator has moved off
# lazysite. Fallback (older STAGE without the lister): the original marker glob,
# which cannot see the template and so updates every marked tree.
USERS=(); DOMAINS=(); DOCS=(); VERS=(); EXCLUDED=()
EXC_D=(); EXC_U=(); EXC_DOC=(); EXC_V=()
LISTER="$STAGE/installers/hestia/lazysite-hestia-list.sh"
# The lister ships in the same release as this script, so it is always here.
# (There was a fallback that globbed /home for install markers; it could only
# run against a release that did not exist, and it could not see a site whose
# engine tree had moved - SM850.)
[ -f "$LISTER" ] || { echo "$0: no lister under STAGE '$STAGE'" >&2; exit 2; }
# SM850: each site's DOCROOT is the lister's, carried through every phase below
# rather than rebuilt from a /home pattern, and its engine tree is asked of
# lazysite_dir.
while IFS=$'\t' read -r u d doc; do
    [ -n "$d" ] || continue
    USERS+=( "$u" ); DOMAINS+=( "$d" ); DOCS+=( "$doc" )
    VERS+=( "$(ver_of "$(lazysite_dir "$doc")/.install-state.json")" )
done < <(bash "$LISTER" --plain --template-only)
# Marker-only domains = the union minus the template set: excluded from the
# update, but surfaced so the operator can reconcile template vs marker.
declare -A _IN_TPL=()
for i in "${!DOMAINS[@]}"; do _IN_TPL["${USERS[$i]}/${DOMAINS[$i]}"]=1; done
while IFS=$'\t' read -r u d doc; do
    [ -n "$d" ] || continue
    if [ "${_IN_TPL[$u/$d]:-0}" != 1 ]; then
        EXCLUDED+=( "$d (user $u)" )
        EXC_D+=( "$d" ); EXC_U+=( "$u" ); EXC_DOC+=( "$doc" )
        EXC_V+=( "$(ver_of "$(lazysite_dir "$doc")/.install-state.json")" )
    fi
done < <(bash "$LISTER" --plain)

n=${#DOMAINS[@]}
NEWVER="$(ver_of "$STAGE/release-manifest.json")"
[ "$NEWVER" = '?' ] && NEWVER="$( [ -f "$STAGE/VERSION" ] && cat "$STAGE/VERSION" || echo unknown )"

# The table is rendered ONCE, below, after the channel check has run - so a
# candidate appears on exactly one line carrying everything known about it,
# rather than in a discovery list, again with its channel, and again in an
# out-of-scope block. --list still exits before anything is changed; it now
# reaches the table first, because --channel-check reads lazysite.conf and the
# manifest and writes nothing, which is what makes it safe to run for a report.
if [ "$n" = 0 ] && [ "${#EXCLUDED[@]}" = 0 ]; then
    echo "No lazysite site found on this host."
    exit 0
fi

# --- SCOPE: which sites is this release actually FOR? (SM345) -------------
#
# A release is for the sites whose update_channel accepts it. Everything below
# this point - proxy assignment, vhost rebuild, deploy, repair, probe - must act
# ONLY on those. Until now the per-site deploy was channel-gated and every OTHER
# phase was not, so an edge rollout rebuilt vhosts, ran repairs and probed sites
# sitting on stable.
#
# That is not merely noisy. `repair` WRITES: an edge rollout repaired a stable
# site, which is a change made to a site running older code by a release that
# was never meant to reach it - a partial update, and exactly what a channel
# ladder exists to prevent. It also produced the fleet's out-of-scope exposures
# as findings against a rollout that could not address them ([[SM344]]).
#
# The channel decision is NOT re-implemented here. `install.sh --channel-check`
# already answers it, reads only lazysite.conf and the manifest, changes
# nothing, and is the same code the per-site deploy obeys. A second copy in bash
# would be one fact in two places, which is the defect this project keeps
# closing.
IN_USERS=(); IN_DOMAINS=(); IN_DOCS=(); IN_VERS=(); OUT_OF_SCOPE=()
CHANS=(); SCOPES=(); ENGINES=(); VHOSTS=()
STAGED_REV="$(template_rev "$STAGE/installers/hestia/lazysite-app.stpl")"
for i in "${!DOMAINS[@]}"; do
    _d="${DOMAINS[$i]}"; _u="${USERS[$i]}"
    _dr="${DOCS[$i]}"
    ENGINES+=( "$(engine_state "$_dr")" )
    VHOSTS+=( "$(vhost_state "$_u" "$_d" "$STAGED_REV")" )
    if [ ! -d "$_dr" ]; then
        # No docroot: leave it to the deploy loop to report properly rather than
        # silently dropping it here. Its row still gets a channel and a scope -
        # skipping them left every later row reading the previous site's.
        IN_USERS+=( "$_u" ); IN_DOMAINS+=( "$_d" ); IN_DOCS+=( "$_dr" ); IN_VERS+=( "${VERS[$i]}" )
        CHANS+=( '?' ); SCOPES+=( 'in scope (no docroot)' )
        continue
    fi
    set +e
    perl "$STAGE/install.pl" --channel-check --docroot "$_dr" >/dev/null 2>&1
    _cc=$?
    set -e
    if [ "$_cc" = 3 ]; then
        OUT_OF_SCOPE+=( "$_d" )
    else
        IN_USERS+=( "$_u" ); IN_DOMAINS+=( "$_d" ); IN_DOCS+=( "$_dr" ); IN_VERS+=( "${VERS[$i]}" )
    fi
    # SM356: say which channel each site is actually on. The fleet's policy was
    # only ever inferable from which sites got skipped, so a site sitting on a
    # channel nobody intended looked exactly like a site behaving correctly -
    # and an unrecognised update_channel value used to resolve, silently, to the
    # MOST permissive setting. --channel-check reports that on stderr now; this
    # makes the normal case legible too.
    _ch=$(sed -n 's/^[[:space:]]*update_channel[[:space:]]*:[[:space:]]*\([^[:space:]]*\).*/\1/p' \
            "$(lazysite_dir "$_dr")/lazysite.conf" 2>/dev/null | head -1)
    CHANS+=( "${_ch:-(unset)}" )
    SCOPES+=( "$( [ "$_cc" = 3 ] && echo 'out of scope' || echo 'in scope' )" )
done

# --- ONE TABLE: every candidate, what it runs, what it is set to, and whether
# this release is for it. Everything an operator needs to answer "what is about
# to happen, and to what" without reading further.
echo
printf '==> lazysite fleet update to %s\n' "$NEWVER"
echo
table_head
for i in "${!DOMAINS[@]}"; do
    table_row "${DOMAINS[$i]}" "${USERS[$i]}" "${VERS[$i]}" \
              "${CHANS[$i]:-?}" "${ENGINES[$i]:-?}" "${VHOSTS[$i]:-?}" "${SCOPES[$i]:-?}"
done
for i in "${!EXC_D[@]}"; do
    # Marker present, template moved away. Never silently deployed to: the
    # operator reconciles template against marker, and until they do this
    # domain is reported and left alone.
    table_row "${EXC_D[$i]}" "${EXC_U[$i]}" "${EXC_V[$i]}" '-' \
              "$(engine_state "${EXC_DOC[$i]}")" '-' 'excluded (not on lazysite-app)'
done
echo
printf '  %d candidate(s): %d in scope, %d out of scope, %d excluded\n' \
    "$(( n + ${#EXC_D[@]} ))" "${#IN_DOMAINS[@]}" "${#OUT_OF_SCOPE[@]}" "${#EXC_D[@]}"
[ "${#OUT_OF_SCOPE[@]}" -gt 0 ] && \
    echo '  Out of scope: update_channel does not accept this build - no template change, no rebuild, no repair, no probe.'
[ "${#EXC_D[@]}" -gt 0 ] && \
    echo "  Excluded: re-set the template or remove the stale marker to reconcile (bash $LISTER)."
[ "$LIST" = 1 ] && exit 0

# From here on, these are THE sites.
DOMAINS=( "${IN_DOMAINS[@]}" )
USERS=(   "${IN_USERS[@]}" )
# The docroots and FROM versions travel with the domains. The summary used to
# index the whole candidate list's versions by an in-scope position, so an
# out-of-scope site earlier in the list shifted every FROM that followed it.
DOCS=(    "${IN_DOCS[@]}" )
VERS=(    "${IN_VERS[@]}" )
n=${#DOMAINS[@]}
if [ "$n" = 0 ]; then
    echo
    echo "==> no site on this host accepts this release. Nothing to do."
    exit 0
fi
echo
printf '==> IN SCOPE: %d site(s)\n' "$n"

# --- refresh Hestia's copies of the lazysite templates (SM1196) -------------
# Before ANY rebuild: a rebuild reads Hestia's copy, so the copy has to be the
# release's first. Order: refresh, then rebuild (below), then the rendered-file
# X-Forwarded-For check in the summary (SM1194).
if [ -f "$STAGE/installers/hestia/$PROXY_TPL.tpl" ]; then
    TPL_SRC="$STAGE/installers/hestia"
else
    TPL_SRC="${LAZYSITE_TEMPLATE_SRC:-/usr/share/lazysite-hestia/templates}"
fi
TPL_STAMP=$(date +%Y%m%d%H%M%S)
TPL_FAILURES=0
TPL_CHANGED=()
TPL_NEW=$DO_TPL
echo
echo "==> comparing Hestia's lazysite templates with the release's ($TPL_SRC)"
if [ -d "$TPLDIR" ]; then
    # SM345: this one CANNOT be scoped, and that is worth saying out loud rather
    # than leaving to be discovered. The web template is a SHARED file in
    # Hestia's template directory; every domain assigned to it renders from
    # whatever version is there, at whatever moment its vhost is next rebuilt.
    #
    # So refreshing it during an edge rollout stages a newer template for sites
    # sitting on stable - they do not render it today, and they will the next
    # time anything rebuilds their vhost, which may be an unrelated Hestia
    # operation weeks later. That is the "partial update on an older version"
    # hazard, arriving late and detached from the release that caused it.
    if [ "${#OUT_OF_SCOPE[@]}" -gt 0 ]; then
        echo "    NOTE: these templates are SHARED and cannot be scoped to a channel."
        printf '    %d out-of-scope site(s) also use them and will render the new\n' \
            "${#OUT_OF_SCOPE[@]}"
        echo "    version the next time their vhost is rebuilt, by anything."
        echo "    Refresh the templates on the channel you are promoting TO."
    fi
    refresh_template "$TPLDIR" lazysite-app tpl stpl sh
    # The Apache cgi/fcgi templates (the deb flow) are refreshed where they were
    # copied and never installed by a rollout.
    TPL_NEW=0 refresh_template "$TPLDIR" lazysite-cgi  tpl stpl
    TPL_NEW=0 refresh_template "$TPLDIR" lazysite-fcgi tpl stpl
fi

# SM283: the nginx PROXY template. Separate because it is a different layer, in
# a different directory, and getting it wrong is a disclosure (SM283 statics,
# SM929 X-Forwarded-For) rather than a cosmetic drift.
if [ -d "$PROXYTPLDIR" ]; then
    if [ -f "$TPL_SRC/$PROXY_TPL.tpl" ]; then
        refresh_template "$PROXYTPLDIR" "$PROXY_TPL" tpl stpl
    else
        echo "    NOTE: STAGE has no $PROXY_TPL template (pre-SM283 release)" >&2
    fi
fi
[ "${#TPL_CHANGED[@]}" -gt 0 ] || [ "$TPL_FAILURES" -gt 0 ] || echo "    all current - nothing to refresh."

# Every domain on a replaced template renders the old one until it is rebuilt.
NEED_REBUILD=()
for _t in "${TPL_CHANGED[@]:-}"; do
    [ -n "$_t" ] || continue
    while IFS= read -r _k; do
        in_list "$_k" "${NEED_REBUILD[@]:-}" || NEED_REBUILD+=( "$_k" )
    done < <(domains_on_template "$_t")
done
if [ "${#NEED_REBUILD[@]}" -gt 0 ]; then
    echo "    these domains render the replaced template until their vhost is rebuilt:"
    printf '      %s\n' "${NEED_REBUILD[@]}"
    [ "$DO_REBUILD" = 1 ] || rebuild_hint "    rebuild them: --rebuild, or for each"
fi

# --- move each domain onto the proxy template (SM283) ------------------------
# Opt-in, because this changes a template ASSIGNMENT. v-change-web-domain-proxy-tpl
# rebuilds the vhost itself, so no separate rebuild is needed for this step.
PROXY_MOVED=0
PROXY_FAILED=()
if [ "$DO_PROXY" = 1 ]; then
    if [ ! -f "$PROXYTPLDIR/$PROXY_TPL.tpl" ]; then
        echo "$0: $PROXY_TPL is not staged in $PROXYTPLDIR - cannot apply it" >&2
        exit 3
    fi
    echo "==> putting each domain on the $PROXY_TPL nginx proxy template"
    for i in "${!DOMAINS[@]}"; do
        d="${DOMAINS[$i]}"; u="${USERS[$i]}"
        if "$HESTIA/bin/v-change-web-domain-proxy-tpl" "$u" "$d" "$PROXY_TPL" >/dev/null 2>&1; then
            echo "    proxy template applied: $d"
            PROXY_MOVED=$((PROXY_MOVED + 1))
        else
            echo "    PROXY TEMPLATE FAILED: $d (user $u)" >&2
            PROXY_FAILED+=( "$d (user $u)" )
        fi
    done
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
    # SM1196: a domain on a refreshed template that this run does not manage
    # (the cgi/fcgi flow) renders the old one just the same.
    for _k in "${NEED_REBUILD[@]:-}"; do
        [ -n "$_k" ] || continue
        in_list "${_k#*/}" "${DOMAINS[@]}" && continue
        if "$HESTIA/bin/v-rebuild-web-domain" "${_k%%/*}" "${_k#*/}" >/dev/null 2>&1; then
            echo "    rebuilt: ${_k#*/}"
            # SM1236: this run neither deploys nor repairs a domain it does not
            # manage, and a rebuild resets its docroot permissions (SM270). Say
            # what to run rather than repair a site outside this run's scope.
            echo "    rebuilt outside this rollout - now run: $(cli_cmd) repair --domain ${_k#*/} (a rebuild resets the docroot permissions, SM270)"
        else
            echo "    REBUILD FAILED: ${_k#*/} (user ${_k%%/*})" >&2
        fi
    done
fi

# --- deploy each -------------------------------------------------------------
# Per-site exit: 0 = updated, 4 = skipped by the site's update channel (stable
# site, edge release), 5 = installed and NOT serviceable (the health check still
# fails after the deploy's repair), anything else = failed.
#
# Q16f: 4 USED TO MEAN TWO THINGS. install.pl exits 4 for "installed, not
# serviceable" (SM933) and the deploy script passed that through, so on the
# 0.15.4 edge rollout a site that upgraded and failed its health check was
# listed here as "skipped (channel)" - 0 failed, no findings, and the watcher
# printed "deployed". The deploy script now maps it to 5 at its boundary, and 5
# is its own column: the site took the release and needs a human, so it is not
# a skip and not a retryable install failure (exit 2 below, not 1).
ok=0; SKIPPED=(); FAILED=(); UNSERVICEABLE=(); RESULTS=()
for i in "${!DOMAINS[@]}"; do
    d="${DOMAINS[$i]}"; u="${USERS[$i]}"
    # ERREXIT IS ON HERE, and was before this line existed. The scope loop above
    # ends each iteration with `set -e`, so from its first pass onwards a
    # non-zero simple command exits the script - and `cmd; rc=$?` does NOT
    # protect against that, because the exit happens before the assignment
    # runs. The deploy loop therefore could not do what it says: the first site
    # that failed to install ABORTED THE ROLLOUT, so FAILED never filled, and
    # the "ROLLOUT FAILED - a retry is meaningful" verdict at the end could
    # never print. It stayed invisible because installs succeed; the failure
    # path was the one nobody exercised.
    #
    # Guarded explicitly, the way the scope loop already guards its own call.
    set +e
    run_quiet "$d" bash "$DEPLOY" "$u" "$d" "$STAGE"
    rc=$?
    set -e
    if   [ "$rc" = 0 ]; then ok=$(( ok + 1 )); RESULTS+=( "updated" )
    elif [ "$rc" = 4 ]; then SKIPPED+=( "$d" ); RESULTS+=( "skipped (channel)" )
    elif [ "$rc" = 5 ]; then UNSERVICEABLE+=( "$d" ); RESULTS+=( "NOT SERVICEABLE" )
    else                     FAILED+=( "$d" ); RESULTS+=( "FAILED (status $rc)" )
    fi
done

# --- re-apply access rules so protected content leaves the docroot -----------
#
# The upgrade step that no package can perform. See --reapply-acls above.
#
# Runs only on sites that ACTUALLY UPGRADED: a site skipped by its update
# channel is still on its old version, where the private store may not exist at
# all, and sweeping it would be meaningless at best.
#
# Each site is swept AS ITS OWN USER. The sweep writes into the site tree, and
# running it as root would leave root-owned files in a tree the CGI must write -
# the SM139 principle, and a mistake this project has made before.
REAPPLIED=0; REAPPLY_FAILED=()
if [ "${DO_REAPPLY:-0}" = 1 ]; then
    ACLTOOL="$STAGE/tools/lazysite-acl.pl"
    if [ ! -f "$ACLTOOL" ]; then
        echo "==> re-apply: $ACLTOOL missing in the staged release; skipping." >&2
    else
        echo
        echo "==> re-applying access rules (moves protected content out of the docroot)"
        for i in "${!DOMAINS[@]}"; do
            d="${DOMAINS[$i]}"; u="${USERS[$i]}"
            in_list "$d" "${SKIPPED[@]}" && continue
            in_list "$d" "${FAILED[@]}"  && continue
            # The lister's docroot for this site, carried from discovery.
            dr="${DOCS[$i]}"
            [ -d "$dr" ] || { echo "    no docroot at $dr; skipping $d" >&2; continue; }
            # SM889 residue: THROUGH run_quiet, like every other per-site phase.
            # This was the one loop left printing raw, and on the 0.14.3 rollout
            # it was most of the transcript: 21 "No protected sections", every
            # site's "0 re-applied, 1 already in place" summary and its "Verify
            # from OUTSIDE" line, the [INFO] acl-set log lines, and the ~90-word
            # @group advisory six times over - none of it a finding of THIS
            # rollout. Quiet: a genuine refusal still matches NOISE_RE and is
            # collected; a failure still prints its whole output; the one
            # aggregate line below still says how many were re-applied.
            if run_quiet "$d" sudo -u "$u" perl "$ACLTOOL" reapply \
                 --docroot "$dr" --actor local --apply; then
                REAPPLIED=$(( REAPPLIED + 1 ))
            else
                REAPPLY_FAILED+=( "$d" )
            fi
        done
        echo "==> re-applied on $REAPPLIED site(s).  Failed ${#REAPPLY_FAILED[@]}."
        [ "${#REAPPLY_FAILED[@]}" -gt 0 ] && \
            printf 'REAPPLY FAILED: %s\n' "${REAPPLY_FAILED[*]}"
    fi
else
    echo "==> access rules: not re-applied (no --reapply-acls); content protected before 0.10.9 keeps its files in the docroot."
fi

# --- SM1238: the SM296 dry run, per site -------------------------------------
# The same sites and the same user as the apply above; it moves nothing.
DRY_FOUND=(); DRY_FAILED=(); DRY_SETTLED=0
if [ "${DO_REAPPLY_DRY:-0}" = 1 ]; then
    ACLTOOL="$STAGE/tools/lazysite-acl.pl"
    if [ ! -f "$ACLTOOL" ]; then
        echo "==> acl dry run: $ACLTOOL missing in the staged release; skipping." >&2
    else
        echo
        echo "==> acl dry run (SM296): which stored rules still have their files in the document root"
        for i in "${!DOMAINS[@]}"; do
            d="${DOMAINS[$i]}"; u="${USERS[$i]}"
            in_list "$d" "${SKIPPED[@]}" && continue
            in_list "$d" "${FAILED[@]}"  && continue
            dr="${DOCS[$i]}"
            [ -d "$dr" ] || { echo "    no docroot at $dr; skipping $d" >&2; continue; }
            acl_dry_run_site "$d" "$u" "$dr"
            case "$DRY_VERDICT" in
                found)   DRY_FOUND+=( "$d" ) ;;
                failed)  DRY_FAILED+=( "$d" ) ;;
                *)       DRY_SETTLED=$(( DRY_SETTLED + 1 )) ;;
            esac
        done
        echo "==> acl dry run: ${#DRY_FOUND[@]} site(s) with content not moved, $DRY_SETTLED settled, ${#DRY_FAILED[@]} could not run."
        [ "${#DRY_FOUND[@]}" -gt 0 ] && \
            printf '  NOT MOVED on: %s (each path is under findings; --reapply-acls moves them)\n' "${DRY_FOUND[*]}"
        [ "${#DRY_FAILED[@]}" -gt 0 ] && \
            printf '  DRY RUN FAILED: %s\n' "${DRY_FAILED[*]}"
    fi
fi
[ "${#SKIPPED[@]}" -gt 0 ] && printf 'SKIPPED (stable site, edge release not installed): %s\n' "${SKIPPED[*]}"
[ "${#FAILED[@]}" -gt 0 ]  && printf 'FAILED to upgrade: %s\n' "${FAILED[*]}"
[ "${#UNSERVICEABLE[@]}" -gt 0 ] && \
    printf 'NOT SERVICEABLE (installed; the health check still fails - needs a human): %s\n' "${UNSERVICEABLE[*]}"

# --- health repair and the outside-in probe, via the CLI ---------------------
#
# SM321: these were 180 lines of per-site logic in THIS script, which meant they
# existed only here - an operator on any other layout could not run them at all,
# and one on Hestia could not run them for a single site without running the
# whole rollout. Neither operation is Hestia-specific.
#
# They are now `lazysite repair` and `lazysite probe`, addressing sites through
# the registry or this host's own site list. This script sequences them; it no
# longer contains them.
if [ -f "$LZS" ]; then
    # SM345: --domain per IN-SCOPE site, never --all.
    #
    # `repair` WRITES. `--all` addressed every site on the host, so an edge
    # rollout repaired sites sitting on stable - a change made to a site running
    # older code by a release that was never meant to reach it. `probe` only
    # reads, but reporting an out-of-scope site's exposure as a finding of THIS
    # rollout is what made a working deploy look failed (SM344).
    #
    # A site is either in scope for this release or it is left alone. There is no
    # third category where we touch it a little.
    echo "==> health: repair, then probe (in-scope sites only)"
    _rep_clean=0; _rep_fixed=0; _rep_human=0
    for i in "${!DOMAINS[@]}"; do
        set +e
        run_quiet "repair ${DOMAINS[$i]}" perl "$LZS" repair --domain "${DOMAINS[$i]}"
        _rc=$?
        set -e
        case "$_rc" in
            0) _rep_clean=$(( _rep_clean + 1 )) ;;
            *) _rep_human=$(( _rep_human + 1 )); REPAIR_RC=1 ;;
        esac
    done

    if [ "${DO_ACL_PROBE:-1}" = 1 ]; then
        # SM912 P2: THREE COLUMNS, because the probe has three answers. This
        # counted `0` as clean and everything else as exposed, so a site whose
        # probe could not RUN - which SM901 made the normal case for a release -
        # landed in the clean column and the summary certified a measurement that
        # never happened. Exit 3 is the probe saying so; it is not an exposure
        # and it is not a pass.
        _probe_ok=0; _probe_bad=0; _probe_none=0
        # SM1237: probe_site reads the verdict from the probe's own words, and
        # puts the reason for each could-not-run among the findings.
        for i in "${!DOMAINS[@]}"; do
            PROBE_TOOL_FAILED=''
            probe_site "${DOMAINS[$i]}"
            case "$PROBE_VERDICT" in
                ok)      _probe_ok=$(( _probe_ok + 1 )) ;;
                exposed) _probe_bad=$(( _probe_bad + 1 )); ACL_PROBE_RC=1 ;;
                *)       _probe_none=$(( _probe_none + 1 ))
                         [ -z "$PROBE_TOOL_FAILED" ] || ACL_PROBE_RC=1 ;;
            esac
        done
    fi
fi

echo
if [ "$DO_PROXY" = 1 ]; then
    echo "==> front end: $PROXY_MOVED domain(s) now on the $PROXY_TPL proxy template"
    if [ "${#PROXY_FAILED[@]}" -gt 0 ]; then
        printf '  NOT MOVED: %s\n' "${PROXY_FAILED[@]}"
        echo "  These still serve gated static files directly (SM283)."
    fi
else
    echo "==> front end: not checked or changed (no --proxy); a domain not on $PROXY_TPL serves protected statics publicly (SM283)."
fi

# --- SUMMARY: the same candidates, with what actually happened to each -------
echo
printf '==> SUMMARY: %s\n' "$NEWVER"
echo
sum_head
# CHECK and VHOST as they stand AFTER the rollout: the check is read-only and
# runs once per in-scope site that installed; the vhost is re-read, because
# --rebuild and --proxy render it again on the way.
_chk_clean=0; _chk_warn=0; _vh_rebuild=0
_xff_bad=0
for i in "${!DOMAINS[@]}"; do
    _chk='-'
    # Q16f: a site that installed and is not serviceable is checked too - it
    # runs this release, and its check is the finding. It was reported as a
    # channel skip, so the summary said "0 with warnings or failures" while the
    # check had both.
    if [ -f "$LZS" ] && { [ "${RESULTS[$i]:-}" = updated ] || [ "${RESULTS[$i]:-}" = "NOT SERVICEABLE" ]; }; then
        _chk=$(check_verdict "${DOMAINS[$i]}")
        if [ "$_chk" = clean ]; then _chk_clean=$(( _chk_clean + 1 )); else _chk_warn=$(( _chk_warn + 1 )); fi
    fi
    _vh=$(vhost_state "${USERS[$i]}" "${DOMAINS[$i]}" "$STAGED_REV")
    [ "$_vh" = rebuild ] && _vh_rebuild=$(( _vh_rebuild + 1 ))
    record_xff_exposure "${USERS[$i]}" "${DOMAINS[$i]}" "${DOCS[$i]:-}" && _xff_bad=$(( _xff_bad + 1 ))
    sum_row "${DOMAINS[$i]}" "${VERS[$i]:-?}" "$NEWVER" "$_chk" "$_vh" "${RESULTS[$i]:-?}"
done
for i in "${!OUT_OF_SCOPE[@]}"; do
    sum_row "${OUT_OF_SCOPE[$i]}" '-' '-' '-' '-' 'not in scope (untouched)'
done
for i in "${!EXC_D[@]}"; do
    sum_row "${EXC_D[$i]}" "${EXC_V[$i]}" '-' '-' '-' 'excluded (untouched)'
done
echo
printf '  %d updated, %d failed, %d not serviceable, %d skipped, %d out of scope, %d excluded\n' \
    "$ok" "${#FAILED[@]}" "${#UNSERVICEABLE[@]}" "${#SKIPPED[@]}" "${#OUT_OF_SCOPE[@]}" "${#EXC_D[@]}"
[ -n "${_rep_clean:-}" ] && \
    printf '  repair: %d clean, %d need a human\n' "${_rep_clean:-0}" "${_rep_human:-0}"
[ -n "${_probe_ok:-}" ] && \
    printf '  probe:  %d clean, %d exposed, %d could not run%s\n' \
        "${_probe_ok:-0}" "${_probe_bad:-0}" "${_probe_none:-0}" \
        "$( [ "${_probe_none:-0}" -gt 0 ] && echo ' (the reason for each is under findings: "probe could not run")' )"
[ -f "$LZS" ] && \
    printf '  check:  %d clean, %d with warnings or failures (%s check --domain D shows each)\n' \
        "$_chk_clean" "$_chk_warn" "$(cli_cmd)"
[ "$_vh_rebuild" -gt 0 ] && \
    printf '  vhost:  %d site(s) render an older template - rebuild them to take this release'"'"'s front-end rules (--rebuild, or v-rebuild-web-domain USER DOMAIN then %s repair --domain DOMAIN)\n' \
        "$_vh_rebuild" "$(cli_cmd)"
xff_summary_line "$_xff_bad"
report_findings

[ "$VERBOSE" = 0 ] && \
    echo '  (quiet report; re-run with --verbose for every phase in full)'

# SM344: TWO different facts, and they had one bit between them.
#
#   1 = THIS ROLLOUT FAILED. A site's install or proxy move did not work. A
#       retry is meaningful, because the thing that failed is the thing being
#       retried.
#   2 = the rollout SUCCEEDED and the FLEET HAS FINDINGS. Sites need repair, or
#       the probe found content served that the engine refuses. Those are
#       conditions the sites were in before this ran and are in afterwards; a
#       retry changes nothing and a human is needed.
#
# The 0.10.12 rollout is why. Every site that could take it installed and
# verified, the release was independently confirmed working from outside, and
# the run exited 1 because 22 sites on an OLDER line were exposed. The watcher
# read that as a failed deployment and told the operator to bump the version and
# retry - burning a version number to re-run a deploy that had worked, against a
# condition it could not address.
#
# SM317's requirement is kept exactly: an exposure is still non-zero, so a caller
# reading only $? cannot miss it. What changes is that the caller can now tell
# which kind of non-zero it has.
if [ "${#FAILED[@]}" -gt 0 ] || [ "${#PROXY_FAILED[@]}" -gt 0 ] || [ "${TPL_FAILURES:-0}" -gt 0 ]; then
    echo
    echo "ROLLOUT FAILED: ${#FAILED[@]} site(s) failed to install, ${#PROXY_FAILED[@]} proxy move(s) failed, ${TPL_FAILURES:-0} template refresh(es) failed."
    echo "  A retry is meaningful - the operation that failed is the one being retried."
    exit 1
fi

# Q16f: a site that installed and is not serviceable is a finding of THIS
# rollout that needs a human - 2, not 1: re-running the install does not make
# the health check pass.
if [ "${#UNSERVICEABLE[@]}" -gt 0 ]; then
    echo
    echo "ROLLOUT INSTALLED, ${#UNSERVICEABLE[@]} SITE(S) NOT SERVICEABLE: the release is in"
    echo "  place on them and their health check still fails after the repair:"
    printf '    %s\n' "${UNSERVICEABLE[@]}"
    echo "  They need a human ($(cli_cmd) check --domain D names each failure);"
    echo "  re-running this deploy will not change them, and neither will cutting"
    echo "  another version."
    exit 2
fi

if [ "${REPAIR_RC:-0}" != 0 ] || [ "${ACL_PROBE_RC:-0}" != 0 ] || [ "${_xff_bad:-0}" != 0 ] \
   || [ -n "${DRY_FOUND[*]:-}" ] || [ -n "${DRY_FAILED[*]:-}" ]; then
    echo
    echo "ROLLOUT SUCCEEDED, FLEET HAS FINDINGS: every site that accepted this"
    echo "  release installed and verified. The findings above are conditions the"
    echo "  fleet was already in - re-running this deploy will not change them, and"
    echo "  neither will cutting another version. They need a human."
    exit 2
fi
exit 0
