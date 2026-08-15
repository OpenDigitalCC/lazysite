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
DO_TPL=0
DO_REBUILD=0
DO_PROXY=0
ARGS=()
for a in "$@"; do
    case "$a" in
        --list)       LIST=1 ;;
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
TPLDIR="$HESTIA/data/templates/web/apache2/php-fpm"
# SM283: the nginx proxy layer. Hestia scans proxy templates here, one level
# up from the web templates above (nginx as PROXY, not as web server).
PROXYTPLDIR="$HESTIA/data/templates/web/nginx"
PROXY_TPL='lazysite-proxy'

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
            # The docroot follows the Hestia layout the discovery loop above
            # walks: /home/<user>/web/<domain>/public_html.
            dr="/home/$u/web/$d/public_html"
            [ -d "$dr" ] || { echo "    no docroot at $dr; skipping $d" >&2; continue; }
            if sudo -u "$u" perl "$ACLTOOL" reapply \
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
    echo
    echo "==> access rules: NOT re-applied (no --reapply-acls)."
    echo "    Any section protected before 0.10.9 still has its FILES in the"
    echo "    document root. Verify from outside with:"
    echo "        lazysite check --check-acl https://<domain>/"
fi
[ "${#SKIPPED[@]}" -gt 0 ] && printf 'SKIPPED (stable site, edge release not installed): %s\n' "${SKIPPED[*]}"
[ "${#FAILED[@]}" -gt 0 ]  && printf 'FAILED to upgrade: %s\n' "${FAILED[*]}"

# --- consolidated health summary, and repair what can be repaired ------------
#
# SM270 RECURS, and reporting it is not enough.
#
# The per-site deploy runs `lazysite-check --fix`, so a site that goes through
# it is repaired. A vhost rebuild AFTER that - or one driven through the control
# panel's own path rather than this script - returns public_html as drwxr-s--x
# with no group write, and nothing runs again to notice.
#
# A 0.10.9 field test found exactly that on edge, three releases after SM270
# shipped the repair. The consequences are not cosmetic: the private store is a
# SIBLING of the docroot, so with the docroot unwritable, `lazysite acl reapply`
# fails on every folder and SM283 stays live across the instance regardless of
# what was upgraded. Protecting a section stores the rule and leaves the content
# served.
#
# This block used to run the doctor READ-ONLY and print what it found. An
# operator reading a warning at the end of a long rollout, on a host they were
# not otherwise touching, is the weakest possible link in that chain - and the
# repair was already written and already shipped. So: find it, fix it, then
# CHECK AGAIN and report what survived.
#
# The re-check is the point. This project's recurring defect is a control that
# reports success without doing the work, and "we ran --fix" is a claim about an
# action; "the site is clean afterwards" is a claim about the outcome. Only the
# second is worth printing.
CHK="$STAGE/tools/lazysite-check.pl"
if [ -f "$CHK" ]; then
    echo
    echo "==> health summary (warnings + failures by site)"
    dirty=0; repaired=0; STILL_DIRTY=()
    for i in "${!DOMAINS[@]}"; do
        d="${DOMAINS[$i]}"; u="${USERS[$i]}"
        doc="/home/$u/web/$d/public_html"
        cgi="/home/$u/web/$d/cgi-bin"
        [ -d "$doc" ] || continue

        issues="$(perl "$CHK" --docroot "$doc" --cgibin "$cgi" 2>/dev/null \
                  | grep -E '\[ (warn|FAIL) \]')"
        [ -n "$issues" ] || continue

        dirty=$(( dirty + 1 ))
        echo "  $d:"
        echo "$issues" | sed 's/^[[:space:]]*/    /'

        # Repair as ROOT, matching the per-site deploy, which is what lets the
        # check work the ownership out itself. lazysite-check --fix repairs modes
        # and ownership; it does not touch content, so it is safe to run on a
        # site that is merely warning about something else.
        echo "    -> repairing (lazysite check --fix)"
        perl "$CHK" --docroot "$doc" --cgibin "$cgi" --fix >/dev/null 2>&1 || true

        left="$(perl "$CHK" --docroot "$doc" --cgibin "$cgi" 2>/dev/null \
                | grep -E '\[ (warn|FAIL) \]')"
        if [ -z "$left" ]; then
            repaired=$(( repaired + 1 ))
            echo "    -> repaired; the site is clean."
        else
            STILL_DIRTY+=( "$d" )
            echo "    -> STILL OUTSTANDING after the repair:"
            echo "$left" | sed 's/^[[:space:]]*/       /'
        fi
    done

    if [ "$dirty" = 0 ]; then
        echo "  all sites clean - no warnings or failures."
    else
        echo "  $dirty site(s) had issues; $repaired repaired automatically."
        if [ "${#STILL_DIRTY[@]}" -gt 0 ]; then
            printf '  NEEDS A HUMAN: %s\n' "${STILL_DIRTY[*]}"
            # Naming the consequence, because a permissions warning reads as
            # housekeeping and this one is not: it is why protected content is
            # still being served.
            echo "  A docroot that is still not writable means the private store"
            echo "  cannot be written, so 'lazysite acl reapply' will fail and"
            echo "  protected sections stay served by the front end. Verify from"
            echo "  OUTSIDE - the engine's report and the front end's behaviour"
            echo "  are different claims:"
            echo "        lazysite check --check-acl https://<domain>/"
        fi
    fi
fi

# --- outside-in ACL probe: does the FRONT END respect the rule? --------------
#
# SM317. The recurring shape, now three times over: a rule can be stored,
# honoured by the engine, reported as applied, and contribute NOTHING to what an
# anonymous request receives. SM283 was that for weeks across a live fleet;
# SM296 was the crash that produced the same state; SM313 was the repair that
# looked complete and left it live. Measured on edge as recently as today, after
# a successful docroot repair: eight of ten probed extensions served 200
# anonymously from a folder with an active read list.
#
# SM285 built `lazysite check --check-acl URL` for exactly this, and it has never
# been part of what a deploy verifies. The tool existed; failing it stopped
# nothing. That is the whole finding.
#
# IT BELONGS HERE RATHER THAN IN THE RELEASE GATE. The gate runs offline against
# a clean checkout of a tag - there is no deployed site to fetch, so the question
# it answers cannot be asked there. It is a property of a SITE, not of a build.
#
# It does NOT abort the deploy: aborting a fleet rollout midway leaves sites on
# mixed versions, which is worse than the condition being reported. It reports
# loudly and sets the exit status, so an automated caller sees it.
if [ "${DO_ACL_PROBE:-1}" = 1 ] && [ -f "$CHK" ]; then
    echo
    echo "==> outside-in ACL probe (does the front end honour the rule?)"
    probe_bad=(); probe_skipped=(); probe_ok=0
    for i in "${!DOMAINS[@]}"; do
        d="${DOMAINS[$i]}"; u="${USERS[$i]}"
        doc="/home/$u/web/$d/public_html"
        [ -d "$doc" ] || continue
        in_list "$d" "${SKIPPED[@]}" && continue
        in_list "$d" "${FAILED[@]}"  && continue

        # As the site user: the probe writes a folder into the docroot and
        # removes it again, and root-owned leftovers in a tree the CGI must
        # write are the SM139 mistake this project has made before.
        out="$(sudo -u "$u" perl "$CHK" --docroot "$doc" \
                 --check-acl "https://$d/" 2>&1)"
        # VERIFIED IS A POSITIVE SIGNAL, never an absence. SM319.
        #
        # The first cut derived the pass from the absence of `[ FAIL ]`, and
        # run_acl_probe has FIVE outcomes: the exposure, a clean confirmation,
        # a PARTIAL ("could not vouch for some file types"), "no usable answer -
        # nothing was served, gated or public", and three paths that return
        # before fetching at all. Four of the five are not a pass, and all four
        # were being announced as "front end honours the rule".
        #
        # The reported instance was the non-fetching returns, whose trigger is an
        # unwritable docroot - what a vhost rebuild produces (SM270), and what
        # edge was in this morning. A deploy runs right after a rebuild, so the
        # population silently absolved is exactly the population being probed
        # for. But fixing only that leaves the partial and the no-answer cases
        # lying in the same way.
        #
        # So the pass requires the probe to SAY it confirmed something. Anything
        # else - today's four, and any outcome added later - falls to "not
        # confirmed", which is the safe direction. This is the defect the probe
        # itself shipped with (SM285: an empty extension list, zero fetches,
        # 0 == 0, and a verdict of "the front end respects the ACL" against a
        # port with nothing listening), reappearing one layer up.
        if printf '%s' "$out" | grep -qE '\[ FAIL \]'; then
            probe_bad+=( "$d" )
            echo "  $d: SERVED ANONYMOUSLY"
            printf '%s\n' "$out" | grep -E '\[ (warn|FAIL) \]' \
                | sed 's/^[[:space:]]*/    /'
        elif printf '%s' "$out" | grep -q 'the front end respects the ACL'; then
            probe_ok=$(( probe_ok + 1 ))
            echo "  $d: front end honours the rule"
        else
            # Not a pass and not an exposure: nothing was confirmed. The reason
            # is whatever the probe warned about - a docroot it could not write,
            # an unreachable URL, or file types it could not vouch for.
            probe_skipped+=( "$d" )
            echo "  $d: NOT CONFIRMED"
            printf '%s\n' "$out" | grep -E '\[ warn \]' \
                | sed 's/^[[:space:]]*/    /'
        fi
    done

    printf '\n  %d verified, %d exposed, %d not confirmed.\n' \
        "$probe_ok" "${#probe_bad[@]}" "${#probe_skipped[@]}"

    if [ "${#probe_skipped[@]}" -gt 0 ]; then
        printf '  NOT CONFIRMED: %s\n' "${probe_skipped[*]}"
        echo "  Nothing was established either way for these. Usual causes: a"
        echo "  docroot or ACL store the probe could not write (the condition a"
        echo "  vhost rebuild produces, which is when this runs), a URL not"
        echo "  reachable from here, or file types it could not vouch for."
        echo "  Repair with 'lazysite check --fix' and re-run."
        # Deliberately NOT a non-zero exit: this is an absence of evidence, not
        # evidence of exposure, and failing a deploy on it would be wrong. The
        # named summary line is what the operator acts on.
    fi

    if [ "${#probe_bad[@]}" -gt 0 ]; then
        printf '\n  SERVED ANONYMOUSLY DESPITE AN ACL: %s\n' "${probe_bad[*]}"
        echo "  Protected content on these sites is reachable without signing in."
        echo "  The engine reports the rule as applied; the front end serves the"
        echo "  files anyway, which is SM283. Check the private store exists"
        echo "  (lazysite check --fix) and re-run the sweep with --reapply-acls."
        ACL_PROBE_RC=1
    fi
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

# --- the front-end layer (SM283) ---------------------------------------------
# Said last, and said even on a clean run, because this is the failure mode that
# hid: everything above can succeed - packages upgraded, vhosts rebuilt, health
# summary clean - while nginx keeps serving gated files, because none of it
# touches the proxy layer. `lazysite-hestia-list.sh` names the affected domains.
echo
if [ "$DO_PROXY" = 1 ]; then
    echo "==> front end: $PROXY_MOVED domain(s) now on the $PROXY_TPL proxy template"
    if [ "${#PROXY_FAILED[@]}" -gt 0 ]; then
        printf '  NOT MOVED: %s\n' "${PROXY_FAILED[@]}"
        echo "  These still serve gated static files directly (SM283)."
    fi
else
    echo "==> front end: NOT checked or changed (no --proxy)."
    echo "  On Hestia the ACL rules live in the Apache template, and nginx"
    echo "  answers static requests before Apache sees them. Until a domain is"
    echo "  on the $PROXY_TPL proxy template, a protected section's images,"
    echo "  PDFs and archives are public. Review: lazysite-hestia-list.sh"
fi

[ "${#FAILED[@]}" -gt 0 ] && exit 1
[ "${#PROXY_FAILED[@]}" -gt 0 ] && exit 1
# SM317: an exposure the outside-in probe found is a non-zero exit too. A fleet
# caller that only looks at $? must see it; until now the only way to learn about
# one was to read the log.
[ "${ACL_PROBE_RC:-0}" != 0 ] && exit 1
exit 0
