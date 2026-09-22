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
        *)            ARGS+=("$a") ;;
    esac
done
STAGE="${ARGS[0]:-$(cd "$(dirname "$0")/../.." && pwd)}"

[ "$(id -u)" = 0 ] || { echo "$0: must run as root" >&2; exit 1; }
DEPLOY="$STAGE/installers/hestia/lazysite-hestia-deploy.sh"
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

# report_findings - print every collected finding once, with the sites it
# affects. Silent when there is nothing, because a heading over an empty list
# is the kind of line this change exists to remove.
report_findings() {
    [ -n "$FINDINGS_FILE" ] && [ -s "$FINDINGS_FILE" ] || return 0
    echo
    echo '==> findings (one line per distinct message, with the sites it affects)'
    group_findings < "$FINDINGS_FILE"
}

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
group_findings() {
    local TAB
    TAB=$(printf '\t')
    # "phase site<TAB>msg" -> "site<TAB>msg"; a bare "site<TAB>msg" is untouched.
    # Then one line per (message, site): sort -u on those two keys IS the dedupe.
    sed "s/^[^${TAB}]* \([^${TAB} ]*\)${TAB}/\1${TAB}/" \
        | sort -t "$TAB" -u -k2,2 -k1,1 \
        | awk -F'\t' '
            {
                if (!($2 in cnt)) order[++k] = $2
                cnt[$2]++
                sites[$2] = sites[$2] (sites[$2] ? ", " : "") $1
            }
            END {
                for (i = 1; i <= k; i++) {
                    m = order[i]
                    printf "  [%d] %s\n      sites: %s\n", cnt[m], m, sites[m]
                }
            }'
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
        # SM889: COLLECTED, not printed. Each finding is stored as
        # label<TAB>message and reported once at the end with the sites it
        # affects - see report_findings. Leading and trailing space is trimmed
        # so the same message indented differently by two phases still groups.
        if [ -n "$FINDINGS_FILE" ]; then
            printf '%s\n' "$out" | grep -E "$NOISE_RE" \
                | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
                | while IFS= read -r line; do
                    [ -n "$line" ] && printf '%s\t%s\n' "$label" "$line" >> "$FINDINGS_FILE"
                done || true
        else
            printf '%s\n' "$out" | grep -E "$NOISE_RE" | sed "s/^/  [$label] /" || true
        fi
    fi
    return "$rc"
}


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
    echo '  Excluded: re-set the template or remove the stale marker to reconcile (lazysite-hestia-list.sh).'
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

# --- refresh the shared Hestia web template (so vhost changes propagate) -----
if [ "$DO_TPL" = 1 ] && [ -d "$TPLDIR" ]; then
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
    #
    # It stays opt-in (--templates / --rebuild / --proxy) and it now says who
    # else it reaches.
    echo "==> refreshing the lazysite-app web template in $TPLDIR"
    if [ "${#OUT_OF_SCOPE[@]}" -gt 0 ]; then
        echo "    NOTE: this template is SHARED and cannot be scoped to a channel."
        printf '    %d out-of-scope site(s) also use it and will render the new\n' \
            "${#OUT_OF_SCOPE[@]}"
        echo "    version the next time their vhost is rebuilt, by anything."
        echo "    Refresh the template on the channel you are promoting TO."
    fi
    cp "$STAGE/installers/hestia/lazysite-app.tpl"  "$TPLDIR/lazysite-app.tpl"
    cp "$STAGE/installers/hestia/lazysite-app.stpl" "$TPLDIR/lazysite-app.stpl"
    cp "$STAGE/installers/hestia/lazysite-app.sh"   "$TPLDIR/lazysite-app.sh"
    chmod 755 "$TPLDIR/lazysite-app.sh"
fi

# --- stage the nginx PROXY templates (SM283) ---------------------------------
# Separate from the block above because it is a different layer, in a different
# directory, and getting it wrong is a disclosure rather than a cosmetic drift.
if [ "$DO_TPL" = 1 ] && [ -d "$PROXYTPLDIR" ]; then
    if [ -f "$STAGE/installers/hestia/$PROXY_TPL.tpl" ]; then
        echo "==> staging the $PROXY_TPL nginx proxy template in $PROXYTPLDIR"
        cp "$STAGE/installers/hestia/$PROXY_TPL.tpl"  "$PROXYTPLDIR/$PROXY_TPL.tpl"
        cp "$STAGE/installers/hestia/$PROXY_TPL.stpl" "$PROXYTPLDIR/$PROXY_TPL.stpl"
    else
        echo "    NOTE: STAGE has no $PROXY_TPL template (pre-SM283 release)" >&2
    fi
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
fi

# --- deploy each -------------------------------------------------------------
# Per-site exit: 0 = updated, 4 = skipped by the site's update channel (stable
# site, edge release), anything else = failed.
ok=0; SKIPPED=(); FAILED=(); RESULTS=()
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
[ "${#SKIPPED[@]}" -gt 0 ] && printf 'SKIPPED (stable site, edge release not installed): %s\n' "${SKIPPED[*]}"
[ "${#FAILED[@]}" -gt 0 ]  && printf 'FAILED to upgrade: %s\n' "${FAILED[*]}"

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
LZS="$STAGE/tools/lazysite-cli.pl"
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
        _probe_ok=0; _probe_bad=0
        for i in "${!DOMAINS[@]}"; do
            set +e
            run_quiet "probe ${DOMAINS[$i]}" perl "$LZS" probe --domain "${DOMAINS[$i]}"
            _rc=$?
            set -e
            case "$_rc" in
                0) _probe_ok=$(( _probe_ok + 1 )) ;;
                *) _probe_bad=$(( _probe_bad + 1 )); ACL_PROBE_RC=1 ;;
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
for i in "${!DOMAINS[@]}"; do
    _chk='-'
    if [ -f "$LZS" ] && [ "${RESULTS[$i]:-}" = updated ]; then
        _chk=$(check_verdict "${DOMAINS[$i]}")
        if [ "$_chk" = clean ]; then _chk_clean=$(( _chk_clean + 1 )); else _chk_warn=$(( _chk_warn + 1 )); fi
    fi
    _vh=$(vhost_state "${USERS[$i]}" "${DOMAINS[$i]}" "$STAGED_REV")
    [ "$_vh" = rebuild ] && _vh_rebuild=$(( _vh_rebuild + 1 ))
    sum_row "${DOMAINS[$i]}" "${VERS[$i]:-?}" "$NEWVER" "$_chk" "$_vh" "${RESULTS[$i]:-?}"
done
for i in "${!OUT_OF_SCOPE[@]}"; do
    sum_row "${OUT_OF_SCOPE[$i]}" '-' '-' '-' '-' 'not in scope (untouched)'
done
for i in "${!EXC_D[@]}"; do
    sum_row "${EXC_D[$i]}" "${EXC_V[$i]}" '-' '-' '-' 'excluded (untouched)'
done
echo
printf '  %d updated, %d failed, %d skipped, %d out of scope, %d excluded\n' \
    "$ok" "${#FAILED[@]}" "${#SKIPPED[@]}" "${#OUT_OF_SCOPE[@]}" "${#EXC_D[@]}"
[ -n "${_rep_clean:-}" ] && \
    printf '  repair: %d clean, %d need a human\n' "${_rep_clean:-0}" "${_rep_human:-0}"
[ -n "${_probe_ok:-}" ] && \
    printf '  probe:  %d clean, %d exposed\n' "${_probe_ok:-0}" "${_probe_bad:-0}"
[ -f "$LZS" ] && \
    printf '  check:  %d clean, %d with warnings or failures (lazysite check --domain D shows each)\n' \
        "$_chk_clean" "$_chk_warn"
[ "$_vh_rebuild" -gt 0 ] && \
    printf '  vhost:  %d site(s) render an older template - rebuild them to take this release'"'"'s front-end rules (--rebuild, or v-rebuild-web-domain USER DOMAIN)\n' \
        "$_vh_rebuild"
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
if [ "${#FAILED[@]}" -gt 0 ] || [ "${#PROXY_FAILED[@]}" -gt 0 ]; then
    echo
    echo "ROLLOUT FAILED: ${#FAILED[@]} site(s) failed to install, ${#PROXY_FAILED[@]} proxy move(s) failed."
    echo "  A retry is meaningful - the operation that failed is the one being retried."
    exit 1
fi

if [ "${REPAIR_RC:-0}" != 0 ] || [ "${ACL_PROBE_RC:-0}" != 0 ]; then
    echo
    echo "ROLLOUT SUCCEEDED, FLEET HAS FINDINGS: every site that accepted this"
    echo "  release installed and verified. The findings above are conditions the"
    echo "  fleet was already in - re-running this deploy will not change them, and"
    echo "  neither will cutting another version. They need a human."
    exit 2
fi
exit 0
