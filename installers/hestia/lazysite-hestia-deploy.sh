#!/bin/bash
# lazysite-hestia-deploy USER DOMAIN [STAGE_DIR] [--sysop NAME] [--channel C]
#
# One-command lazysite install/upgrade for a HestiaCP domain. RUN AS ROOT.
# It folds the whole INSTALL-RUNBOOK into a single invocation:
#   1. on FIRST-TIME setup only, apply the lazysite-app web template (its
#      rebuild hook, as root, creates the extensions/ and tools/ children of the
#      0551-locked domain root and sets the base www-data docroot perms). An
#      upgrade leaves the Hestia web template untouched - it only refreshes
#      code/content/perms - so a deliberately-changed template is preserved.
#      Force a re-apply with LAZYSITE_APPLY_TEMPLATE=1.
#   2. run install.pl as the domain user to deploy/upgrade the code;
#   3. set the directory layout + permissions a www-data CGI needs (the
#      reason a plain `install.pl` as the domain user can't do it alone -
#      it can't write the locked domain root or chgrp to www-data);
#   4. drop the Hestia placeholder index.html so index.md renders.
#
# A FIRST-TIME deploy also finishes a working site (n807, SM1427), so a new site is
# this one command and nothing chained after it:
#   - the lazysite-proxy nginx template is applied with lazysite-app, when Hestia
#     has it (when it does not, the script says so and names the command that
#     copies it);
#   - site_url is set to https://DOMAIN when lazysite.conf holds no absolute one
#     (through install.pl --site-url), so a claim link made on the command line
#     is a full URL;
#   - /etc/lazysite/sites.d/DOMAIN is written (docroot, cgibin, owner, channel,
#     policy=manual - the format `lazysite provision` writes) unless one exists;
#   - --channel C is the site's update channel (default edge in the registry; the
#     conf is set only when it is given, as `lazysite provision` does);
#   - --sysop NAME, once the health check passes, runs setup-sysop for NAME as the
#     site user and prints the claim link as a full https://DOMAIN/claim?... URL.
#     Without it the script says how to add one. A rerun on a site that already has
#     accounts does what setup-sysop does there, and says so.
# It ends with one summary: the URLs, the claim link, the registry entry, the probe.
#
# Exit status (read by lazysite-hestia-update-all.sh; Q16f):
#   0  installed, and the site passed the health check after the repair
#   1  the install or its verification failed (or install.pl's own non-zero)
#   2  a mistake in the invocation, or no install.pl in STAGE_DIR
#   4  SKIPPED by the site's update channel (stable site, edge build) - nothing
#      touched
#   5  installed, and the site is NOT serviceable: the health check still names
#      a failure after the permission pass and the repair - a human is needed
#
# LAZYSITE_FORCE_SECURITY=1 (SM1307, set by lazysite-hestia-update-all.sh
# --force-security) passes --force-security to install.pl, for the channel
# check and the upgrade: a site whose update_channel refuses the build takes it
# anyway, and only when the release's manifest declares security_critical -
# install.pl refuses the flag for any other payload, and so does this script.
#
# STAGE_DIR is the unpacked release (defaults to this script's dir, so it
# works straight from inside an extracted tarball: installers/hestia/..).
set -e

# SM850: where a site's engine tree is - <docroot>-lazysite once it has been
# moved out of the document root (SM293), <docroot>/lazysite before. The rule
# Lazysite::Paths::lazysite_dir states; t/lint/37 runs this copy against it.
# Built by hand, this script took a migrated site for a FIRST-TIME install on
# every upgrade (re-applying the Hestia web template and rebuilding the vhost),
# re-ran the manager's first-run setup, and swept and locked the permissions of
# an engine tree that was no longer there - leaving the real one's secrets as
# the install wrote them.
lazysite_dir() {
    local d="$1"
    while [ "${d%/}" != "$d" ]; do d="${d%/}"; done
    if [ -d "$d-lazysite" ]; then printf '%s\n' "$d-lazysite"; else printf '%s\n' "$d/lazysite"; fi
}

USAGE="usage: $0 USER DOMAIN [STAGE_DIR] [--sysop NAME] [--channel edge|beta|stable|certified]"
SYSOP=""; CHANNEL=""; POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --sysop)      [ $# -ge 2 ] || { echo "$0: --sysop needs a name" >&2; echo "$USAGE" >&2; exit 2; }
                  SYSOP="$2"; shift 2 ;;
    --sysop=*)    SYSOP="${1#--sysop=}"; shift ;;
    --channel)    [ $# -ge 2 ] || { echo "$0: --channel needs a value" >&2; echo "$USAGE" >&2; exit 2; }
                  CHANNEL="$2"; shift 2 ;;
    --channel=*)  CHANNEL="${1#--channel=}"; shift ;;
    -*)           echo "$0: unknown option '$1'" >&2; echo "$USAGE" >&2; exit 2 ;;
    *)            POS+=("$1"); shift ;;
  esac
done
U="${POS[0]:-}"; DOMAIN="${POS[1]:-}"; STAGE_ARG="${POS[2]:-}"
STAGE="${STAGE_ARG:-$(cd "$(dirname "$0")/../.." && pwd)}"
[ -n "$U" ] && [ -n "$DOMAIN" ] && [ "${#POS[@]}" -le 3 ] || { echo "$USAGE" >&2; exit 2; }
# Refused before anything is touched: a name or channel the tools would refuse after
# the install has run.
case "$CHANNEL" in ""|edge|beta|stable|certified) ;;
  *) echo "$0: --channel must be edge, beta, stable or certified (got '$CHANNEL')" >&2; exit 2 ;; esac
if [ -n "$SYSOP" ] && ! printf '%s' "$SYSOP" | grep -Eq '^[A-Za-z0-9_.-]+$'; then
  echo "$0: --sysop NAME may hold letters, digits, '.', '_' and '-' only (got '$SYSOP')" >&2; exit 2
fi
[ "$(id -u)" = 0 ] || { echo "$0: must run as root (it sets ownership/perms)" >&2; exit 1; }
# SM892 D4: install.sh is now a signpost that refuses everything, so this
# script drives install.pl - the implementation - directly, with an explicit
# --mode. Going through the wrapper would hit the refusal; going through it
# *without* a mode is what the ruling forbids.
[ -f "$STAGE/install.pl" ] || { echo "$0: no install.pl under STAGE '$STAGE'" >&2; exit 2; }

# SM1236: the CLI as this host runs it, for the hints below. The batch updater
# passes its spelling in LAZYSITE_CLI; the tarball puts no `lazysite` on PATH.
if [ -n "${LAZYSITE_CLI:-}" ]; then
  LZS_CLI="$LAZYSITE_CLI"
elif command -v lazysite >/dev/null 2>&1; then
  LZS_CLI=lazysite
else
  LZS_CLI="perl $STAGE/tools/lazysite-cli.pl"
fi

HESTIA=/usr/local/hestia
DOM="/home/$U/web/$DOMAIN"
DOC="$DOM/public_html"
CGI="$DOM/cgi-bin"
[ -d "$DOC" ] || { echo "$0: no docroot at $DOC" >&2; exit 1; }
LZ="$(lazysite_dir "$DOC")"

# n807: functions begin (t/tools/624 sources this block with stubs)
# Each reads the script's variables (U DOMAIN DOM DOC CGI LZ STAGE HESTIA CHANNEL
# SYSOP LZS_CLI) and prints what it did.

# lazysite-proxy is the nginx template that hands a protected section's static files
# back to Apache. Hestia has it only once the template is copied in.
apply_proxy_template() {
  if [ -f "$HESTIA/data/templates/web/nginx/lazysite-proxy.tpl" ]; then
    echo "==> applying lazysite-proxy nginx template (first-time setup)"
    "$HESTIA/bin/v-change-web-domain-proxy-tpl" "$U" "$DOMAIN" lazysite-proxy \
      || echo "  (could not apply lazysite-proxy - run: $HESTIA/bin/v-change-web-domain-proxy-tpl $U $DOMAIN lazysite-proxy)"
  else
    echo "==> lazysite-proxy is not installed in Hestia, so the nginx front end keeps its stock proxy"
    echo "    (static files in a protected section are then served before lazysite sees the request)."
    echo "    Copy it in, then apply it:"
    echo "      cp $STAGE/installers/hestia/lazysite-proxy.tpl $STAGE/installers/hestia/lazysite-proxy.stpl $HESTIA/data/templates/web/nginx/"
    echo "      $HESTIA/bin/v-change-web-domain-proxy-tpl $U $DOMAIN lazysite-proxy"
  fi
}

# site_url: an absolute address, set through install.pl when the conf has none.
# `${REQUEST_SCHEME}://${SERVER_NAME}` (the seeded template) is not one: only a web
# request can expand it, so a claim link made here had no host.
set_site_url() {
  local conf="$LZ/lazysite.conf" cur
  [ -f "$conf" ] || return 0
  cur="$(sed -n 's/^site_url:[[:space:]]*//p' "$conf" | head -1)"
  case "$cur" in
    *'$'*) ;;
    http://*|https://*) echo "==> site_url is already $cur - left as it is"; return 0 ;;
  esac
  echo "==> setting site_url to https://$DOMAIN"
  sudo -u "$U" perl "$STAGE/install.pl" --site-url "https://$DOMAIN" --docroot "$DOC" \
    || echo "  (could not set site_url - run: sudo -u $U perl $STAGE/install.pl --site-url https://$DOMAIN --docroot $DOC)"
}

# --channel C is the site's update channel; `lazysite provision` sets the conf key
# only when it is given, and so does this.
set_site_channel() {
  [ -n "$CHANNEL" ] || return 0
  echo "==> update channel: $CHANNEL"
  sudo -u "$U" perl "$STAGE/install.pl" --channel "$CHANNEL" --docroot "$DOC" \
    || echo "  (could not set the channel - run: sudo -u $U perl $STAGE/install.pl --channel $CHANNEL --docroot $DOC)"
}

# The registry entry `lazysite provision` writes (registry_record in
# tools/lazysite-cli.pl: docroot, cgibin, owner, channel, policy, in that order).
# That verb refuses root and this script is root, so the five lines are written here;
# t/tools/624 holds the order to the CLI's. An existing entry is never overwritten.
write_registry() {
  local dir="${LAZYSITE_REGISTRY_DIR:-/etc/lazysite/sites.d}" tmp
  REGISTRY_PATH="$dir/$DOMAIN"
  if [ -e "$REGISTRY_PATH" ]; then
    REGISTRY_NOTE="already present, left unchanged"
    return 0
  fi
  mkdir -p "$dir"
  tmp="$REGISTRY_PATH.tmp.$$"
  {
    echo "docroot=$DOC"
    echo "cgibin=$CGI"
    echo "owner=$U"
    echo "channel=${CHANNEL:-edge}"
    echo "policy=manual"
  } > "$tmp"
  chmod 0644 "$tmp"
  mv -n "$tmp" "$REGISTRY_PATH"
  rm -f "$tmp"
  REGISTRY_NOTE="written"
}

# setup-sysop NAME as the site user, after the health check passed. Sets CLAIM_URL to
# the full https://DOMAIN/claim?... link. On a site that already has accounts it
# does what setup-sysop does there and says so.
run_setup_sysop() {
  local out rc path
  CLAIM_URL=""
  if [ -s "$LZ/auth/users" ]; then
    echo "==> this site already has accounts. setup-sysop makes '$SYSOP' an operator here too"
    echo "    and issues a new single-use link; if '$SYSOP' already exists, their password is"
    echo "    cleared until they follow it."
  else
    echo "==> setup-sysop for '$SYSOP' (as $U)"
  fi
  set +e
  out="$(sudo -u "$U" perl "$DOM/tools/lazysite-users.pl" --docroot "$DOC" setup-sysop --user "$SYSOP" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out"
  if [ "$rc" != 0 ]; then
    echo "ERROR: setup-sysop for '$SYSOP' failed (exit $rc). The site is deployed; run it by hand:" >&2
    echo "  sudo -u $U perl $DOM/tools/lazysite-users.pl --docroot $DOC setup-sysop --user $SYSOP" >&2
    return 1
  fi
  path="$(printf '%s\n' "$out" | grep -o '/claim?[^[:space:]]*' | head -1 || true)"
  [ -n "$path" ] && CLAIM_URL="https://$DOMAIN$path"
  return 0
}

# One summary at the end: where the site is, how to get in, what was registered, and
# how to probe the front end.
print_summary() {
  local reg
  echo
  echo "==> $DOMAIN is deployed"
  echo "    site:      https://$DOMAIN/"
  echo "    manager:   https://$DOMAIN/manager/"
  if [ -n "$SYSOP" ] && [ -n "${CLAIM_URL:-}" ]; then
    echo "    claim:     $CLAIM_URL"
    echo "               (single-use link for '$SYSOP' to set their own password)"
  elif [ -n "$SYSOP" ]; then
    echo "    claim:     none - setup-sysop for '$SYSOP' did not finish (see above)"
  else
    echo "    claim:     none - no sysop yet; rerun with:  $0 $U $DOMAIN${STAGE_ARG:+ $STAGE_ARG} --sysop NAME"
  fi
  reg="${LAZYSITE_REGISTRY_DIR:-/etc/lazysite/sites.d}/$DOMAIN"
  if [ -n "${REGISTRY_NOTE:-}" ]; then
    echo "    registry:  $reg ($REGISTRY_NOTE)"
  elif [ -e "$reg" ]; then
    echo "    registry:  $reg (present, unchanged: only a first-time deploy writes it)"
  else
    echo "    registry:  none for this site (only a first-time deploy writes one)"
  fi
  echo "    probe:     curl -sI https://$DOMAIN/ | grep -i x-lazysite-front        # X-Lazysite-Front: hestia-proxy/acl"
  echo "               grep -n X-Forwarded-For $HESTIA/data/templates/web/nginx/lazysite-proxy.*tpl   # trusted_proxies: the front end must overwrite it"
}
# n807: functions end

# Update-channel pre-check, BEFORE we touch anything. If this site is on the
# 'stable' channel and the build is 'edge', the upgrade will be skipped - so bail
# now, before applying the template or normalising ownership. A skip MUST be a true
# no-op: doing the pre-install chown but then exiting on the skip (before the
# corrective permission pass) left skipped sites half-configured and 500ing.
# Read-only (lazysite.conf + manifest); run as root so it can always read them.
FORCE_ARGS=()
[ "${LAZYSITE_FORCE_SECURITY:-}" = 1 ] && FORCE_ARGS=(--force-security)
set +e
perl "$STAGE/install.pl" --channel-check --docroot "$DOC" "${FORCE_ARGS[@]}"
CC=$?
set -e
# SM1307: install.pl refuses --force-security (exit 2) for a payload that does
# not declare security_critical. Nothing has been touched; stop here.
if [ "${#FORCE_ARGS[@]}" -gt 0 ] && [ "$CC" != 0 ] && [ "$CC" != 3 ]; then
  echo "==> --force-security refused by install.pl (exit $CC). Nothing touched." >&2
  exit 2
fi
if [ "$CC" = 3 ]; then
  echo "==> upgrade SKIPPED: stable channel, edge build. Nothing touched."
  exit 4
fi

# Apply the web template on FIRST-TIME setup only. An upgrade (the site already
# has a lazysite install marker) must NOT touch the Hestia web template - that
# would change Hestia state, force a vhost rebuild, and re-assert lazysite-app on
# a domain whose template was deliberately changed (e.g. reverted to keep an
# original static/SSI/PHP site working). Set LAZYSITE_APPLY_TEMPLATE=1 to force.
STATE_FILE="$LZ/.install-state.json"
if [ -n "${LAZYSITE_APPLY_TEMPLATE:-}" ] || [ ! -f "$STATE_FILE" ]; then
  echo "==> applying lazysite-app web template (first-time setup)"
  "$HESTIA/bin/v-change-web-domain-tpl" "$U" "$DOMAIN" lazysite-app yes
  apply_proxy_template
else
  echo "==> existing lazysite install - leaving the Hestia web template unchanged"
  echo "    (set LAZYSITE_APPLY_TEMPLATE=1 to re-apply lazysite-app + rebuild the vhost)"
fi

# A previous install.pl run directly as root can leave the install targets owned by
# root, which the user-run install.pl below then cannot overwrite ("Permission
# denied", failed upgrade). This script runs as root, so make the domain user own
# everything install.pl writes BEFORE running it: the docroot, the cgi-bin, and the
# sibling lib/ extensions/ tools/ trees (DOCROOT/../{lib,extensions,tools}).
echo "==> normalising ownership to $U:www-data (so the user-run install can write)"
# SM1142 (R4): extensions/ is made HERE, before the user-run install, on every
# run - an existing site never has the web template re-applied, and the 0551
# domain root stops the site user creating it, so without this the upgrade that
# moves a site to extensions/ could not.
mkdir -p "$DOM/extensions"
# A moved engine tree is written by install.pl too, so it is on the list.
for tgt in "$DOC" "$LZ" "$CGI" "$DOM/lib" "$DOM/extensions" "$DOM/tools"; do
  [ -e "$tgt" ] && chown -R "$U":www-data "$tgt" 2>/dev/null || true
done
# old-name: begin (SM1142, the deploy names the directory the upgrade empties)
# The old directory, which install.pl's extensions-rename moves the files out of:
# the site user must own it to move them, and cannot remove it from the 0551
# domain root afterwards - that is done below, once the install has run.
OLD_EXT="$DOM/plugins"
[ -d "$OLD_EXT" ] && chown -R "$U":www-data "$OLD_EXT" 2>/dev/null || true
# old-name: end

# SM892: DECLARE WHICH OF THE TWO THIS IS. install.pl no longer infers it, and
# this script already knows the answer - the state file it read above is the
# same fact the installer used to read for itself. So the decision is made once,
# here, by the script that has the context, and passed on.
if [ -f "$STATE_FILE" ]; then
  MODE=upgrade
else
  MODE=provision
fi

echo "==> install.pl --mode $MODE (as $U)"
# SM1220 (#356): install.pl's own health check is left out (--health-check-by-caller). As
# $U it cannot read the web server group's private store, so every deploy carried
# four "could not read ... Permission denied" warnings; the final check below runs
# as root, after the permission pass, and is the deploy's one verdict.
set +e
# SM1285 (ruling 33): a new site gets no starter pages unless LAZYSITE_STARTER=1
# asks; install.pl's default, so this only passes the opt-in on.
STARTER_FLAG=
if [ "$MODE" = provision ] && [ "${LAZYSITE_STARTER:-}" = 1 ]; then
  STARTER_FLAG=--starter
fi
sudo -u "$U" perl "$STAGE/install.pl" --mode "$MODE" --docroot "$DOC" --cgibin "$CGI" --health-check-by-caller "${FORCE_ARGS[@]}" $STARTER_FLAG
IRC=$?
set -e
# Exit 3 = the install was skipped by the site's update-channel policy (this site
# is 'stable' and the build is 'edge'). That is a deliberate no-op, not a failure:
# report it and stop here (no files changed, so the verify below would wrongly
# flag a mismatch against the new manifest).
if [ "$IRC" = 3 ]; then
  echo "==> upgrade SKIPPED: this site is on the 'stable' update channel and this"
  echo "    release is an 'edge' build. Nothing changed (logged in the site audit)."
  exit 4          # distinct code so the batch updater can report skips separately
elif [ "$IRC" = 4 ]; then
  # Q16f: install.pl's 4 is "installed, and the site is NOT serviceable" (SM933)
  # - not this script's 4, which is the channel skip. This passed it straight
  # through (`exit "$IRC"` below), so the batch updater read a site that had
  # upgraded and failed its health check as "skipped (channel)": on the 0.15.4
  # edge rollout, 0 failed, and the watcher printed "deployed" with no findings.
  #
  # The files ARE installed, so the rest of this script still runs: the
  # permission pass and the check's --fix below are what make a Hestia site
  # serviceable, and stopping here left it half-configured. The verdict is the
  # final check's, on the tree as it then is: exit 5 if it still fails.
  INSTALL_UNSERVICEABLE=1
  # SM1205: A PROGRESS LINE, NOT A FINDING. install.pl's check ran BEFORE the
  # permission pass and the repair, so its 4 is not this deploy's verdict; the
  # batch updater's findings report keys on lines that begin WARN, and reported
  # this one (cut to its first line) on every site whose final check then passed.
  # One line, no level marker; the final check below says what became of it.
  echo "==> install.pl's own health check named a failure before the permission pass and the repair (exit 4); the final check below decides"
elif [ "$IRC" != 0 ]; then
  echo "ERROR: install failed (exit $IRC)" >&2
  exit "$IRC"
fi

# SM1142: the old directory, emptied by the install's extensions-rename. Only
# when empty: a file left there is one the step could not move, and the
# install's summary named it.
if [ -d "$OLD_EXT" ]; then
  if rmdir "$OLD_EXT" 2>/dev/null; then
    echo "==> removed the emptied $OLD_EXT (SM1142)"
  else
    echo "==> $OLD_EXT is not empty - left in place; nothing reads it (see the install summary above)"
  fi
fi

# Verify the installed code actually matches the release before trusting the
# stamped version: catches a partial/stale deploy (the "version reports X but the
# running code is Y" gap) instead of letting it pass silently.
echo "==> verifying installed code matches the release manifest"
if ! sudo -u "$U" perl "$STAGE/install.pl" --verify --docroot "$DOC" --cgibin "$CGI"; then
  echo "ERROR: post-deploy verification FAILED - installed code does not match the" >&2
  echo "       release, so the reported version would not reflect the running code." >&2
  echo "       Check permissions / a stale cgi-bin copy, then re-run the deploy." >&2
  exit 1
fi

# n807: a first-time deploy finishes a working site: its address, its channel, its
# registry entry. Before the permission pass, so the pass covers what they wrote.
if [ "$MODE" = provision ]; then
  set_site_url
  set_site_channel
  write_registry
fi

echo "==> permissions (CGI runs as www-data)"
# The compiled-template cache (lazysite/cache/tt) is regenerated on demand and
# mirrors absolute paths in deeply-nested directories; on a long-running site it
# is by far the slowest part of the sweep below. Drop it first so the permission
# pass stays fast (the next render rebuilds it with the right ownership).
rm -rf "$LZ/cache/tt" 2>/dev/null || true
# -RP: recurse without following symlinks (the cgi-bin links live outside $DOC,
# but be explicit). Batched -exec (chmod once per many paths, not once per file)
# - a per-file sweep over a large docroot takes many minutes and looks like a hang.
chown -RP "$U":www-data "$DOC"
find "$DOC" -type d -exec chmod 2775 {} +
find "$DOC" -type f -exec chmod 664  {} +
# A moved engine tree is not under $DOC, so it gets the same pass on its own:
# the CGI writes it exactly as it wrote the tree inside the docroot.
if [ "$LZ" = "$DOC-lazysite" ]; then
  chown -RP "$U":www-data "$LZ"
  find "$LZ" -type d -exec chmod 2775 {} +
  find "$LZ" -type f -exec chmod 664  {} +
fi
echo "    permissions set"
[ -d "$LZ/auth" ]  && chmod 2770 "$LZ/auth"
[ -d "$LZ/forms" ] && chmod 2770 "$LZ/forms"
# Secrets must not be world-readable (the blanket 664 above would expose them);
# 660 keeps them readable by the www-data group only.
for sec in auth/.secret forms/.secret manager/.csrf-secret \
           auth/oauth.json auth/user-settings.json; do
  [ -f "$LZ/$sec" ] && chmod 660 "$LZ/$sec"
done

# Optional: reload nginx after an upgrade. nginx serves the static manager assets
# (manager.css, cm/*) directly and, IF open_file_cache is enabled, can briefly
# serve a stale size for a just-rewritten file until the cache entry expires
# (open_file_cache_valid, default 60s). open_file_cache is off by default in
# nginx and self-heals when on, so this is opt-in, not the norm - the ?v=<version>
# cache-buster on the asset URLs already handles the browser side. Enable with
# LAZYSITE_RELOAD_NGINX=1 only if your nginx has open_file_cache on and you don't
# want to wait out its validity window.
if [ -n "${LAZYSITE_RELOAD_NGINX:-}" ] && command -v systemctl >/dev/null 2>&1; then
  echo "==> reloading nginx (LAZYSITE_RELOAD_NGINX set)"
  systemctl reload nginx 2>/dev/null \
    || systemctl reload-or-restart nginx 2>/dev/null \
    || echo "  (could not reload nginx automatically - run: systemctl reload nginx)"
fi

# index.html is handled by the template hook (install-hestia.sh): it clears only
# an index.html that was rendered from a PRE-EXISTING index.md - never real
# content - so lazysite can overlay an existing static site safely. We do NOT
# delete index.html here.
echo
echo "Deployed lazysite to $DOMAIN."
if [ -f "$DOC/index.html" ] && [ -f "$DOC/index.md" ]; then
  echo "Note: the homepage ('/') must route through the processor so the manager"
  echo "bar shows on it. The current lazysite web template does this (index.html"
  echo "is no longer a DirectoryIndex). If '/' shows no manager bar while other"
  echo "pages do, this vhost is on an OLDER template - re-apply it:"
  echo "    v-rebuild-web-domain $U $DOMAIN"
  # SM1236: a rebuild resets the docroot permissions (SM270); the repair puts them back.
  echo "    $LZS_CLI repair --domain $DOMAIN"
fi
# First-run sentinel: the group-settings store exists once setup-manager has
# run. (The old sentinel grepped the conf for manager_groups:, which SM138
# retired in 0.6.5 - it never matched again, so setup-manager re-ran on every
# deploy; harmless because it self-heals, but wrong.)
if [ ! -f "$LZ/auth/groups-settings.json" ] && [ -z "$SYSOP" ]; then
  # SM864: THIS USED TO RUN `setup-manager`, WHICH SM659 DELETED WITH NO ALIAS.
  #
  # The tool answered "unknown command" and exited 2, correctly - and this script
  # sets no -e and never looked at the status, so a fresh install announced
  # "first-run manager setup", created nothing, and carried on. The sentinel
  # below was never written either, so every later deploy repeated it. SM659
  # updated INSTALL-RUNBOOK.md and missed this file; the runbook being right is
  # what hid it.
  #
  # IT DOES NOT RUN A BOOTSTRAP AT ALL NOW, deliberately. setup-sysop REQUIRES a
  # username, because SM659 established that a default account called `manager`
  # is a shared role login and the audit trail then says `manager` did
  # everything. A deploy cannot know who the first person is, and inventing a
  # name is the thing that was removed. Deployment and first user are separate
  # steps: a site with no accounts is a coherent state, not a half-built one.
  #
  # So this SAYS SO, and prints the command. Naming it here is the whole fix: the
  # previous version's fault was not that it failed, but that it claimed to have
  # done something.
  echo "==> no accounts on this site yet - that is expected on a first deploy"
  echo "    Create the first sysop when the person is ready to collect their link:"
  echo "      sudo -u $U perl $DOM/tools/lazysite-users.pl \\"
  echo "           --docroot $DOC setup-sysop --user <name>"
  echo "    It issues a single-use link for them to set their own password, so no"
  echo "    password is chosen for them or sent to them. There is no default login."
  echo "    Or rerun this deploy with --sysop NAME, which does the same and prints the link:"
  echo "      $0 $U $DOMAIN${STAGE_ARG:+ $STAGE_ARG} --sysop <name>"
fi

# SM757: THE PERSISTENT RUNTIME, PROVISIONED HERE, EVERY TIME. This script is the
# tarball flow's root context - the deb flow has lazysite-hestia-domain --daemon
# for the same job - so the host half of the daemon's two switches is done on
# every deploy and upgrade, automatically, and never by hand:
#   - /etc/lazysite/daemon/<domain>.conf names the docroot, the Hestia user and
#     ENGINE=<domain root>, so the runtime runs the SITE's own tools/ and lib/
#     (a tarball host has no /usr/share/lazysite);
#   - the templated unit and its timer are installed from STAGE into
#     /etc/systemd/system (refreshed when the release changed them);
#   - the TIMER is enabled: it starts the service every five minutes while the
#     service is not running, so a sysop enabling the extension in the manager -
#     which has no root - is picked up within five minutes;
#   - a runtime that is RUNNING is restarted, so an upgrade takes effect the way
#     a pool restart does, without anybody remembering to.
# The extension stays the site's switch: with it disabled the service exits 0 in
# well under a second and the timer tries again in five minutes. Nothing here
# writes into the site tree.
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  echo "==> persistent runtime (SM757): conf, unit, timer"
  DAEMON_ETC=/etc/lazysite/daemon
  mkdir -p "$DAEMON_ETC"
  DCONF="$DAEMON_ETC/$DOMAIN.conf"
  DTMP="$DCONF.tmp.$$"
  # SM760: THE RUNTIME RUNS AS THE UNIX USER THE REQUEST PATH WRITES AS - the
  # two share one write plane (the CGI writes the auth stores the runtime
  # reads; the runtime writes the pid, state and run records Status reads),
  # and a 0660 file owned by one is closed to the other. On this flow the CGI
  # runs as www-data (see the permissions pass above); a site served by the
  # FastCGI pool runs as the pool's USER= instead. The first version wrote the
  # panel user here, and the runtime's first real run refused every job for a
  # capability its account held: www-data had rewritten groups-settings.json
  # and the panel user could not open it.
  RUNTIME_USER="${LAZYSITE_CGI_USER:-www-data}"
  POOL_CONF="/etc/lazysite/pools/$DOMAIN.conf"
  if [ -f "$POOL_CONF" ]; then
    POOL_USER=$(sed -n 's/^USER=//p' "$POOL_CONF" | head -1)
    [ -n "$POOL_USER" ] && RUNTIME_USER="$POOL_USER"
  fi
  {
    echo "# lazysite persistent runtime for $DOMAIN - written by lazysite-hestia-deploy.sh"
    echo "# (tarball flow) on every deploy; consumed by lazysited@.service."
    echo "DOCROOT=$DOC"
    echo "USER=$RUNTIME_USER"
    echo "ENGINE=$DOM"
  } > "$DTMP"
  mv -f "$DTMP" "$DCONF"
  UNITS_CHANGED=0
  for unit in lazysited@.service lazysited@.timer; do
    src="$STAGE/installers/systemd/$unit"
    dst=/etc/systemd/system/$unit
    if [ -f "$src" ] && ! cmp -s "$src" "$dst"; then
      install -m 0644 "$src" "$dst"
      UNITS_CHANGED=1
    fi
  done
  if [ "$UNITS_CHANGED" = 1 ]; then systemctl daemon-reload; fi
  systemctl enable --now "lazysited@$DOMAIN.timer" >/dev/null 2>&1 \
    || echo "  (could not enable lazysited@$DOMAIN.timer - run: systemctl enable --now lazysited@$DOMAIN.timer)"
  if systemctl is-active --quiet "lazysited@$DOMAIN.service"; then
    systemctl restart "lazysited@$DOMAIN.service" \
      && echo "    runtime restarted on the new release" \
      || echo "  (could not restart lazysited@$DOMAIN - run: systemctl restart lazysited@$DOMAIN)"
  else
    echo "    runtime provisioned; it starts within five minutes of the daemon extension being enabled"
  fi

  # N141-05: AND THE FastCGI POOL, WHICH NOTHING RESTARTED.
  #
  # A pooled worker is a long-lived process holding the engine it loaded at
  # start. An upgrade replaces the files on disk and the worker goes on serving
  # the OLD CODE until somebody restarts it - and until today the only place
  # that restart appeared was INSTALL-RUNBOOK.md:177, as a sentence telling a
  # human to remember. The comment above this block says the runtime is
  # restarted "the way a pool restart does, without anybody remembering to",
  # which reads as an assumption that the pool was already handled. It was not.
  #
  # Found from the outside: xisl.com and dhcf.eu reported `generator lazysite
  # 0.13.13` on a 0.14.0 engine, including on a freshly rendered 404 for a path
  # that had never been requested - which rules out the page cache. The version
  # was not being misreported; it was HONEST. Those pages really were rendered
  # by 0.13.13, because that is the code the worker was still running.
  #
  # Two consequences, and the second is the one that bites later: the site is
  # not running the release the operator was told it is running, and
  # `?v=` on the injected assets is pinned to the old number, so the cache-buster
  # that exists to force a refetch stops moving at exactly the upgrade it is for.
  #
  # Guarded the same way as the runtime above - restarted only if it is actually
  # running, so a site that does not use the pool is untouched and silent.
  if systemctl list-unit-files "lazysite@*.service" >/dev/null 2>&1 \
     && systemctl is-active --quiet "lazysite@$DOMAIN.service"; then
    systemctl restart "lazysite@$DOMAIN.service" \
      && echo "    FastCGI pool restarted on the new release" \
      || echo "  (could not restart lazysite@$DOMAIN - run: systemctl restart lazysite@$DOMAIN)"
  fi
else
  echo "==> persistent runtime: no systemd on this host - not provisioned (the daemon extension will report it)"
fi

echo "==> verifying install (permissions + health, auto-repair)"
# Run as root with --fix so it can repair both modes and ownership if anything is
# still off (the user asked: when run as root, the deploy should work the ownership
# out itself).
#
# Q16f: ITS VERDICT IS THIS SCRIPT'S. A failure left after the repair was an
# echo and exit 0, so the batch updater counted the site "updated". The check
# exits non-zero only on a FAIL left in the post-fix tree - SM933's "not
# serviceable" - and that is exit 5 here, distinct from the channel skip (4) and
# a failed install (anything else), so the updater reports it as a site that
# needs a human.
set +e
perl "$DOM/tools/lazysite-check.pl" --docroot "$DOC" --cgibin "$CGI" --fix
CHK=$?
set -e
if [ "$CHK" != 0 ]; then
  echo "NOT SERVICEABLE: $DOMAIN installed, and its health check still names a failure" >&2
  echo "  after the repair (see above). Run: ${LZS_CLI:-lazysite} check --domain $DOMAIN" >&2
  exit 5
fi
if [ "${INSTALL_UNSERVICEABLE:-0}" = 1 ]; then
  echo "==> the install-time health check failure was cleared by the permission pass and the repair; the final check passes"
fi

# n807: the first operator, once the site is known to be serviceable.
SYSOP_RC=0
if [ -n "$SYSOP" ]; then
  run_setup_sysop || SYSOP_RC=1
fi
print_summary
exit "$SYSOP_RC"
