#!/usr/bin/perl
# install.pl - lazysite installer (D021c)
#
# Upgrade-safe installer driven by release-manifest.json. Reads
# release-manifest.json at the tarball root, tracks installed
# state in {DOCROOT}/lazysite/.install-state.json, and makes
# upgrade decisions per file based on the classification bucket:
#
#
#   code: always overwritten on upgrade
#   anything else (seed and friends): overwritten only if the
#         on-disk SHA matches the state file - i.e. the operator
#         has not edited it. Only `code` is tested by name.
#
# Runtime directories come from the manifest's runtime_paths
# array. Some install steps are not manifest-expressible and stay
# imperative (cgi-bin symlinks for plugin endpoints, auth
# users/groups seed, nav.conf seed, lazysite.conf conditional
# write, SGID on lazysite/).
#
# Restore via --restore extracts a backup tarball produced on a
# prior upgrade.
#
# Core-only Perl; no CPAN deps. Shells out to `tar` for backup
# creation and extraction.

use strict;
use warnings;
use File::Copy     ();
use File::Path     qw(make_path remove_tree);
use File::Find     ();
use File::Basename qw(basename dirname);
use File::Temp     qw(tempdir);
use Digest::SHA    ();
use JSON::PP       ();
use POSIX          qw(strftime);
use Getopt::Long   ();
use Cwd            qw(abs_path);
use Fcntl          qw(O_WRONLY O_APPEND O_CREAT O_EXCL);

my $STAGE_DIR = abs_path( dirname($0) );

# The channel ladder: a build's channel declares its maturity, a site's
# update_channel is the MINIMUM maturity it accepts. edge = every release
# (early testing), beta = bedded-in candidates, stable = certified customer
# rollout. Keep in sync with tools/build-manifest.pl and the CLI validators
# (the installer does not load the lib). Initialised here, ahead of the
# top-level option blocks (--channel-check runs before the sub definitions'
# region is reached at runtime).
# 'certified' (2026-08-20, ADR 0010): above stable - a stable build whose
# compliance records have been WALKED (signed declaration, restore rehearsal,
# pentest posture). The conformity gates that used to block a stable cut
# attach there instead, so stable ships supported software and certification
# is a deliberate act rather than a blocked cut.
our %CHANNEL_RANK = ( edge => 0, beta => 1, stable => 2, certified => 3, all => 0 );

# SM356: `all` is spelled out rather than reached through a `// 0` fallback. It
# meant the same thing before - and it meant it by ACCIDENT, because an
# unrecognised value fell to the same 0. A rung that is only ever reached by
# failing to recognise something cannot be told apart from a typo.
our $CHANNEL_DEFAULT = 'stable';

# ---------- arg parse ----------

my %opt = (
    docroot      => '',
    cgibin       => '',
    domain       => '',
    theme        => '',
    help         => 0,
    restore      => 0,
    backup       => '',
    list_backups => 0,
    dry_run      => 0,
);

sub usage {
    my ($rc) = @_;
    print <<'USAGE';
Usage: install.pl --docroot PATH --cgibin PATH [options]

Install or upgrade lazysite in-place. On first run, creates a
fresh installation from the shipped manifest. On subsequent
runs, upgrades while preserving operator-edited content (pages,
custom docs) and overwriting project-owned code.

Required (for install/upgrade):
  --docroot PATH      Path to web document root
  --cgibin  PATH      Path to cgi-bin directory

Optional:
  --domain  NAME      Domain name for lazysite.conf site_url
                      (used only when seeding a new lazysite.conf)
  --dry-run           Compute the plan without executing any
                      filesystem changes. Useful before upgrade.
  --force             Upgrade even if the site's update channel would skip this
                      release (e.g. a 'stable' site taking an 'edge' build). The
                      override is recorded in the audit log.
  --channel edge|beta|stable|certified
                      Set the site's update channel (update_channel in
                      lazysite.conf) and exit - no install. The ladder is
                      edge < beta < stable < certified: a site accepts builds
                      at its own maturity or above (beta takes beta and up;
                      stable takes stable and up; edge takes everything). An
                      unrecognised value is treated as 'stable' and reported.
                      Loop over your docroots to set a whole fleet.
  --policy auto|manual
                      Set the site's update policy (update_policy in
                      lazysite.conf) and exit - no install. 'auto' lets
                      `lazysite upgrade --all` (cron-driven fleet upgrades)
                      touch this site; 'manual' (the default) leaves it to
                      the operator.
  --restore-full FILE Restore a full-system backup (manager "full" backup) into
                      --docroot, optionally rewriting the site domain with
                      --domain NAME. The temp -> final domain migration path.
  --help              Show this help

Maintenance modes:
  --list-backups      List available backups at
                      {docroot}/lazysite/backups/
  --restore           Restore the most recent backup
  --restore --backup PATH
                      Restore a specific backup tarball
  --verify            Is the code INSTALLED at --docroot/--cgibin actually this
                      payload's version? Reports the gap and exits non-zero if
                      it is not. Needs --docroot and --cgibin; changes nothing.
  --channel-check     Would this upgrade be SKIPPED by the site's update
                      channel? Exit 3 if yes, 0 otherwise - so a deploy can
                      bail BEFORE touching the site. Needs --docroot; reads
                      lazysite.conf and the manifest only.

Example:
  install.pl --docroot /var/www/html --cgibin /usr/lib/cgi-bin
  install.pl --docroot /var/www/html --cgibin /usr/lib/cgi-bin --domain example.com
  install.pl --docroot /var/www/html --cgibin /usr/lib/cgi-bin --dry-run

Upgrade notes:
  Seed files you have edited (pages, docs, forms config) are
  preserved across upgrades. Code files are always refreshed.
  Pre-upgrade backups accumulate under
  {docroot}/lazysite/backups/ per backup_retention
  (lazysite.conf; default 3).
USAGE
    exit( $rc // 0 );
}

# A mistake in the INVOCATION. Named after the program, and exit 2 - the code
# every other lazysite tool uses for "you typed it wrong", where a die would
# have exited 255 and told the operator perl had aborted.
sub _usage_error {
    my ($msg) = @_;
    print {*STDERR} "install.pl: $msg\n";
    exit 2;
}

# No args = help (matches install.sh behaviour)
usage(0) unless @ARGV;

Getopt::Long::Configure( 'no_ignore_case', 'bundling_override' );
Getopt::Long::GetOptions(
    'docroot=s'      => \$opt{docroot},
    'cgibin=s'       => \$opt{cgibin},
    'domain=s'       => \$opt{domain},
    'theme=s'        => \$opt{theme},
    'help'           => \$opt{help},
    'restore'        => \$opt{restore},
    'backup=s'       => \$opt{backup},
    'list-backups'   => \$opt{list_backups},
    'dry-run'        => \$opt{dry_run},
    'verify'         => \$opt{verify},
    'channel-check'  => \$opt{channel_check},
    'channel=s'      => \$opt{channel},
    'policy=s'       => \$opt{policy},
    'restore-full=s' => \$opt{restore_full},
    'force'          => \$opt{force},
) or do {
    print {*STDERR} "install.pl: unknown option (run --help for the option list)\n";
    exit 2;
};

usage(0) if $opt{help};

if ( $opt{theme} ) {
    warn "WARNING: --theme is no longer supported. install.pl "
        . "does not fetch remote themes. Upload themes via the "
        . "manager UI at /manager/themes.\n";
}

# --- mode dispatch ---

if ( $opt{list_backups} ) {
    _usage_error('--list-backups requires --docroot') unless $opt{docroot};
    exit cmd_list_backups( $opt{docroot} );
}

if ( $opt{restore} ) {
    _usage_error('--restore requires --docroot') unless $opt{docroot};
    exit cmd_restore( \%opt );
}

# --channel-check: would this upgrade be SKIPPED by the site's update channel?
# Exit 3 if yes (so the deploy can bail BEFORE touching the site), 0 otherwise.
# Reads only lazysite.conf + the manifest - no file changes, no ownership needed.
if ( $opt{channel_check} ) {
    _usage_error('--channel-check requires --docroot') unless $opt{docroot};
    my $manifest = load_manifest("$STAGE_DIR/release-manifest.json");
    my $state    = load_state( state_path( $opt{docroot} ) );
    # Only an upgrade (existing install at a different version) is gated.
    if ( $state && ( $state->{version} // '' ) ne ( $manifest->{version} // '' ) ) {
        my ( $site, $problem ) = read_update_channel( $opt{docroot} );
        my $rel = $manifest->{channel} || 'edge';
        warn "channel-check: $problem\n" if defined $problem;
        exit 3                           if channel_refuses( $site, $rel );
    }
    exit 0;
}

# --channel edge|beta|stable|certified: set the site's update_channel in lazysite.conf. A
# standalone maintenance op (no install) - pins a deployment to a channel, or
# moves it back, without hand-editing the conf. To set a whole fleet, loop it over
# your docroots (lazysite has no central site registry - the host knows the sites):
#   for d in /home/*/web/*/public_html; do install.pl --channel stable --docroot "$d"; done
if ( defined $opt{channel} ) {
    _usage_error('--channel requires --docroot') unless $opt{docroot};
    exit cmd_set_channel( $opt{docroot}, $opt{channel} );
}

# --policy auto|manual: set the site's update_policy in lazysite.conf (SM139). The
# same standalone maintenance-op shape as --channel. 'auto' opts the site in to
# cron-driven fleet upgrades (`lazysite upgrade --all`); 'manual' (the default
# when the key is absent) means only a deliberate per-site upgrade touches it.
if ( defined $opt{policy} ) {
    _usage_error('--policy requires --docroot') unless $opt{docroot};
    exit cmd_set_policy( $opt{docroot}, $opt{policy} );
}

# --restore-full: restore a full-system backup (from the manager's "full" backup)
# into a docroot, optionally rewriting the site domain - the temp-domain ->
# final-domain migration path. A system-user operation: the tarball carries the
# auth secrets, so this deliberately lives in the installer, not the manager UI.
if ( defined $opt{restore_full} ) {
    _usage_error('--restore-full requires --docroot') unless $opt{docroot};
    exit cmd_restore_full( $opt{docroot}, $opt{restore_full}, $opt{domain} );
}

# --verify: is the INSTALLED code actually this version? (the deploy-gap detector)
if ( $opt{verify} ) {
    _usage_error('--verify requires --docroot and --cgibin')
        unless $opt{docroot} && $opt{cgibin};
    $opt{docroot} = abs_path( $opt{docroot} ) // $opt{docroot};
    $opt{cgibin}  = abs_path( $opt{cgibin} )  // $opt{cgibin};
    exit cmd_verify( \%opt );
}

# Install / upgrade path.
_usage_error('--docroot is required') unless $opt{docroot};
_usage_error('--cgibin is required')  unless $opt{cgibin};

# Absolute paths to avoid surprises when cwd is not the install root.
$opt{docroot} = abs_path( $opt{docroot} ) // $opt{docroot};
$opt{cgibin}  = abs_path( $opt{cgibin} )  // $opt{cgibin};

exit cmd_install( \%opt );

# =========================================================
# ---------- install / upgrade command ----------
# =========================================================

# The site's update channel preference, read from lazysite.conf.
#
# SM356: THE DEFAULT FAILED OPEN, IN THREE DIFFERENT WAYS.
#
# This returned 'all' - accept every build, edge included - when the conf could
# not be read, when there was no update_channel line, and when the value was not
# recognised. The third is the dangerous one: `update_channel: stabel` did not
# fail, did not warn, and did not mean stable. It meant the MOST permissive
# setting available, silently, which is the opposite of what the operator typed.
#
# The reported symptom was that an edge rollout touched sites it was not for.
# The gate was working; the default was wrong.
#
# Now: a recognised value is honoured, and everything else falls to `stable` -
# the most restrictive rung, which is the safe direction for a control whose
# failure mode is installing a pre-release build on a customer site. An
# unrecognised value is ALSO reported, in the second return value, because a
# typo silently corrected to something safe is still a setting that does not do
# what it says.
#
# Returns ( channel, problem ) - problem is undef when the value was explicit
# and recognised.
sub read_update_channel {
    my ($docroot) = @_;
    my $conf = _conf_path($docroot);
    open my $fh, '<', $conf
        or return ( $CHANNEL_DEFAULT, "cannot read $conf" );
    while ( my $l = <$fh> ) {
        next unless $l =~ /^\s*update_channel\s*:\s*(\S+)/;
        close $fh;
        my $c = lc $1;
        return ( $c, undef ) if exists $CHANNEL_RANK{$c};
        return ( $CHANNEL_DEFAULT,
            "update_channel is '$c', which is not one of "
                . join( '/', sort keys %CHANNEL_RANK )
                . " - treating this site as '$CHANNEL_DEFAULT'" );
    }
    close $fh;
    return ( $CHANNEL_DEFAULT, undef );    # absent is a policy, not a fault
}

# Would the site's channel refuse this release? 'all' (and 'edge') accept
# everything; otherwise the release must sit at the site's rung or above.
sub channel_refuses {
    my ( $site_channel, $release_channel ) = @_;

    # SM356: an unrecognised rung FAILS CLOSED on both sides. These were `// 0`,
    # which is `edge`, which accepts everything - so any value neither side
    # recognised resolved to "install it". A comparison whose unknown case is
    # the permissive one is not a gate.
    my $need = $CHANNEL_RANK{ lc( $site_channel // '' ) };
    $need = $CHANNEL_RANK{$CHANNEL_DEFAULT} unless defined $need;

    # An unrecognised RELEASE channel is treated as the least mature, so a site
    # asking for stable does not accept a build whose maturity nobody can read.
    my $got = $CHANNEL_RANK{ lc( $release_channel // 'edge' ) };
    $got = 0 unless defined $got;

    return $got < $need ? 1 : 0;
}

# Shared appender for the installer's audit events. Same file and pipe format
# as Lazysite::Audit (the installer must not load the lib - keep the two in
# sync). Robust like the lib writer: creation is umask-proof (sysopen 0664 +
# chmod, so the web-server group - inherited via the setgid logs dir - can
# append later; the field defect was a 0644 install-created file silently
# locking every CGI audit write out forever), an owned file that lost its
# group-write bit is healed before appending, and a failed write warns to
# STDERR instead of vanishing. Never dies - auditing must not break a deploy.
sub audit_append {
    my ( $docroot, $act, $target, $detail ) = @_;
    my $logdir = lazysite_dir_for($docroot) . "/logs";
    unless ( -d $logdir || mkdir $logdir ) {
        warn "audit write failed ($act): cannot create $logdir: $!\n";
        return;
    }
    for ( $target, $detail ) { $_ = defined $_ ? "$_" : ''; s/[|\r\n]+/ /g }
    my $ts   = POSIX::strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime );
    my $file = "$logdir/audit.log";
    my @s    = stat $file;
    chmod 0664, $file if @s && !( $s[2] & 0020 ) && $s[4] == $>;
    my $fh;
    unless ( sysopen $fh, $file, O_WRONLY | O_APPEND | O_CREAT, 0664 ) {
        warn "audit write failed ($act): cannot append to $file: $!\n";
        return;
    }
    chmod 0664, $file unless @s;    # umask-proof the create
    my $line = "$ts | system | $act | $target |  | ok | install";
    $line .= " | $detail" if length $detail;
    print {$fh} "$line\n" or warn "audit write failed ($act): $!\n";
    close $fh;
    return;
}

# Replace one "key: value" line in the site's lazysite.conf (append when the key
# is absent). Atomic via temp + rename. Shared by --channel and --policy.
# Where a site keeps its lazysite.conf. Asked through lazysite_dir_for, never
# assembled by hand, because SM293 moved the engine tree on migrated sites.
sub _conf_path {
    my ($docroot) = @_;
    return lazysite_dir_for($docroot) . '/lazysite.conf';
}

# Every pre-upgrade backup in a site's backup directory, oldest first.
sub _backup_files {
    my ($dir) = @_;
    my @files = sort glob("$dir/lazysite-backup-*.tar.gz");
    return @files;
}

# How the install state records a file's digest.
sub _sha256_tag {
    my ($path) = @_;
    return 'sha256:' . sha256_of($path);
}

# THE conf-key writer for this file. Returns ( ok, reason ): 1 and undef on
# success, 0 and a sentence on failure, so a caller that wants to warn has the
# words and a caller that wants silence can drop them.
#
# The installer is core-Perl by design (ADR 0001) and cannot reach
# Lazysite::Manager::Common's writer, so it carries its own - one of them.
sub _write_conf_key {
    my ( $conf, $key, $value ) = @_;
    return ( 0, "No lazysite.conf at $conf - is this a lazysite docroot?" )
        unless -f $conf;
    open my $in, '<', $conf or return ( 0, "Cannot read $conf: $!" );
    my @lines = <$in>;
    close $in;

    my $found = 0;
    for my $l (@lines) {
        if ( $l =~ /^\s*\Q$key\E\s*:/ ) {
            $l     = "$key: $value\n";
            $found = 1;
            last;
        }
    }
    push @lines, "$key: $value\n" unless $found;

    # Preserve the original's mode and group across the atomic replace. The
    # temp file is born with the INVOKING user's umask and primary group, so
    # without this a site-user CLI run (e.g. a root-driven channel sweep via
    # sudo -u) silently replaced a siteuser:www-data 0664 conf with a
    # siteuser:siteuser 0644 one - and the manager (running as the web-server
    # user on a no-suexec host) could no longer save settings. chmod is always
    # ours to do (we own the temp); the chgrp is best-effort (only root or a
    # member of the target group may set it - lazysite check --fix repairs
    # anything left).
    my @orig_stat = stat $conf;
    my $tmp       = "$conf.tmp.$$";
    open my $out, '>', $tmp or return ( 0, "Cannot write $tmp: $!" );
    print {$out} @lines;
    close $out;
    if (@orig_stat) {
        chmod $orig_stat[2] & 07777, $tmp;
        # SM215: as root (a sudo-driven update), preserve the file's OWNER too -
        # not just the group - so an upgrade never leaves a root-owned conf the web
        # user cannot rewrite. Non-root: group only (owner chown would just fail).
        chown( ( $> == 0 ? $orig_stat[4] : -1 ), $orig_stat[5], $tmp );
    }
    unless ( rename $tmp, $conf ) {
        my $why = "Cannot replace $conf: $!";
        unlink $tmp;
        return ( 0, $why );
    }
    return ( 1, undef );
}

# The maintenance-op face of the writer: takes a DOCROOT, warns the reason, and
# answers in exit-status terms (0 = ok) because --channel and --policy return
# what it gives them straight out of the process.
sub set_conf_line {
    my ( $docroot, $key, $value ) = @_;
    my ( $ok, $why ) = _write_conf_key( _conf_path($docroot), $key, $value );
    return 0 if $ok;
    warn "$why\n";
    return 1;
}

# --channel: set update_channel in the site's lazysite.conf (replace the line if
# present, else append). Standalone maintenance op.
sub cmd_set_channel {
    my ( $docroot, $value ) = @_;
    $value = lc $value;
    unless ( exists $CHANNEL_RANK{$value} ) {
        warn "--channel must be 'edge', 'beta', 'stable' or 'certified' (got '$value')\n";
        return 2;
    }
    my $rc = set_conf_line( $docroot, 'update_channel', $value );
    return $rc if $rc;

    audit_channel_set( $docroot, $value );
    info("Update channel set to '$value' for $docroot");
    return 0;
}

# --policy: set update_policy in the site's lazysite.conf (SM139). 'auto' opts the
# site in to fleet-wide `lazysite upgrade --all`; 'manual' (the absent-key default)
# leaves upgrades to the operator. Standalone maintenance op, same shape as
# --channel.
sub cmd_set_policy {
    my ( $docroot, $value ) = @_;
    $value = lc $value;
    unless ( $value eq 'auto' || $value eq 'manual' ) {
        warn "--policy must be 'auto' or 'manual' (got '$value')\n";
        return 2;
    }
    my $rc = set_conf_line( $docroot, 'update_policy', $value );
    return $rc if $rc;

    audit_policy_set( $docroot, $value );
    info("Update policy set to '$value' for $docroot");
    return 0;
}

# Record a policy change (origin = install).
sub audit_policy_set {
    my ( $docroot, $value ) = @_;
    audit_append( $docroot, 'policy-set', "update_policy: $value" );
    return;
}

# Record a channel change (origin = install).
sub audit_channel_set {
    my ( $docroot, $value ) = @_;
    audit_append( $docroot, 'channel-set', "update_channel: $value" );
    return;
}

# --restore-full: extract a full-system backup into the docroot, optionally
# rewriting the site domain, and clear render caches so pages re-render. This is
# the temp -> final domain migration path (a system-user operation).
sub cmd_restore_full {
    my ( $docroot, $tarball, $domain ) = @_;
    $tarball = abs_path($tarball) // $tarball;
    die "Backup '$tarball' not found\n" unless -f $tarball;
    make_path($docroot)                 unless -d $docroot;
    $docroot = abs_path($docroot) // $docroot;

    info("Restoring full-system backup into $docroot");
    info("  from: $tarball");
    # SM268 H16: was missing --no-same-permissions, so as ROOT this restored
    # setuid bits straight out of the tarball. safe_tar_extract also vets the
    # member names for traversal before writing anything.
    my $rc = safe_tar_extract( $tarball, $docroot );
    die "tar extraction failed (rc=$rc)\n" if $rc != 0;

    my $conf = _conf_path($docroot);
    die "Restored tree has no lazysite/lazysite.conf - not a full backup?\n"
        unless -f $conf;

    if ( defined $domain && length $domain ) {
        my ($set_ok) = _write_conf_key( $conf, 'domain', $domain );
        warn "Could not set domain in $conf\n" unless $set_ok;
        info("Set site domain to: $domain");
    }

    # Drop generated HTML caches so pages re-render (new domain, fresh mtimes).
    my $cache = lazysite_dir_for($docroot) . "/cache";
    File::Path::remove_tree($cache) if -d $cache;

    audit_full_restore( $docroot, $tarball, $domain );
    info("Full restore complete. Check file ownership/permissions on the target host.");
    return 0;
}

# Record a full-system restore (origin = install).
sub audit_full_restore {
    my ( $docroot, $tarball, $domain ) = @_;
    ( my $base = $tarball ) =~ s{.*/}{};
    my $target = "full restore from $base"
        . ( ( defined $domain && length $domain ) ? " -> domain $domain" : '' );
    audit_append( $docroot, 'full-restore', $target );
    return;
}

# What the channel gate needs to decide: the site's rung, the release's rung,
# and whether the first refuses the second. Reports an unrecognised conf value
# on the way past (SM356), which is why it is one call and not three.
sub channel_verdict {
    my ( $docroot, $manifest ) = @_;
    my ( $site,    $problem )  = read_update_channel($docroot);
    my $rel = $manifest->{channel} || 'edge';
    info("NOTE: $problem") if defined $problem;
    return ( $site, $rel, channel_refuses( $site, $rel ) );
}

# The channel gate's two outcomes, which wrote the same sentence: an upgrade the
# site's channel refused ('upgrade-skipped') and one --force pushed through
# anyway ('upgrade-forced', which adds the override clause).
sub audit_channel_outcome {
    my ( $docroot, $act, $from, $to, $rel_channel, $site_channel, $extra ) = @_;
    audit_append( $docroot, $act,
        "$from -> $to (release channel: $rel_channel; site channel: "
            . ( $site_channel // 'stable' )
            . ( $extra        // '' ) . ")" );
    return;
}

sub audit_install_event {
    my ( $docroot, $mode, $from, $to, $detail ) = @_;
    my $act = $mode eq 'fresh' ? 'installed'
        : $mode eq 'upgrade' ? 'upgraded'
        :                      'reinstalled';
    my $target = ( $mode eq 'upgrade' && defined $from ) ? "$from -> $to" : $to;
    audit_append( $docroot, $act, $target, $detail );
    return;
}

sub cmd_install {
    my ($o) = @_;

    my $manifest = load_manifest("$STAGE_DIR/release-manifest.json");
    info("Installer: lazysite $manifest->{version}");

    my $state_path = state_path( $o->{docroot} );
    my $state      = load_state($state_path);

    my $mode;
    if ( !defined $state ) {
        $mode = 'fresh';
    }
    elsif ( $state->{version} eq $manifest->{version} ) {
        $mode = 'reinstall';
    }
    else {
        $mode = 'upgrade';
    }

    info("Mode: $mode");
    info("  docroot: $o->{docroot}");
    info("  cgibin:  $o->{cgibin}");
    if ( $mode ne 'fresh' ) {
        info("  from:    $state->{version}");
        info("  to:      $manifest->{version}");
    }

   # Upgrade channel policy: a site's update_channel is the minimum maturity it
   # accepts on the edge < beta < stable < certified ladder - a 'stable' site refuses beta
   # and edge UPGRADES, a 'beta' site refuses edge ones. This is how a
   # not-yet-bedded-in build is kept off customer sites. Fresh installs and
   # reinstalls are the operator's explicit choice and are never gated. The
   # skip is a clean no-op (exit 3, not an error) and is recorded in the
   # site's audit log.
    if ( $mode eq 'upgrade' && !$o->{force} ) {
        # SM356: a value nobody recognised used to become the most permissive
        # setting in silence. It now becomes the most restrictive one and SAYS
        # SO (channel_verdict reports it) - a typo corrected to something safe
        # is still a setting that does not do what the operator wrote.
        my ( $site_channel, $release_channel, $refuses )
            = channel_verdict( $o->{docroot}, $manifest );
        if ($refuses) {
            info( "Upgrade SKIPPED: this site is on the '$site_channel' update channel and "
                    . "$manifest->{version} is an '$release_channel' build. No changes made. "
                    . "Use --force to install it anyway." );
            audit_channel_outcome( $o->{docroot}, 'upgrade-skipped',
                $state->{version}, $manifest->{version}, $release_channel,
                $site_channel );
            return 3;
        }
    }
    elsif ( $mode eq 'upgrade' && $o->{force} ) {
        # --force: install regardless of the site's update channel (a deliberate
        # operator override for an out-of-channel build). Recorded in the audit log;
        # the normal upgrade event is still logged when the install completes.
        my ( $site, $rel, $refuses ) = channel_verdict( $o->{docroot}, $manifest );
        if ($refuses) {
            info( "--force: installing '$rel' build $manifest->{version} over the "
                    . "site's '$site' channel policy (operator override)." );
            audit_channel_outcome( $o->{docroot}, 'upgrade-forced',
                $state->{version}, $manifest->{version}, $rel, $site,
                '; --force override' );
        }
    }

    my %subs = placeholders( $o->{docroot}, $o->{cgibin} );

    # ---- plan ----
    my $plan = compute_plan( $manifest, $state, \%subs );
    if ( $o->{dry_run} ) {
        print_plan( $plan, $manifest, \%subs );
        info("--dry-run: no changes made.");
        return 0;
    }

    # ---- directory model ----
    # Must precede anything that creates a directory. Empty (older payload)
    # leaves install_file on its historical bare-make_path behaviour.
    load_install_dirs( $manifest, \%subs );

    # ---- runtime paths ----
    # SM246: BEFORE the backup, not after. lazysite/backups is a runtime path
    # the CGI writes (Manager::Backups saves snapshots through the manager), and
    # the backup step below used to create it first with a bare make_path - so
    # on an upgrade run as root it landed at the umask default, root-owned and
    # not group-writable, and the manager's own backup action then failed with a
    # permission error on a directory the installer had made. Creating the
    # declared paths first means the model's mode is the one that takes effect.
    # create_backup archives an explicit file list from the install state, so
    # this ordering cannot change what a backup contains.
    create_runtime_paths( $manifest->{runtime_paths} || [], \%subs, $mode );

    # ---- backup (upgrade or reinstall only) ----
    my $backup_path;
    if ( $mode ne 'fresh' ) {
        my $backup_dir = lazysite_dir_for( $o->{docroot} ) . "/backups";
        # Normally already created above from the model. Retained for a payload
        # whose manifest predates the declaration, which must install as before.
        make_path($backup_dir) unless -d $backup_dir;
        $backup_path = create_backup(
            $state, $backup_dir, $state_path, $manifest->{version},
        );
        info("Backup: $backup_path");
    }

    # ---- execute plan ----
    my ( $state_files, $plan_stats, $warnings ) = execute_plan($plan);

    # ---- imperative post-steps ----
    post_install_steps( $o, $manifest, \%subs, $state_files, $mode, $plan_stats );

    # ---- integrity check ----
    # The code we just installed must match the manifest, so the version we are
    # about to stamp truthfully reflects the RUNNING code (a partial deploy would
    # otherwise report the new version with stale code).
    my @verr = verify_code_files( $manifest, \%subs );
    if (@verr) {
        push @$warnings, "INTEGRITY: " . scalar(@verr)
            . " code file(s) do NOT match the manifest after install - the"
            . " reported version may not reflect the running code: "
            . join( '; ', @verr );
        info( "WARNING: post-install verification found "
                . scalar(@verr) . " code-file mismatch(es) - run --verify" );
    }

    # ---- invalidate rendered HTML (SM413) ----
    #
    # On an UPGRADE only: a fresh install has nothing rendered yet, and running
    # it there would report a number that means nothing. The pages re-render on
    # next request, so the cost is one render per page actually visited rather
    # than a rebuild of the whole site at upgrade time.
    if ( $mode eq 'upgrade' ) {
        my $dropped = invalidate_rendered_html( $o->{docroot} );
        info( "Invalidated $dropped rendered page(s) - they re-render on next"
                . " request, so the new build is what visitors get" )
            if $dropped;
    }

    # ---- write new state ----
    write_state( $state_path, $manifest->{version}, $state_files );

    # ---- audit the deploy (SM117) ----
    # A fresh install records the channel it was seeded with (post_install_steps
    # writes update_channel into a seeded lazysite.conf) in the install event's
    # detail field, matching the standalone --channel audit's wording - so a
    # provision-time channel choice is on the trail, not just later switches.
    audit_install_event(
        $o->{docroot}, $mode,
        ( defined $state ? $state->{version} : undef ),
        $manifest->{version},
        $mode eq 'fresh'
        ? 'update_channel: ' . ( read_update_channel( $o->{docroot} ) )[0]
        : undef
    );

    # ---- retention ----
    if ( $mode ne 'fresh' ) {
        my $retention = read_retention( $o->{docroot} );
        apply_retention( lazysite_dir_for( $o->{docroot} ) . "/backups", $retention );
    }

    # ---- summary ----
    print_summary( $mode, $manifest, $plan_stats, $backup_path, $warnings );
    print_dep_check();
    print_next_steps( $o->{docroot} );

    return 0;
}

# =========================================================
# ---------- plan computation ----------
# =========================================================

# Verify every code-bucket file is present at its install_to destination with the
# manifest's sha256 - i.e. the running code really IS this manifest's version.
# Returns a list of human-readable mismatches (empty = all good). Only code files
# (content/config are operator-editable and legitimately differ).
sub verify_code_files {
    my ( $manifest, $subs ) = @_;
    my @bad;
    for my $entry ( @{ $manifest->{files} } ) {
        next unless defined $entry->{install_to};
        next unless ( $entry->{bucket} // '' ) eq 'code';
        my $dest = resolve_placeholders( $entry->{install_to}, $subs );
        if ( !-f $dest ) { push @bad, "$dest (missing)"; next }
        my $disk = sha256_of($dest);
        push @bad, "$dest (disk=$disk manifest=$entry->{sha256})"
            if $disk ne ( $entry->{sha256} // '' );
    }
    return @bad;
}

# --verify: check the installed code against the shipped manifest. Exit 0 if the
# running code matches this version, 1 (with the mismatches) if it does not - so
# a deploy that left a stale .pl behind is caught instead of silently reporting
# the new version.
sub cmd_verify {
    my ($o)      = @_;
    my $manifest = load_manifest("$STAGE_DIR/release-manifest.json");
    my %subs     = placeholders( $o->{docroot}, $o->{cgibin} );
    my @bad      = verify_code_files( $manifest, \%subs );
    if (@bad) {
        print STDERR "VERIFY FAILED for $manifest->{version}: "
            . scalar(@bad) . " code file(s) do not match the manifest -\n";
        print STDERR "  $_\n" for @bad;
        print STDERR "The installed code is NOT $manifest->{version} "
            . "(incomplete deploy). Re-run the install.\n";
        return 1;
    }
    print "VERIFY OK: installed code matches the manifest for $manifest->{version}.\n";
    return 0;
}

sub compute_plan {
    my ( $manifest, $state, $subs ) = @_;

    my $stored_files = $state ? ( $state->{files} || {} ) : {};

    my @plan;
    my %manifest_installs;

    for my $entry ( @{ $manifest->{files} } ) {
        next unless defined $entry->{install_to};    # null = tarball-only

        my $dest   = resolve_placeholders( $entry->{install_to}, $subs );
        my $source = "$STAGE_DIR/$entry->{path}";
        $manifest_installs{$dest} = 1;

        if ( !exists $stored_files->{$dest} ) {
            # Not tracked in prior state. If the destination already EXISTS on disk
            # and this is an operator-editable (non-code) file, treat it as
            # pre-existing operator content and PRESERVE it - never clobber a
            # homepage/page created or edited outside the installer's state tracking
            # (e.g. seeded by a different install path, authored via the manager /
            # WebDAV, or written before this file became manifest-tracked). Only
            # write when the destination is absent, or it is a code file (which must
            # match the shipped version). Preserve records the shipped sha as the
            # baseline, so it stays edited-vs-shipped and preserved on later upgrades.
            if ( -e $dest && ( $entry->{bucket} // '' ) ne 'code' ) {
                push @plan, {
                    action => 'preserve',
                    dest   => $dest,
                    bucket => $entry->{bucket},
                    sha256 => $entry->{sha256},
                    path   => $entry->{path},
                };
                next;
            }
            push @plan, {
                action => 'install',
                source => $source,
                dest   => $dest,
                bucket => $entry->{bucket},
                sha256 => $entry->{sha256},
                path   => $entry->{path},
            };
            next;
        }

        my $stored  = $stored_files->{$dest} // '';
        my $on_disk = -f $dest ? _sha256_tag($dest) : '';

        if ( $on_disk eq $stored ) {
            # unedited
            push @plan, {
                action => 'overwrite',
                source => $source,
                dest   => $dest,
                bucket => $entry->{bucket},
                sha256 => $entry->{sha256},
                path   => $entry->{path},
            };
        }
        else {
            # user-edited
            if ( ( $entry->{bucket} // '' ) eq 'code' ) {
                push @plan, {
                    action     => 'overwrite',
                    source     => $source,
                    dest       => $dest,
                    bucket     => 'code',
                    sha256     => $entry->{sha256},
                    was_edited => 1,
                    path       => $entry->{path},
                };
            }
            else {
                push @plan, {
                    action => 'preserve',
                    dest   => $dest,
                    bucket => $entry->{bucket},
                    sha256 => $entry->{sha256},
                    path   => $entry->{path},
                };
            }
        }
    }

    # Files in the stored state but not in the new manifest.
    if ( keys %$stored_files ) {
        for my $dest ( sort keys %$stored_files ) {
            next if $manifest_installs{$dest};

            if ( !-e $dest ) {
                push @plan, { action => 'already_gone', dest => $dest };
                next;
            }

            my $stored  = $stored_files->{$dest};
            my $on_disk = _sha256_tag($dest);
            if ( $on_disk eq $stored ) {
                push @plan, { action => 'remove', dest => $dest };
            }
            else {
                push @plan, { action => 'orphan_warn', dest => $dest };
            }
        }
    }

    return \@plan;
}

sub print_plan {
    my ( $plan, $manifest, $subs ) = @_;
    my %by_action;
    push @{ $by_action{ $_->{action} } }, $_ for @$plan;
    print "\n--- Plan ---\n";
    for my $action (qw(install overwrite preserve remove orphan_warn already_gone)) {
        my $items = $by_action{$action} or next;
        my $count = scalar @$items;
        print "  $action: $count\n";
        if ( $action eq 'preserve' || $action eq 'orphan_warn' ) {
            print "    - $_->{dest}\n" for @$items;
        }
    }
    print "\nRuntime paths:\n";
    for my $rp ( @{ $manifest->{runtime_paths} || [] } ) {
        my $resolved = resolve_placeholders( $rp->{path}, $subs );
        print "  $rp->{mode} $resolved  ($rp->{purpose})\n";
    }
    print "\n";
}

# =========================================================
# ---------- plan execution ----------
# =========================================================

# SM413: invalidate rendered HTML, in one place, used by every path that
# changes the code under a site.
#
# THE ASYMMETRY THIS REMOVES: the rollback path already did this - "content at
# the pre-upgrade version may reference state that no longer matches" - and the
# UPGRADE path did not. So the installer already knew the rule and applied it
# in one direction only, which is the direction taken far less often.
#
# The field measured the cost: a homepage served a render produced under
# 0.10.13 through FOUR subsequent deployments, and was only corrected when an
# operator invalidated by hand. Because a cached page is regenerated when its
# SOURCE changes, and an upgrade changes no source, a page nobody edits keeps
# its pre-upgrade render for ever - including any head-contract or security
# header the new build introduced. The homepage is the page least likely to be
# edited and the first one an operator checks after an upgrade, so the failure
# presents as "the upgrade did not take".
#
# Only the rendered .html is dropped, never the whole cache directory: the
# per-host mirrors and other cache state have their own lifecycles, and this
# is a re-render trigger rather than a reset.
sub invalidate_rendered_html {
    my ($docroot) = @_;
    my $cache = lazysite_dir_for($docroot) . "/cache";
    return 0 unless -d $cache;
    my $n = 0;
    File::Find::find(
        { no_chdir => 1,
            wanted => sub {
                return unless -f $_ && /\.html$/;
                if   ( unlink $_ ) { $n++ }
                else               { warn "  warn: could not unlink $_: $!\n" }
            },
        },
        $cache,
    );
    return $n;
}

sub execute_plan {
    my ($plan) = @_;

    my %state_files;
    my %stats = (
        installed => 0,
        overwrote => 0,
        preserved => [],
        removed   => 0,
        orphaned  => [],
    );
    my @warnings;

    for my $step (@$plan) {
        my $a = $step->{action};

        if ( $a eq 'install' || $a eq 'overwrite' ) {
            my $ok = eval { install_file( $step->{source}, $step->{dest} ); 1 };
            if ( !$ok ) {
                my $err = $@; $err =~ s/\s+$//;
                # Code files (the app) are critical - fail. Content/seed files
                # are not: a page the owner (or a webdav partner) wrote may not
                # be writable by the installer - warn, leave it, carry on.
                die "$err\n" if ( $step->{bucket} // '' ) eq 'code';
                push @warnings, "skipped (not writable, left as-is): $step->{dest}";
                # Record the SHIPPED sha as the baseline so a future upgrade
                # treats it as edited-vs-shipped and keeps preserving it.
                $state_files{ $step->{dest} } =
                    defined $step->{sha256} ? "sha256:$step->{sha256}" : '';
                next;
            }
            $state_files{ $step->{dest} } = _sha256_tag( $step->{dest} );
            $a eq 'install' ? $stats{installed}++ : $stats{overwrote}++;
        }
        elsif ( $a eq 'preserve' ) {
            # Record the SHIPPED sha as the baseline (not the on-disk/user
            # version), so an edited file stays "edited vs shipped" and keeps
            # being preserved on future upgrades instead of being clobbered.
            $state_files{ $step->{dest} } =
                defined $step->{sha256} ? "sha256:$step->{sha256}" : _sha256_tag( $step->{dest} );
            push @{ $stats{preserved} }, $step->{dest};
        }
        elsif ( $a eq 'remove' ) {
            unlink $step->{dest}
                or warn "  warn: could not unlink $step->{dest}: $!\n";
            # Also remove any stale .html cache for .md sources.
            if ( $step->{dest} =~ /\.md$/ ) {
                ( my $cached = $step->{dest} ) =~ s/\.md$/.html/;
                unlink $cached if -f $cached;
                # SM110: and its per-alias-host copies (standalone installer -
                # inline rather than the Lazysite::Util helper).
                ( my $rel = $cached ) =~ s{^\Q$opt{docroot}\E/?}{};
                my $hosts = lazysite_dir_for( $opt{docroot} ) . "/cache/hosts";
                if ( length $rel && $rel !~ m{\.\.} && opendir( my $hd, $hosts ) ) {
                    for my $h ( readdir $hd ) {
                        next                    if $h =~ /^\./;
                        unlink "$hosts/$h/$rel" if -f "$hosts/$h/$rel";
                    }
                    closedir $hd;
                }
            }
            $stats{removed}++;
        }
        elsif ( $a eq 'already_gone' ) {
            # No-op, not in new state.
        }
        elsif ( $a eq 'orphan_warn' ) {
            push @{ $stats{orphaned} }, $step->{dest};
            push @warnings, "orphan (edited post-install, left in place): $step->{dest}";
        }
    }

    return ( \%state_files, \%stats, \@warnings );
}

# SM246: the declared mode for each directory the installer may create, resolved
# from the manifest once per run. Empty means the payload predates install_dirs,
# in which case install_file behaves exactly as it always did - an older tarball
# must install unchanged.
our %INSTALL_DIR_MODE;

# The resolved docroot for this run, so make_declared_path can tell "a directory
# the installer owns" from "a directory above the site" (SM268 03-F8) - the two
# need opposite advice.
our $INSTALL_DOCROOT = '';

sub load_install_dirs {
    my ( $manifest, $subs ) = @_;
    %INSTALL_DIR_MODE = ();
    $INSTALL_DOCROOT  = $subs->{DOCROOT} // '';
    for my $d ( @{ $manifest->{install_dirs} || [] } ) {
        $INSTALL_DIR_MODE{ resolve_placeholders( $d->{path}, $subs ) } = oct( $d->{mode} );
    }
    return scalar keys %INSTALL_DIR_MODE;
}

# Create a missing directory chain, giving EVERY level the mode the model
# declares for it.
#
# This is deliverable 1's fault. `make_path($dir)` with no mode uses
# 0777 & ~umask, which under a root umask of 022 is 0755 - no group write - and
# nothing corrected the docroot directories that are not in runtime_paths. The
# installer already solves this problem three times for FILES and never once for
# directories.
#
# Two properties worth being explicit about, because this is the class of change
# that caused the 0.6.5 outage:
#
#   * the mode is applied ONLY on creation. An existing directory is never
#     chmod'ed here, so an operator who tightened one keeps their choice and a
#     site whose ownership does not match the assumption cannot be broken by
#     this path.
#   * mkdir's mode argument is masked by the umask, so the mode is applied by an
#     explicit chmod afterwards - the same umask-proofing the file path uses.
#
# A single make_path with one mode would give every intermediate level the mode
# of the deepest one, which is wrong the moment two levels differ (creating
# lazysite/auth would make lazysite/ 2770). Hence the level-by-level walk.
sub make_declared_path {
    my ($dir) = @_;

    # SM268 H5: `-d` follows a link, so a symlinked intermediate directory was
    # accepted as "already there" and everything below it was written outside
    # the docroot - 39 files, in the reviewer's reproduction. Walk the existing
    # levels and refuse any that is a link before trusting the tree.
    {
        my $d = $dir;
        while ( length $d ) {
            _refuse_symlink( $d, 'create a directory' ) if -e $d || -l $d;
            my $parent = dirname($d);
            last if $parent eq $d;
            $d = $parent;
        }
    }

    return 1 if -d $dir;

    # No model (older payload): historical behaviour, unchanged.
    return make_path($dir) ? 1 : 0 unless %INSTALL_DIR_MODE;

    my @missing;
    my $d = $dir;
    while ( length $d && !-d $d ) {
        push @missing, $d;
        my $parent = dirname($d);
        last if $parent eq $d;
        $d = $parent;
    }

    for my $path ( reverse @missing ) {
        my $mode = $INSTALL_DIR_MODE{$path};
        # Refusing is the point. A directory created with no declared mode is
        # how this incident happened: it lands at the umask default, no consumer
        # claims it, and nothing reports it until a deploy exposes it. Shipping
        # a file into a new directory must therefore be a decision someone made
        # rather than a side effect nobody saw.
        # SM268 03-F8: say which of the two cases this is, because they need
        # opposite responses and the old message only described one of them.
        #
        # A path INSIDE the site is the installer's own: the model must gain an
        # entry. A path ABOVE the site is the operator's - the installer will
        # not guess a mode for a directory it does not own, and telling them to
        # edit classification.json for their own parent directory sends them
        # somewhere that cannot help. That was the reported complaint: the entry
        # was already there.
        unless ( defined $mode ) {
            my $inside = length($INSTALL_DOCROOT)
                && ( $path eq $INSTALL_DOCROOT
                || index( $path, "$INSTALL_DOCROOT/" ) == 0 );
            die "No declared mode for directory $path\n"
                . "  Every directory the installer creates must be declared in\n"
                . "  dist/config/classification.json (install_dirs), with the mode\n"
                . "  and the reason for it. Add an entry and rebuild the manifest.\n"
                if $inside;
            die "Cannot create $path: it is above the site and the installer does\n"
                . "  not own it, so there is no mode it can safely choose. Create it\n"
                . "  yourself with the ownership and mode your platform expects:\n"
                . "      mkdir -p $path\n"
                . "  then re-run this install. (Editing classification.json will not\n"
                . "  help here - it describes the site's own directories.)\n";
        }
        # SM268 H5: mkdir FAILS if the name already exists - including as a
        # symlink - so a successful mkdir proves we created a real directory
        # and the chmod below cannot land on someone else's file. Without the
        # check, a pre-placed symlink-to-file took the runtime mode: an
        # adversarial review put 2775 on an arbitrary file outside the docroot.
        mkdir $path or die "Cannot create directory $path: $!\n";
        _refuse_symlink( $path, 'set the mode' );
        chmod $mode, $path;    # mkdir's mode is masked by the umask; this is not
    }
    return 1;
}

# SM268 H5: refuse a path that IS a symlink.
#
# The installer runs as ROOT by the documented deploy path, and SM246 guarantees
# the docroot and lazysite/ are group-writable by design. So any account that can
# create a name in the docroot - the CGI, the site user, a compromised plugin -
# could pre-place a symlink and have the next upgrade write through it, chmod
# through it, or chown through it, as root. An adversarial review landed five:
# a write through a symlinked destination, a chmod through a symlinked .pl, a
# runtime directory chmod through a symlinked dir, `chmod 2775` applied to an
# arbitrary FILE outside the docroot, and 39 files written outside via a
# symlinked intermediate directory.
#
# lstat, not stat: `-d`/`-e` follow the link and answer about the target, which
# is exactly the confusion being exploited. `lazysite-check.pl` already uses this
# idiom in two walks.
# SM268 H6/H16: extract an archive with the member names checked FIRST.
#
# Both restore paths shelled out to tar and trusted the archive. Two problems:
#
#   * a member named `../..` or an absolute path escapes the destination, even
#     when -C names a staging directory. The reviewer wrote a file outside the
#     docroot this way.
#   * --restore-full omitted --no-same-permissions, so as ROOT it restored
#     setuid bits straight out of the tarball.
#
# tar has no "reject traversal" switch, so the member list is read and vetted
# before anything is written. Refusing beats sanitising: an archive containing a
# traversal member is not a backup this installer produced, and continuing with
# the "safe" remainder would restore a half-tree from a hostile file.
sub safe_tar_extract {
    my ( $tarball, $dest, @extra ) = @_;

    my @members = qx(tar tzf \Q$tarball\E 2>/dev/null);
    die "Cannot list $tarball\n" if $? != 0;
    chomp @members;

    for my $m (@members) {
        # `..` in any position escapes the destination even with -C, and no tar
        # switch rejects it - hence the pre-flight.
        #
        # A LEADING SLASH is not a finding here: create_backup deliberately
        # writes absolute member names (--absolute-names) and the restore relies
        # on tar stripping the leading `/` to land them under a staging dir,
        # which is tar's default whenever -P/--absolute-names is absent - and
        # the extract below deliberately does not pass it.
        # Rejecting absolute members would refuse every backup this installer
        # has ever produced.
        die "Refusing to restore: archive member escapes the destination: $m\n"
            if $m =~ m{(?:\A|/)\.\.(?:/|\z)};
    }

    # --no-same-owner: never restore uid/gid from the archive.
    # --no-same-permissions: never restore setuid/setgid or over-permissive
    #   modes; extracted files take the process umask instead.
    #
    # Stripping the leading `/` is tar's DEFAULT (it only keeps absolute names
    # under --absolute-names/-P, which is not passed here), so no flag is needed
    # for it - and `--no-absolute-names` is not accepted by every tar in the
    # supported range, so naming it would break the restore it protects.
    return system( 'tar', '-xzf', $tarball, '-C', $dest,
        '--no-same-owner', '--no-same-permissions', @extra );
}

sub _is_symlink {
    my ($path) = @_;
    return ( lstat($path) && -l _ ) ? 1 : 0;
}

# Die on a symlinked path, naming it. Loud rather than skipped: a symlink where
# the installer expects a real file is either an attack or a broken tree, and
# both want an operator to look.
sub _refuse_symlink {
    my ( $path, $what ) = @_;
    return unless _is_symlink($path);
    die "Refusing to $what through a symlink: $path\n"
        . "  The installer runs as root and never follows a link. Remove it (or\n"
        . "  replace it with the real file) and re-run.\n";
}

sub install_file {
    my ( $src, $dest ) = @_;
    my $dir = dirname($dest);
    _refuse_symlink( $dest, 'write' );
    if ( !-d $dir && !eval { make_declared_path($dir); 1 } ) {
        my $err = $@;
        # An undeclared directory is a packaging fault, not a permissions one -
        # pass it through rather than burying it under the Hestia hint, which
        # would send the reader to re-apply a web template that cannot fix it.
        die $err if $err =~ /^No declared mode/;
        # Most often: a site-root sibling (plugins/, tools/, lib/) on a Hestia
        # domain, whose root is mode 0551 - the template hook (lazysite-app.sh)
        # must pre-create those as root. Give an actionable message rather than
        # a bare "mkdir ... Permission denied".
        die "Cannot create directory $dir: $err"
            . "  If this is a Hestia install, the domain root is not user-writable;\n"
            . "  re-apply the lazysite-app web template (it pre-creates plugins/,\n"
            . "  tools/ and lib/ as root), then re-run the install.\n";
    }
    File::Copy::copy( $src, $dest )
        or die "Failed to copy $src -> $dest: $!\n";
    chmod mode_for($dest), $dest;
}

sub mode_for {
    my ($path) = @_;
    return 0755 if $path =~ /\.(pl|sh)$/;
    return 0640 if $path =~ m{/lazysite/auth/};
    return 0644;
}

# =========================================================
# ---------- imperative post-install steps ----------
# =========================================================

sub post_install_steps {
    my ( $o, $manifest, $subs, $state_files, $mode, $stats ) = @_;

    my $docroot    = $o->{docroot};
    my $cgibin     = $o->{cgibin};
    my $plugin_dir = resolve_placeholders( '{DOCROOT}/../plugins', $subs );

    # --- cgi-bin symlinks for plugin endpoints ---
    #
    # form-handler and payment-demo need /cgi-bin/<name>.pl presence
    # so Apache routes POSTs at them. Symlink from plugins; fall
    # back to install if symlink unsupported (some shared hosts).
    # These paths are NOT tracked in .install-state.json - they are
    # links to files that ARE tracked.
    for my $plugin (qw(form-handler payment-demo)) {
        my $src = "$plugin_dir/$plugin.pl";
        my $dst = "$cgibin/$plugin.pl";
        next unless -f $src;
        if ( -e $dst || -l $dst ) {
            # Already present from earlier install; refresh.
            unlink $dst;
        }
        if ( symlink( $src, $dst ) ) {
            info("  linked:    $dst -> $src");
        }
        else {
            File::Copy::copy( $src, $dst )
                or die "Could not install $dst: $!\n";
            chmod 0755, $dst;
            info("  installed: $dst (symlink unsupported)");
        }
    }

    # --- manager CSS: now manifest-tracked ---
    #
    # The manager CSS/assets are shipped straight to the web-served
    # manager/assets/ by the manifest (classification rule
    # ^starter/lazysite/manager/assets/), code bucket, so an upgrade always
    # refreshes them. The old approach copied them here from
    # lazysite/manager/assets/ on every run; that copy could go stale (a
    # pre-SM109 manager.css lingered on upgrade), so it was removed. Clean up
    # the now-orphaned source copy if a previous install left one.
    {
        my $orphan = lazysite_dir_for($docroot) . "/manager/assets/manager.css";
        unlink $orphan if -f $orphan;
        my $od = lazysite_dir_for($docroot) . "/manager/assets";
        rmdir $od if -d $od;    # only succeeds if empty
    }

    # --- auth users/groups: seed from .example on fresh install ---
    #
    # Runtime state. Not tracked in .install-state.json. On upgrade
    # the live files are left alone (operator-edited); we do nothing.
    if ( $mode eq 'fresh' ) {
        for my $f (qw(users groups)) {
            my $src = lazysite_dir_for($docroot) . "/auth/$f.example";
            my $dst = lazysite_dir_for($docroot) . "/auth/$f";
            if ( -f $src && !-f $dst ) {
                File::Copy::copy( $src, $dst )
                    or die "Could not seed auth/$f: $!\n";
                # 0660, not 0640: the auth store is co-managed by the CLI
                # users tool (site user) and the www-data CGI (setgid auth
                # dir); without group-write the manager cannot save users.
                chmod 0660, $dst;
                info("  seeded:    lazysite/auth/$f (from $f.example)");
            }
        }
    }

    # --- nav.conf: seed from .example on fresh install ---
    if ( $mode eq 'fresh' ) {
        my $src = "$STAGE_DIR/starter/nav.conf.example";
        my $dst = lazysite_dir_for($docroot) . "/nav.conf";
        if ( -f $src && !-f $dst ) {
            File::Copy::copy( $src, $dst )
                or die "Could not seed nav.conf: $!\n";
            # 0664, not 0644: the manager's nav editor saves this through the
            # www-data CGI ("Cannot write nav: Permission denied" in the field).
            chmod 0664, $dst;
            info("  seeded:    lazysite/nav.conf (from nav.conf.example)");
        }
    }

    # --- lazysite.conf: write on fresh install ---
    #
    # If --domain, write a minimal conf with templated site_name /
    # site_url. Otherwise, install the .example as the live conf.
    if ( $mode eq 'fresh' ) {
        my $conf = _conf_path($docroot);
        if ( !-f $conf ) {
            if ( length $o->{domain} ) {
                write_text(
                    $conf,
                    "# lazysite.conf - site configuration\n"
                        . "# See https://lazysite.io/docs for reference\n\n"
                        . "site_name: $o->{domain}\n"
                        . "site_url: \${REQUEST_SCHEME}://$o->{domain}\n"
                        # New sites default to the stable update channel (edge upgrades
                        # are skipped). Change to 'all' for a test / cutting-edge site.
                        . "update_channel: stable\n"
                        # SM139: fleet upgrades (`lazysite upgrade --all`) leave a
                        # 'manual' site alone; set 'auto' to opt in to cron-driven
                        # upgrades. 'manual' matches the absent-key default.
                        . "update_policy: manual\n"
                );
                info("  wrote:     lazysite/lazysite.conf (from --domain)");
            }
            else {
                my $src = "$STAGE_DIR/starter/lazysite.conf.example";
                if ( -f $src ) {
                    File::Copy::copy( $src, $conf )
                        or die "Could not seed lazysite.conf: $!\n";
                    info("  seeded:    lazysite/lazysite.conf (from example)");
                }
            }
            # 0664, not 0644: the manager (config-set, plugin enable, channel
            # changes) runs as the web-server user and must be able to write the
            # conf. Group-writability only helps with the right group ownership -
            # see align_ownership below for the root-run case.
            chmod 0664, $conf if -f $conf;
        }
    }

    # --- CGI-writable file set: umask-proof the group-write bit ---
    #
    # Every file the www-data CGI must WRITE IN PLACE (the manager saves
    # nav.conf / lazysite.conf / the auth store / ACLs; every surface appends
    # audit.log) has to carry group-write whatever umask this installer ran
    # under - a 0644 file here silently locks the CGI out (the field defects:
    # nav-save "Permission denied", and audit entries lost without trace).
    # This list mirrors check 4b in tools/lazysite-check.pl - keep the two in
    # step (t/tools/03-install-pl.t cross-checks them). Runs on every mode and
    # only ADDS the group-write bit to files that exist; anything else about
    # an operator's modes is left alone.
    # SM246 (deliverable 4): the list is DECLARED in the model
    # (classification.json's runtime_files), not repeated here. It was
    # hand-maintained in two places - a new file needing group write was only
    # fixed if someone remembered both - and each row now carries the reason.
    # Falls back to the historical list when the manifest predates the field, so
    # an older payload installs exactly as before.
    my @gw = map { $_->{path} } @{ $manifest->{runtime_files} || [] };
    @gw = map { "{DOCROOT}/$_" } qw(
        lazysite/nav.conf lazysite/lazysite.conf
        lazysite/auth/users lazysite/auth/groups lazysite/auth/acls.json
        lazysite/logs/audit.log
    ) unless @gw;
    for my $spec (@gw) {
        ( my $rel = $spec ) =~ s/\{DOCROOT\}\///;
        my $p = "$docroot/$rel";
        next unless -f $p;
        my $m = ( stat _ )[2] & 07777;
        chmod( $m | 0020, $p ) unless $m & 0020;
    }

    # --- SGID on the lazysite/ subtree (not whole docroot) ---
    my $laz = lazysite_dir_for($docroot);
    if ( -d $laz ) {
        my $mode_now = ( stat $laz )[2] & 07777;
        my $want     = $mode_now | 02020;          # g+ws
        if ( $mode_now != $want ) {
            chmod $want, $laz;
        }
    }

    # --- Robustness: ownership alignment when installing as root ---
    # A sudo install writes root-owned files; deploy wrappers (Hestia) fix that
    # with a blanket chown afterwards, but a direct `sudo install.sh` has no such
    # pass - leaving lazysite.conf and the runtime dirs unwritable by the web
    # server ("Cannot write lazysite.conf: Permission denied" the moment the
    # manager saves a setting). Align what we manage to the DOCROOT's own
    # owner/group, so the installer is correct on its own regardless of the
    # calling wrapper.
    align_ownership($docroot);
}

# Repair ROOT-OWNED files under the lazysite tree (root runs only): a sudo
# install writes as root, and without a wrapper chown pass those files are
# unreadable/unwritable by the web-server CGI. Scope is deliberately narrow -
# ONLY files currently owned by root are touched (the CGI legitimately owns its
# runtime files as www-data, and the operator owns content; both are left
# alone - a broader "align everything" pass in 0.6.5 stripped www-data's access
# on a site whose docroot group was not www-data, 500ing the auth wrapper).
# Owner becomes the docroot's owner; group becomes the WEB-SERVER group
# (www-data when it exists, matching lazysite-check), so group-rw modes keep
# working for the CGI.
sub align_ownership {
    my ($docroot) = @_;
    return unless $> == 0;    # only meaningful (and permitted) as root
    my $uid = ( stat $docroot )[4];
    return unless defined $uid;
    return if $uid == 0;      # a root-owned docroot gives us no better target
    my $gid = ( getgrnam 'www-data' )[2];
    $gid = ( stat $docroot )[5] unless defined $gid;

    my @paths = ( _conf_path($docroot) );
    my @stack = ( lazysite_dir_for($docroot) );
    while ( my $dir = pop @stack ) {
        next unless -d $dir;
        push @paths, $dir;
        opendir my $dh, $dir or next;
        for my $e ( readdir $dh ) {
            next if $e eq '.' || $e eq '..';
            my $p = "$dir/$e";
            # SM268 H5: a symlink is SKIPPED outright, never queued for chown.
            # It used to fall into @paths, where stat read the TARGET's uid for
            # the "only root-owned" guard and chown followed the link - so a
            # planted link handed its target to the site user, as root. Perl has
            # no lchown, so skipping is the only correct answer.
            if    ( -l $p ) { next }
            elsif ( -d $p ) { push @stack, $p }
            else            { push @paths, $p }
        }
        closedir $dh;
    }
    my $n = 0;
    for my $p (@paths) {
        next unless -e $p;
        my $cu = ( stat _ )[4];
        next unless defined $cu && $cu == 0;    # ONLY repair root-owned paths
        chown( $uid, $gid, $p ) and $n++;
    }
    info("  ownership: repaired $n root-owned path(s) under lazysite/")
        if $n;
    return;
}

# =========================================================
# ---------- runtime paths ----------
# =========================================================

sub create_runtime_paths {
    my ( $rps, $subs, $install_mode ) = @_;
    # SM246: the defensive default is the CONSERVATIVE value. This read
    # `||= 'fresh'`, and 'fresh' is the one that re-chmods existing directories -
    # so a caller that forgot the argument got the destructive behaviour. The one
    # real caller always passes it, so this was never live; a default that only
    # bites when someone makes a mistake should not be the dangerous one.
    $install_mode ||= 'upgrade';
    for my $rp (@$rps) {
        # SM246: one model, three consumers - install applies, check verifies,
        # check --fix repairs. `applied_by` says which consumers own a path, so
        # the table can describe paths that are VERIFIED without being created
        # or chmod'ed here (lazysite/git is made by the content-history plugin at
        # adoption; lazysite/forms and the form-events log by the CGI). Absent
        # means install, so an entry that predates the field behaves as before.
        my $by = $rp->{applied_by};
        next if ref $by eq 'ARRAY' && !grep { $_ eq 'install' } @$by;
        my $path = resolve_placeholders( $rp->{path}, $subs );
        my $mode = oct( $rp->{mode} );
        # SM268 H5: never chmod a runtime path that is a symlink. `-d` follows
        # the link, so a planted link took the runtime mode onto its target -
        # the reviewer put 2775 on a file outside the docroot this way.
        _refuse_symlink( $path, 'set the mode' );
        if ( -d $path ) {
            # On a FRESH install the directory may already exist because the
            # file-install pass created it (e.g. to hold the seeded
            # auth/*.example), in which case it carries a default mode, not the
            # declared one - so apply the runtime mode (these dirs must be
            # group-writable + setgid for the www-data CGI to write them). On an
            # UPGRADE, leave an existing directory alone: the operator may have
            # tightened it deliberately.
            # SM246 (deliverable 3): the fresh-versus-upgrade policy is now
            # DECLARED per path rather than implied by one branch.
            #
            #   repair - the engine owns this absolutely and re-applies the mode
            #            on every run. These are the directories the CGI MUST be
            #            able to write; an operator who "tightens" lazysite/cache
            #            breaks their own site, silently, and the failure looks
            #            like a rendering fault rather than a permission one.
            #   leave  - set on creation, never touched again. ../plugins is
            #            EXECUTED, not written, so 0755 is right and hardening it
            #            further is a legitimate operator choice.
            #
            # Absent means leave, so an entry predating the field keeps the old
            # upgrade behaviour. Note this only ever widens a mode toward what the
            # model declares - it is not the "align everything" ownership pass
            # that caused the 0.6.5 outage, which was chown and is untouched.
            my $on_upgrade = $rp->{on_upgrade} // 'leave';
            chmod $mode, $path
                if $install_mode eq 'fresh' || $on_upgrade eq 'repair';
            next;
        }
        # SM246: create the PARENTS through the directory model, then this
        # directory with its own runtime mode.
        #
        # `make_path($path, {mode => $mode})` applied one mode to every level it
        # created and then chmod'ed only the leaf, so an intermediate kept
        # whatever mkdir left it with: creating lazysite/auth (2770) made
        # lazysite/ 2770, and creating lazysite/manager/locks (2775) made
        # lazysite/manager/ 0775 with no setgid. Both were then invisible,
        # because nothing verified an intermediate.
        #
        # Linux mkdir(2) does not take S_ISGID from its mode argument, which is
        # why every level needs an explicit chmod rather than a mode passed to
        # mkdir - the same reason install_file's directory walk exists.
        make_declared_path( dirname($path) );
        mkdir $path unless -d $path;
        chmod $mode, $path;
    }
}

# =========================================================
# ---------- backup / restore ----------
# =========================================================

sub create_backup {
    my ( $state, $backup_dir, $state_path, $new_version ) = @_;

    my $ts   = strftime( '%Y%m%d-%H%M%S', gmtime );
    my $name = "lazysite-backup-$ts-pre-$new_version.tar.gz";
    my $out  = "$backup_dir/$name";

    # Collect the set of files to back up: everything in the current
    # .install-state.json plus .install-state.json itself. Missing
    # files are skipped with a warning (stale state).
    my @paths;
    for my $path ( sort keys %{ $state->{files} || {} } ) {
        if ( -f $path ) {
            push @paths, $path;
        }
        else {
            warn "  backup: missing $path (recorded in state but not on disk; skipped)\n";
        }
    }
    push @paths, $state_path if -f $state_path;

    unless (@paths) {
        die "Backup: no files to archive. Aborting upgrade to avoid unrecoverable state.\n";
    }

    # Build a file list for tar --files-from. Paths are absolute;
    # tar strips leading / by default. Restore re-adds it.
    # SM268 H7: the list is piped to tar, not written to a file.
    #
    # It used to be `$backup_dir/.backup-list-$$` - a predictable name in a
    # directory SM246 guarantees is group-writable. Anyone in the site group
    # could pre-place that name as a symlink and, since this runs as root during
    # an upgrade, have the open() write the file list through it. Racing the pid
    # is easy: pids are small and the window is the whole backup.
    #
    # Feeding tar on stdin removes the file, and with it the race, the predicable
    # name and the cleanup. There is nothing left to plant.
    my @cmd = (
        'tar',
        '--absolute-names',
        '-czf', $out,
        # --verbatim-files-from is POSITIONAL and affects only the --files-from
        # that follows it, so the order here is load-bearing: after, tar warns
        # "has no effect" and exits non-zero, which aborts the upgrade.
        '--verbatim-files-from',
        '--files-from', '-',
    );
    my $rc;
    if ( open my $tar, '|-', @cmd ) {
        print {$tar} "$_\n" for @paths;
        close $tar;
        $rc = $?;
    }
    else {
        die "Backup: could not run tar: $!\n";
    }

    if ( $rc != 0 ) {
        unlink $out if -f $out;
        die "Backup: tar failed (rc=$rc). Aborting upgrade. Your system is unchanged.\n";
    }

    # SM268 03-F10: the installer's own backups never got a sidecar.
    #
    # SM183 said "every site package and backup now gets a .sha256 sidecar" and
    # the installer's did not - it cannot load Lazysite::Manager::Backups, so the
    # writer simply was not there. That also made apply_retention's
    # `unlink "$backups[$i].sha256"` dead code: it retired a file nothing had
    # ever written. Same format, same sha256sum -c compatibility, written the
    # same atomic way.
    write_backup_sha256($out);

    return $out;
}

# The .sha256 sidecar for an installer-written artefact. Deliberately a small
# local copy rather than a shared one: install.pl runs from the release tarball
# with no @INC into the site's lib, which is the whole reason this was missing.
# Failure is not fatal - the artefact is valid without it - but it must not be
# reported as written when it was not.
sub write_backup_sha256 {
    my ($path) = @_;
    return '' unless -f $path;
    my $sha = eval { sha256_of($path) };
    return '' unless defined $sha && length $sha;
    my $base = basename($path);
    my $side = "$path.sha256";
    if ( -l $side ) {
        warn "  warn: $side is a symlink; not writing a digest sidecar\n";
        return '';
    }
    my $tmp = "$side.tmp.$$";
    unless ( sysopen my $fh, $tmp, O_WRONLY | O_CREAT | O_EXCL, oct '640' ) {
        warn "  warn: could not write $tmp: $!\n";
        return '';
    }
    else {
        print {$fh} "$sha  $base\n";
        close $fh;
    }
    unless ( rename $tmp, $side ) {
        warn "  warn: could not install $side: $!\n";
        unlink $tmp;
        return '';
    }
    return $sha;
}

sub cmd_list_backups {
    my ($docroot) = @_;
    my $dir = lazysite_dir_for($docroot) . "/backups";
    unless ( -d $dir ) {
        print "No backups directory at $dir.\n";
        return 0;
    }
    my @files = _backup_files($dir);
    unless (@files) {
        print "No backups found at $dir.\n";
        return 0;
    }
    printf "%-60s  %12s  %s\n", 'Backup', 'Size', 'Modified';
    for my $f (@files) {
        my @st    = stat $f;
        my $size  = $st[7];
        my $mtime = strftime( '%Y-%m-%d %H:%M:%S UTC', gmtime $st[9] );
        printf "%-60s  %12d  %s\n", basename($f), $size, $mtime;
    }
    return 0;
}

sub cmd_restore {
    my ($o) = @_;

    my $backup_path;
    if ( length $o->{backup} ) {
        $backup_path = abs_path( $o->{backup} ) // $o->{backup};
        die "Backup '$backup_path' not found\n" unless -f $backup_path;
    }
    else {
        my $dir   = lazysite_dir_for( $o->{docroot} ) . "/backups";
        my @files = _backup_files($dir);
        die "No backups found at $dir\n" unless @files;
        $backup_path = $files[-1];    # most recent (lexicographic == chronological)
    }

    info("Restoring from: $backup_path");

    # Extract into a temp dir. Do NOT pass --absolute-names at
    # extract: tar must strip leading / and land files under $tmp
    # so we can explicitly copy them to their real destinations.
    # Otherwise tar would write to the absolute paths directly and
    # bypass our state-driven restore logic (and the security
    # benefit of staging in a temp dir first).
    my $tmp = tempdir( 'lazysite-restore-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    my $rc  = safe_tar_extract( $backup_path, $tmp );
    die "tar extraction failed (rc=$rc)\n" if $rc != 0;

    # The tar stripped the leading "/" from paths, so the content
    # lives at $tmp/<abs-path-without-leading-slash>.
    my $state_rel = state_path( $o->{docroot} );
    $state_rel =~ s{^/+}{};
    my $state_copy = "$tmp/$state_rel";
    die "Backup is missing .install-state.json at $state_copy\n"
        unless -f $state_copy;

    my $backup_state = load_state($state_copy);
    my $files        = $backup_state->{files} || {};

    my $restored = 0;
    for my $dest ( sort keys %$files ) {
        ( my $rel = $dest ) =~ s{^/+}{};
        my $src = "$tmp/$rel";
        unless ( -f $src ) {
            warn "  skip (missing in backup): $dest\n";
            next;
        }
        make_path( dirname($dest) );
        if ( -e $dest ) {
            unlink $dest
                or warn "  warn: could not remove existing $dest: $!\n";
        }
        File::Copy::copy( $src, $dest )
            or die "Could not restore $dest: $!\n";
        chmod mode_for($dest), $dest;
        $restored++;
    }

    # Rewrite .install-state.json from the backup.
    my $state_path = state_path( $o->{docroot} );
    make_path( dirname($state_path) );
    File::Copy::copy( $state_copy, $state_path )
        or die "Could not write $state_path: $!\n";
    chmod 0644, $state_path;

    # Invalidate rendered .html cache: content at the pre-upgrade
    # version may reference state that no longer matches.
    my $dropped = invalidate_rendered_html( $o->{docroot} );
    info("  cleared:   lazysite/cache/ ($dropped rendered page(s) invalidated)")
        if $dropped;

    info("");
    info("Restore complete.");
    info("  Version:  $backup_state->{version}");
    info("  Files:    $restored restored");
    info("  Runtime:  untouched (auth, logs, locks, etc.)");
    info("");

    return 0;
}

# =========================================================
# ---------- retention ----------
# =========================================================

sub read_retention {
    local $_;    # SM420: while(<>) assigns the GLOBAL $_
    my ($docroot) = @_;
    my $conf      = _conf_path($docroot);
    my $default   = 3;
    return $default unless -f $conf;
    open my $fh, '<', $conf or return $default;
    my $val = $default;
    while (<$fh>) {
        if (/^backup_retention\s*:\s*(\S+)/) {
            my $v = $1;
            if ( $v =~ /^\d+$/ ) {
                $val = $v + 0;
                last;
            }
            close $fh;
            die "lazysite.conf: backup_retention must be a non-negative integer (got '$v')\n";
        }
    }
    close $fh;
    return $val;
}

sub apply_retention {
    my ( $dir, $retention ) = @_;
    return if $retention == 0;
    my @backups = _backup_files($dir);
    # Sort by mtime ascending (oldest first) in case lexical and
    # chronological diverge (shouldn't, but defensive).
    @backups = sort { ( stat $a )[9] <=> ( stat $b )[9] } @backups;
    my $excess = @backups - $retention;
    return if $excess <= 0;
    for my $i ( 0 .. $excess - 1 ) {
        unlink $backups[$i]
            or warn "  warn: could not remove $backups[$i]: $!\n";
        # SM183: retire the integrity sidecar with the artefact it describes.
        unlink "$backups[$i].sha256" if -f "$backups[$i].sha256";
        info( "  retired:   " . basename( $backups[$i] ) );
    }
}

# =========================================================
# ---------- state i/o ----------
# =========================================================

sub state_path {
    my ($docroot) = @_;
    return lazysite_dir_for($docroot) . "/.install-state.json";
}

sub load_state {
    my ($path) = @_;
    return undef unless -f $path;
    open my $fh, '<:raw', $path
        or die "Cannot read state $path: $!\n";
    my $text = do { local $/; <$fh> };
    close $fh;
    my $parsed = eval { JSON::PP::decode_json($text) }
        or die "Cannot parse state $path: $@\n";
    return $parsed;
}

sub write_state {
    my ( $path, $version, $files ) = @_;

    # SM268 03-F7: record the RESOLVED install_dirs modes alongside the files.
    #
    # SM246's design is "one table, three consumers - install applies, check
    # verifies, check --fix repairs". That was true of runtime_paths and false
    # of install_dirs: lazysite-check.pl carried its own hand-written list of
    # eleven lazysite/* directories and knew nothing of the twenty-eight the
    # model declares. So every site already carrying the reported fault - the
    # docroot's content directories stripped of group write - stayed broken, and
    # the audit tool called the site healthy.
    #
    # The model lives in the release tarball, which an installed site does not
    # keep, so check cannot read it directly. Writing the resolved paths into
    # the install state is what gives check something to verify against, without
    # it having to guess at placeholders or find a manifest.
    my %dirs = map { $_ => sprintf '%04o', $INSTALL_DIR_MODE{$_} }
        keys %INSTALL_DIR_MODE;

    my $data = {
        schema_version => '1',
        version        => $version,
        installed_at   => strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime ),
        files          => $files,
        ( %dirs ? ( dirs => \%dirs ) : () ),
    };
    make_path( dirname($path) );
    my $json = JSON::PP->new->utf8(1)->pretty(1)->indent_length(2)
        ->canonical(1)->encode($data);
    open my $fh, '>:raw', $path
        or die "Cannot write state $path: $!\n";
    print $fh $json;
    close $fh;
    chmod 0644, $path;
}

# A release tarball always carries release-manifest.json - it is generated at
# build time and shipped. A SOURCE CHECKOUT does not: the file is gitignored,
# so it exists only on a machine that has built a release.
#
# That distinction was invisible for a long time, because the developer's
# working copy always had one lying around from the last build. The suite
# passed there and failed on a clean checkout of the very tag it was testing -
# fifteen test files invoke install.pl, and the strict SBOM gate needs the same
# file, so a released tag could neither run its own tests nor its own
# compliance control for anyone who cloned it (2026-08-14 review, D3 F3.1 and
# D6 F6.6).
#
# The manifest is DERIVABLE from the tree, so absence is recoverable rather
# than fatal: if the builder and the classification map are both present, build
# one. It goes to a temp path and not into the checkout, so a clean tree stays
# clean and the fallback cannot be mistaken for a real release artefact.
sub _generate_manifest_to_tmp {
    my ($expected) = @_;
    my $root       = dirname($expected);
    my $builder    = "$root/tools/build-manifest.pl";
    return undef unless -f $builder && -f "$root/dist/config/classification.json";

    my $tmp = "/tmp/lazysite-manifest-$$.json";
    my $rc  = system( $^X, $builder, '--staged', $root, '--out', $tmp );
    return ( $rc == 0 && -s $tmp ) ? $tmp : undef;
}

sub load_manifest {
    my ($path) = @_;
    my $tmp;
    if ( !-f $path ) {
        $tmp = _generate_manifest_to_tmp($path);
        die "release-manifest.json not found at $path\n" unless $tmp;
        print "install: no release-manifest.json; generated one from the "
            . "source tree (this is a checkout, not a release tarball)\n";
        $path = $tmp;
    }
    open my $fh, '<:raw', $path
        or die "Cannot read $path: $!\n";
    my $text = do { local $/; <$fh> };
    close $fh;
    # SM304: a manifest that is PRESENT but unparseable is treated exactly as an
    # absent one, because the recovery is identical and already written above.
    #
    # A power cut during the 0.10.10 gate left this file as 66,505 bytes of nulls
    # - written, not fsynced. It is gitignored, so `git status` reported the tree
    # clean and nothing pointed at it. Both readers of this file died, with
    # different messages, and NEITHER considered regenerating a file it knows how
    # to regenerate. That is the same gap written twice, which is the whole
    # argument of SM304.
    my $parsed = eval { JSON::PP::decode_json($text) };
    if ( !$parsed && !$tmp ) {
        my $why = $@ || 'unparseable';
        $tmp = _generate_manifest_to_tmp($path);
        if ($tmp) {
            print "install: $path could not be parsed ($why); regenerated one "
                . "from the source tree\n";
            open my $rfh, '<:raw', $tmp or die "Cannot read $tmp: $!\n";
            $text = do { local $/; <$rfh> };
            close $rfh;
            $parsed = eval { JSON::PP::decode_json($text) };
        }
    }
    die "Cannot parse $path: $@\n" unless $parsed;
    unlink $tmp if $tmp;
    return $parsed;
}

# =========================================================
# ---------- helpers ----------
# =========================================================

# SM293: where this site keeps its engine tree.
#
# Module-free, and that is not laziness: install.pl is the bootstrap that
# INSTALLS the payload containing lib/, so it cannot depend on it. Mirrors
# Lazysite::Paths::lazysite_dir and the processor's copy; t/lint/37 drives all
# three and compares their answers.
#
# This one matters more than the others. Every write into the engine tree flows
# through the {LAZYSITE} placeholder below, so an installer that computed
# "<docroot>/lazysite" would RE-CREATE the tree inside the docroot on the next
# upgrade of a migrated site - putting it in both places, which is the one state
# that is broken and invisible at the same time.
sub lazysite_dir_for {
    my ($d) = @_;
    return '' unless defined $d && length $d;
    $d =~ s{/+\z}{};
    return '' unless length $d;
    my $leaf = $d;
    $leaf =~ s{\A.*/}{};         # basename
    my $parent = $d;
    $parent =~ s{/[^/]*\z}{};    # dirname
    my $ext = "$parent/$leaf-lazysite";
    return -d $ext ? $ext : "$d/lazysite";
}

sub placeholders {
    my ( $docroot, $cgibin ) = @_;
    return (
        DOCROOT  => $docroot,
        CGIBIN   => $cgibin,
        LAZYSITE => lazysite_dir_for($docroot),

        # SM321: the private store, so it can be DECLARED like every other
        # runtime directory instead of being created by whichever code path
        # happens to reach it first.
        #
        # It was the only runtime directory not in runtime_paths, and that single
        # omission produced a chain of defects: install never created it, so
        # `check` needed bespoke repair code (SM313), so the operator needed a
        # special command with hand-assembled paths, so a sweep and a CGI protect
        # raced to create it with different ownership (SM323) and whichever won
        # decided whether partner surfaces could protect content at all.
        #
        # DUPLICATED FROM Lazysite::Private::private_root ON PURPOSE. This
        # installer is core-Perl-only by design - it must run before, and
        # independently of, the engine it installs, so it cannot load the module
        # that owns this path. t/lint/51 asserts the two constructions agree,
        # which is the same treatment ADR 0008's frozen fields get in t/lint/45:
        # where a fact must exist twice, the second copy is pinned to the first.
        PRIVATE_STORE => _private_store_for($docroot),
    );
}

# Mirrors Lazysite::Private::private_root exactly - a SIBLING of the docroot,
# not a child. Getting that wrong is what made the docroot repair miss it.
sub _private_store_for {
    my ($docroot) = @_;
    return '' unless defined $docroot && length $docroot;
    ( my $d = $docroot ) =~ s{/+\z}{};
    return '' unless length $d;
    return dirname($d) . '/' . basename($d) . '-lazysite-private';
}

sub resolve_placeholders {
    my ( $template, $subs ) = @_;
    my $out = $template;
    for my $k ( keys %$subs ) {
        $out =~ s/\{\Q$k\E\}/$subs->{$k}/g;
    }
    # Collapse any "/../" sequences where the docroot placeholder
    # introduced them (e.g. {DOCROOT}/../plugins), by normalising
    # through a simple textual pass. Do NOT use abs_path here - the
    # directory may not exist yet.
    #
    # SM268 03-F8: a TRAILING `..` counts too. This pattern needed a slash on
    # both sides, so `{DOCROOT}/../lib` collapsed to /base/lib and matched,
    # while `{DOCROOT}/..` stayed as `/base/site/..` - a string
    # make_declared_path never looks up, because the parent walk asks for
    # `/base`. The declaration for the site's parent directory was therefore
    # dead, and provisioning a site whose parent does not yet exist failed with
    # "No declared mode for directory ..." telling the operator to add an entry
    # to classification.json that was already there.
    #
    # Loop: collapsing one segment can expose another (a/b/../../c).
    1 while $out =~ s{/[^/]+/\.\./}{/}g;
    1 while $out =~ s{/[^/]+/\.\.\z}{};
    $out =~ s{/\z}{} if length($out) > 1;
    # Collapsing back past the root leaves nothing; that is the root itself, and
    # an empty string would be a lookup key no declaration can ever carry.
    $out = '/' if $out eq '';
    return $out;
}

sub sha256_of {
    my ($path) = @_;
    my $sha = Digest::SHA->new('sha256');
    $sha->addfile( $path, 'b' );
    return $sha->hexdigest;
}

sub write_text {
    my ( $path, $text ) = @_;
    make_path( dirname($path) );
    open my $fh, '>:raw', $path or die "Cannot write $path: $!\n";
    print $fh $text;
    close $fh;
}

sub info {
    my ($msg) = @_;
    print STDERR "$msg\n";
}

# =========================================================
# ---------- summary + dep check + next steps ----------
# =========================================================

sub print_summary {
    my ( $mode, $manifest, $stats, $backup_path, $warnings ) = @_;
    print STDERR "\n=== Install summary ($mode) ===\n";
    print STDERR "  Version:    $manifest->{version}\n";
    print STDERR "  Installed:  $stats->{installed}\n";
    print STDERR "  Overwrote:  $stats->{overwrote}\n";
    my $pcount = scalar @{ $stats->{preserved} };
    print STDERR "  Preserved:  $pcount";
    print STDERR " (operator-edited)" if $pcount;
    print STDERR "\n";
    if ($pcount) {
        print STDERR "    - $_\n" for @{ $stats->{preserved} };
    }
    print STDERR "  Removed:    $stats->{removed}\n";
    my $ocount = scalar @{ $stats->{orphaned} };
    if ($ocount) {
        print STDERR "  Orphans:    $ocount (edited post-install, left in place):\n";
        print STDERR "    - $_\n" for @{ $stats->{orphaned} };
    }
    print STDERR "  Backup:     $backup_path\n" if $backup_path;
    if (@$warnings) {
        print STDERR "\nWarnings:\n";
        print STDERR "  $_\n" for @$warnings;
    }
    print STDERR "\n";
}

sub print_dep_check {
    my @missing;
    for my $check (
        [ 'Archive::Zip', 'libarchive-zip-perl',
            'theme upload (manager UI)' ],
        [ 'Template::Plugin::JSON::Escape', 'libtemplate-plugin-json-escape-perl',
            'search index (search-index.md)' ],
    ) {
        my ( $mod, $pkg, $feature ) = @$check;
        my $rc = system("perl -M$mod -e 1 2>/dev/null");
        push @missing, [ $mod, $pkg, $feature ] if $rc != 0;
    }
    return unless @missing;
    print STDERR "Missing optional Perl modules:\n";
    for my $m (@missing) {
        print STDERR "  $m->[0]    # $m->[2]\n";
    }
    print STDERR "\nOn Debian/Ubuntu:\n";
    my $pkgs = join ' ', map { $_->[1] } @missing;
    print STDERR "  sudo apt-get install $pkgs\n\n";
}

sub print_next_steps {
    my ($docroot) = @_;
    my $LAZYSITE_SHOWN = lazysite_dir_for($docroot);
    print STDERR <<"TEXT";
Next steps:
  1. Install a layout + theme via the manager UI at /manager/themes.
     A fresh install has no default layout - the processor falls
     back to a built-in template until a layout is installed and
     a compatible theme is activated via /manager/config. Set
     'layout:' and 'theme:' in lazysite.conf to point at them.
  2. Edit $LAZYSITE_SHOWN/lazysite.conf to configure your site.
  3. Replace $docroot/index.md with your content.

TEXT
}

__END__

=head1 NAME

install.pl - install or upgrade lazysite in place

=head1 SYNOPSIS

  install.pl --docroot PATH --cgibin PATH [--domain NAME] [--dry-run]

=head1 DESCRIPTION

Installs or upgrades lazysite in place from the shipped release manifest. On the
first run it creates a fresh installation; on later runs it upgrades, overwriting
project-owned code while preserving operator-edited content (pages, custom docs)
per the manifest's C<code>/C<seed> classification. Per-file SHAs are recorded in
F<lazysite/.install-state.json> so an edited seed file is never clobbered and an
unwritable file is skipped non-fatally.

=head1 OPTIONS

=over 4

=item B<--docroot> PATH

Path to the web document root (required).

=item B<--cgibin> PATH

Path to the C<cgi-bin> directory (required).

=item B<--domain> NAME

Domain name for the C<site_url> in a newly-seeded F<lazysite.conf> (used only
when seeding a fresh config).

=item B<--dry-run>

Compute and print the plan without making any filesystem change. Run this before
an upgrade to see what would be written.

=item B<--force>

Upgrade even when the site's C<update_channel> would skip this release (for
example a C<stable> site taking an C<edge> build). A deliberate operator override,
recorded in the site's audit log as C<upgrade-forced>.

=item B<--channel> C<edge>|C<beta>|C<stable>|C<certified>

Set the site's update channel (the C<update_channel:> key in C<lazysite.conf>) and
exit - a standalone maintenance operation, no install. The ladder is
C<edge> E<lt> C<beta> E<lt> C<stable> E<lt> C<certified>, and a site accepts
builds at its own rung or above. Use it to pin a deployment to C<stable>
(customer rollout) or move it back to C<edge>, without hand-editing
the conf. An unrecognised value in the conf is treated as C<stable> - the most
restrictive rung - and reported (SM356). Recorded in the audit log as C<channel-set>. lazysite has no central
registry of sites, so to set a whole fleet, loop this over your docroots:

    for d in /home/*/web/*/public_html; do
        install.pl --channel stable --docroot "$d"
    done

=item B<--verify>

Is the code B<installed> at C<--docroot>/C<--cgibin> actually this payload's
version? The deploy-gap detector: it compares what is on disk against the
release manifest and reports the difference, exiting non-zero when they
disagree. Needs both C<--docroot> and C<--cgibin>; changes nothing.

=item B<--channel-check>

Would an upgrade of this site be skipped by its C<update_channel>? Exits 3 if
it would, 0 otherwise, so a deploy can bail before touching the site. Needs
C<--docroot>; reads C<lazysite.conf> and the release manifest only - no file
changes and no ownership requirement.

=item B<--policy> C<auto>|C<manual>

Set the site's update policy (the C<update_policy:> key in C<lazysite.conf>) and
exit - a standalone maintenance operation, no install. C<auto> opts the site in
to fleet-wide C<lazysite upgrade --all> runs (e.g. cron-driven); C<manual> (the
default when the key is absent) means only a deliberate per-site upgrade - or
C<upgrade --all --force>/C<--force-security> - touches it. Recorded in the audit
log as C<policy-set>.

=item B<--restore-full> I<FILE>

Restore a full-system backup (created by the manager's "full" backup) into
C<--docroot>, and clear the render caches. Pass C<--domain> I<NAME> to rewrite the
site's C<domain:> - the temp-domain to final-domain migration path (build a site on
a temporary domain, then migrate it, content + config + accounts intact, to the
final domain). A deliberate system-user operation: a full backup carries the auth
secrets, so restore is not exposed in the manager UI. Recorded as C<full-restore>.
Review file ownership/permissions on the target host afterwards.

    install.pl --restore-full full-20260704T101500Z.tar.gz \
        --docroot /home/site/public_html --domain www.example.com

=item B<--help>

Print the usage summary.

=back

=head1 SEE ALSO

L<lazysite-check.pl(1)>, L<lazysite-users.pl(1)>. See also
F<installers/hestia/INSTALL-RUNBOOK.md> and F<docs/IMPLEMENTOR.md>.

=cut
