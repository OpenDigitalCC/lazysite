package Lazysite::Util;

# Shared helpers for the modular lazysite scripts (auth, dav, manager-api, the
# users tool). The processor stays self-contained and does NOT use this module -
# see docs/feature-requests/archive/SM079-modular-refactor.md.
#
# Each script sets $Lazysite::Util::COMPONENT after `use`, so log lines are
# attributed to the right component.

use strict;
use warnings;
use Lazysite::Paths ();
use POSIX           ();
use Exporter 'import';

our @EXPORT_OK = qw(log_event const_eq unlink_host_copies unlink_host_page clear_host_cache forward_line service_enabled secure_write_perms drop_to_tree_owner target_identity cannot_read backup_retention);

our $COMPONENT = 'lazysite';

# SM215: make a just-written file owner/group/mode-safe so a helper run under sudo
# (as root) never leaves a file the web-server (www-data) CGI cannot access. The
# parent directory is provisioned <site-user>:<web-group> (and is setgid), so we
# INHERIT owner+group from it rather than hard-code www-data: as root, chown both
# (only root can); unprivileged, set the group only (best-effort - a non-root CLI
# is normally already the file's owner, and chown-to-another-user would just fail).
# Call on the temp file BEFORE rename (same directory), or on the final path. Mode
# is applied explicitly. Best-effort throughout: never dies on a chown/chmod fail.
# SM766 (SM760's lesson, made a rule): A STORE READER NEVER TURNS AN
# UNOPENABLE FILE INTO AN EMPTY ANSWER IN SILENCE. `open ... or return {}`
# on a file that EXISTS turned a permissions fault into "this account holds
# nothing" for the runtime and a dead process for Status; both were read as
# facts about the site. Every read-open in the auth and daemon stores now
# goes through this on failure: it WARNs with the file, the error and the
# unix user - unless the file simply is not there (ENOENT), which is the
# ordinary empty case and not a fault - and returns undef so the caller's
# `// <empty>` keeps its shape. t/lint/121 holds that no read-open in those
# modules returns in silence.
# SM753: THE ONE READER of `backup_retention`. Three parsers read this key
# with two defaults - the manager kept 10, the installer and the theme store
# kept 3, the docs said 3 - so a sysop who never set it kept ten manual
# backups, read that they kept three, and the theme store kept three. The
# release manager's ruling (2026-09-07): 3, one reader, settable on the Site
# config page. `0` means unlimited; anything that is not a whole number
# reads as the default and is said in the log, not died on.
our $BACKUP_RETENTION_DEFAULT = 3;
sub backup_retention {
    my ($lazysite_dir) = @_;
    my $conf = "$lazysite_dir/lazysite.conf";
    return $BACKUP_RETENTION_DEFAULT unless defined $lazysite_dir && -f $conf;
    open my $fh, '<:utf8', $conf or return $BACKUP_RETENTION_DEFAULT;
    my $val = $BACKUP_RETENTION_DEFAULT;
    while ( my $l = <$fh> ) {
        next unless $l =~ /^backup_retention\s*:\s*(.*?)\s*$/;
        my $v = $1;
        # SM782: an EMPTY value is the default, silently - it is how the
        # field ships and what clearing it through the API writes.
        if    ( !length $v )      { $val = $BACKUP_RETENTION_DEFAULT }
        elsif ( $v =~ /\A\d+\z/ ) { $val = $v + 0 }
        else { log_event( 'WARN', 'config', 'backup_retention is not a whole number; using the default', value => $v, default => $BACKUP_RETENTION_DEFAULT ) }
        last;
    }
    close $fh;
    return $val;
}

sub cannot_read {
    my ( $what, $path ) = @_;
    return undef if $!{ENOENT};
    # SM768: read $! BEFORE getpwuid, which is free to reset it - the first
    # version logged `error=` blank, which is the one field the rule exists
    # to carry.
    my $err = "$!";
    my ($who) = getpwuid($>);
    log_event( 'WARN', 'store', "cannot read $what - it exists and this process cannot open it",
        file => $path, error => $err, unix_user => ( $who // $> ) );
    return undef;
}

sub secure_write_perms {
    my ( $path, $mode ) = @_;
    return unless defined $path && length $path;
    chmod $mode, $path if defined $mode;
    ( my $dir = $path ) =~ s{/[^/]+\z}{};
    $dir = '.' unless length $dir;
    my @ds = stat $dir or return;
    my ( $duid, $dgid ) = @ds[ 4, 5 ];
    if ( $> == 0 ) { chown $duid, $dgid, $path }    # root: match the provisioned dir
    else           { chown -1, $dgid, $path }       # non-root: group only, best-effort
    return;
}

# SM619: BECOME the owner of the site tree before writing into it.
#
# The rule this enforces is not new - lazysite-check.pl states it as SM139:
# "lazysite never writes into a site tree as root, because root-owned files
# there are exactly what stops the manager working afterwards". It was enforced
# in exactly one probe. A fleet sweep after the 0.11.0 upgrade found 31 sites
# with 16 identical failures each, every one traceable to a tree owned root:root
# - and one root-run command explains a whole tree, because lazysite/auth is
# setgid (02770): once ITS group is root, everything created beneath it
# afterwards inherits group root, including writes by callers that are
# themselves careful.
#
# secure_write_perms (SM215) is the per-FILE remedy and cannot reach this case:
# it inherits owner and group from the parent directory, so when the parent is
# the thing make_path() just created as root, it faithfully inherits root.
#
# WHOSE identity: the docroot's, read per call. One host serves many sites owned
# by different users, so this is never a constant - it is whatever owns the tree
# being written to, resolved fresh each time.
#
# Returns a hashref: { dropped => 0|1, user, group, why }. NEVER dies - the
# caller decides whether a refusal to drop is fatal, because that answer differs
# between a tool that writes (fatal) and one that only reads (harmless).
# The DECISION half, split out so it can be tested without being root: given a
# tree and an optional --as-user, who should this process become? Returns
# ( uid, gid ) or ( undef, why ). A test can point it at any real directory,
# including a genuinely root-owned one like '/', which is how the refusal path
# gets exercised at all - the alternative was a fake-root environment variable
# inside a privilege-dropping function, which is a worse thing to own.
sub target_identity {
    my ( $docroot, %opt ) = @_;
    my ( $uid, $gid );
    if ( defined $opt{as_user} && length $opt{as_user} ) {
        my @pw = getpwnam $opt{as_user}
            or return ( undef, "no such user '$opt{as_user}'" );
        ( $uid, $gid ) = @pw[ 2, 3 ];
        # An explicit --as-user names the OWNER; the tree still decides the
        # group, so a file lands in the web group the site is provisioned with
        # rather than the user's private group.
        my @ds = stat $docroot;
        $gid = $ds[5] if @ds && $ds[5] != 0;
    }
    else {
        my @ds = stat $docroot
            or return ( undef, "cannot stat '$docroot'" );
        ( $uid, $gid ) = @ds[ 4, 5 ];
        # A root-owned tree cannot say who it belongs to. Guessing here is how
        # the damage spread in the first place, so say so and let the caller
        # refuse - the repair (lazysite-check --fix, as root) is a different
        # tool with a different job.
        return ( undef,
            "the tree at '$docroot' is owned by root, so it cannot say "
                . 'which user to become - repair ownership first '
                . '(lazysite-check.pl --docroot ... --fix, as root), '
                . 'or name the owner with --as-user' )
            if $uid == 0;
    }

    return ( $uid, $gid );
}

sub drop_to_tree_owner {
    my ( $docroot, %opt ) = @_;
    return { dropped => 0, why => 'not running as root' } if $> != 0;

    my ( $uid, $gid ) = target_identity( $docroot, %opt );
    return { dropped => 0, why => $gid } unless defined $uid;

    # ORDER MATTERS AND IS NOT RECOVERABLE. The group must be set while still
    # root: once the UID is dropped the process can no longer change its GID, so
    # a UID-first version would strand the process in root's group with no way
    # back and no error to say so.
    $) = "$gid $gid";    ## no critic (Variables::RequireLocalizedPunctuationVars)
    $( = $gid;           ## no critic (Variables::RequireLocalizedPunctuationVars)
    $> = $uid;           ## no critic (Variables::RequireLocalizedPunctuationVars)
    $< = $uid;           ## no critic (Variables::RequireLocalizedPunctuationVars)

    # Perl does not die when one of those assignments fails, so VERIFY rather
    # than assume. Both real and effective are checked: dropping only the
    # effective ids would leave the privilege reachable again through $> = 0.
    if ( $> != $uid || $< != $uid || $) + 0 != $gid || $( + 0 != $gid ) {
        return {
            dropped => 0,
            why     => "could not drop to uid $uid gid $gid "
                . "(now euid=$>, uid=$<, egid=" . ( $) + 0 ) . ", gid=" . ( $( + 0 ) . ')'
        };
    }

    # 0002, so a new file is group-writable and a new directory group-writable
    # and traversable - what the CGI needs, and what the deploy sets by hand.
    umask 0002;

    return {
        dropped => 1,
        user    => scalar( ( getpwuid $uid )[0] ) // $uid,
        group   => scalar( ( getgrgid $gid )[0] ) // $gid,
    };
}

# Constant-time string compare for timing-safe credential/token checks.
sub const_eq {
    my ( $a, $b ) = @_;
    return 0 unless defined $a && defined $b;
    return 0 if length($a) != length($b);
    my $r = 0;
    $r |= ord( substr( $a, $_, 1 ) ) ^ ord( substr( $b, $_, 1 ) )
        for 0 .. length($a) - 1;
    return $r == 0;
}

# Minimal JSON string escaper for the structured log format.
sub _json_str {
    my ($s) = @_;
    $s //= '';
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r/\\r/g;
    $s =~ s/\t/\\t/g;
    return $s;
}

# Levelled logging to STDERR (text or json), honouring LAZYSITE_LOG_LEVEL and
# LAZYSITE_LOG_FORMAT. Component comes from $COMPONENT. Emitted diagnostics are
# ALSO forwarded to syslog - at WARN and above unless forward_diagnostics says
# otherwise, SM932 (see below). STDERR alone is not a sink this code can verify.
sub log_event {
    my ( $level, $context, $message, %extra ) = @_;
    my $min_level = $ENV{LAZYSITE_LOG_LEVEL} // 'INFO';
    my %rank      = ( DEBUG => 0, INFO => 1, WARN => 2, ERROR => 3 );
    return if ( $rank{$level} // 1 ) < ( $rank{$min_level} // 1 );
    my $ts     = POSIX::strftime( '%Y-%m-%d %H:%M:%S', localtime );
    my $format = $ENV{LAZYSITE_LOG_FORMAT} // 'text';
    no warnings 'uninitialized';    # helper subs in unit tests may pass undef
    my $line;
    if ( $format eq 'json' ) {
        my $pairs = join ',',
            map { '"' . _json_str($_) . '":"' . _json_str( $extra{$_} ) . '"' }
            keys %extra;
        $line = '{"ts":"' . $ts . '"'
            . ',"level":"' . _json_str($level) . '"'
            . ',"component":"' . _json_str($COMPONENT) . '"'
            . ',"context":"' . _json_str($context) . '"'
            . ',"message":"' . _json_str($message) . '"'
            . ( $pairs ? ",$pairs" : '' ) . '}';
    }
    else {
        my $extras = join ' ', map { "$_=" . ( $extra{$_} // '' ) } keys %extra;
        my $ctx    = $context // '';
        $line = "[$ts] [$level] [$COMPONENT] [$ctx] $message";
        $line .= " $extras" if $extras;
    }
    print STDERR "$line\n";
    my %prio = ( DEBUG => 'debug', INFO => 'info', WARN => 'warning', ERROR => 'err' );
    forward_line( 'diag', $prio{$level} // 'info', $line );
    return;
}

# --- External log forwarding (the 'Logging & forwarding' plugin, log.pl) ----
#
# forward_audit / forward_diagnostics / syslog_facility in lazysite.conf control
# best-effort syslog copies of the two streams: audit-trail lines (the pipe
# format, at LOG_INFO) and log_event diagnostics (at their mapped priority).
# Config resolution rides the same path as log_level: an env override wins
# (LAZYSITE_FORWARD_AUDIT / LAZYSITE_FORWARD_DIAGNOSTICS /
# LAZYSITE_SYSLOG_FACILITY), else ONE cheap peek at lazysite.conf per process
# (located via $Lazysite::Audit::LAZYSITE_DIR, else DOCUMENT_ROOT); the result
# is cached, so a request pays at most one small-file read - and syslog is
# only opened when a stream is actually enabled. Sys::Syslog is core Perl.
#
# SM932, ruled 2026-09-30: DIAGNOSTICS FORWARDING IS ON BY DEFAULT, at WARN and
# above. Until this release log_event's only unconditional sink was
# `print STDERR`, and on a stack where a FastCGI child's STDERR does not reach
# the web server's error_log the engine had no reachable voice at all - an
# operator debugging a live site grepped error_log through four failing
# submissions and found nothing, while the same code from a terminal printed the
# cause at once. One unverifiable sink was the whole of it. A second sink does
# not make the first one work; it stops "nothing reached anybody" being the
# default outcome.
#
# The THRESHOLD is WARN rather than everything, and that is measured rather than
# preferred: cannot_read() logs at WARN, so WARN-and-above carries every repair
# the four-state work of 0.15.0 and 0.15.1 produced, while forwarding nothing
# new at INFO means no install's syslog volume changes on upgrade.
#
# forward_audit stays a boolean and stays OFF by default - it is a copy of an
# access record, not a diagnostic, and nobody has been unable to read it.
#
# Forwarding failure NEVER propagates: everything is eval-guarded, with a
# single WARN per process. Test seam (test-only): LAZYSITE_SYSLOG_DUMP=<file>
# appends "<priority> <line>" to that file instead of calling syslog, so tests
# can assert what would have been forwarded without a running syslogd.

my %FWD;                # cached forwarding config (per process)
my $fwd_warned;         # WARN once per process on forwarding TRANSPORT failure
my $fwd_conf_warned;    # WARN once per process on a bad/unreadable forwarding CONFIG
my $syslog_open;

sub _conf_bool {
    my $v = lc( $_[0] // '' );
    return $v =~ /^(?:1|on|yes|true|enabled)$/ ? 1 : 0;
}

# SM932: forward_diagnostics is a LEVEL, not a boolean, and absent means "WARN
# and above" rather than "off". Returns two values:
#   ( minimum rank to forward | undef to forward nothing, unrecognised value | undef )
#
#   absent              => 2   WARN and above - the default this release sets
#   off / 0 / no / false => undef, forward nothing
#   on / 1 / yes / true / all => 0, every level
#   a level name        => that rank (debug info warn|warning error|err)
#
# on/true meaning EVERY level is deliberate and is the backward-compatibility
# half of the change: an operator who switched forwarding on before this release
# asked for the whole stream and still gets exactly it, so no configured install
# changes behaviour. Only an install that never set the key moves, and it moves
# from nothing to WARN and above.
#
# An unrecognised value returns the default AND the offending value, so the
# caller can say so - a value the code silently ignores is the shape
# feedback_a_declaration_the_code_ignores exists to refuse.
sub _conf_diag_rank {
    my $v = lc( $_[0] // '' );
    $v =~ s/\A\s+//;
    $v =~ s/\s+\z//;
    return ( 2,     undef ) if $v eq '';
    return ( undef, undef ) if $v =~ /\A(?:0|off|no|false|disabled)\z/;
    return ( 0,     undef ) if $v =~ /\A(?:1|on|yes|true|enabled|all)\z/;
    my %rank = ( debug => 0, info => 1, warn => 2, warning => 2, error => 3, err => 3 );
    return ( $rank{$v}, undef ) if exists $rank{$v};
    return ( 2,         $v );
}

# The inverse of log_event's level -> syslog priority map, so forward_line can
# apply the diagnostics threshold to a line it only ever sees as a priority.
#
# An unknown priority ranks as err, not info: it is forwarded under every
# setting except "off". The point of this filing is diagnostics that went
# nowhere, so a line we cannot classify is one to pass on rather than drop.
my %SYSLOG_RANK = ( debug => 0, info => 1, warning => 2, err => 3 );

sub _syslog_rank { return $SYSLOG_RANK{ lc( $_[0] // '' ) } // 3 }

# SM932: reported only AFTER %FWD is fully built - never during. log_event calls
# forward_line calls _forward_conf, so warning mid-construction would forward
# against half-set values; by the time this runs $FWD{loaded} short-circuits the
# re-entry and every field has its value. Its own latch, separate from
# $fwd_warned, so a transport failure cannot suppress a config complaint.
sub _forward_conf_warn {
    my ( $message, $path, $detail ) = @_;
    return if $fwd_conf_warned++;
    log_event( 'WARN', 'forwarding', $message,
        file  => ( $path   // '' ),
        error => ( $detail // '' ) );
    return;
}

# Service killswitches (0.9.0): a network surface (MCP, OAuth, the control-API
# token path, token exchange) is OFF unless the operator explicitly enables it in
# lazysite.conf - the same posture WebDAV already has (webdav_enabled, default
# off). $docroot is DOCUMENT_ROOT (lazysite.conf is at $docroot/lazysite/). Absent
# / blank / false value => 0 (disabled). Cheap single-pass read; each surface
# calls this once at request entry.
sub service_enabled {
    my ( $docroot, $key ) = @_;
    return 0 unless defined $docroot && length $docroot && defined $key && length $key;
    open my $fh, '<', Lazysite::Paths::lazysite_dir($docroot) . "/lazysite.conf" or return 0;
    my $val = '';
    while ( my $l = <$fh> ) {
        if ( $l =~ /^\Q$key\E\s*:\s*(\S+)/ ) { $val = $1; last }
    }
    close $fh;
    return _conf_bool($val);
}

sub _forward_conf {
    return \%FWD if $FWD{loaded};
    $FWD{loaded} = 1;
    my %want = (
        audit    => $ENV{LAZYSITE_FORWARD_AUDIT},
        diag     => $ENV{LAZYSITE_FORWARD_DIAGNOSTICS},
        facility => $ENV{LAZYSITE_SYSLOG_FACILITY},
    );
    my ( $conf_path, $conf_error );
    unless ( defined $want{audit} && defined $want{diag} && defined $want{facility} ) {
        my $dir =
            defined $Lazysite::Audit::LAZYSITE_DIR ? $Lazysite::Audit::LAZYSITE_DIR
            : defined $ENV{DOCUMENT_ROOT} ? Lazysite::Paths::lazysite_dir( $ENV{DOCUMENT_ROOT} )
            :                               undef;
        if ( defined $dir ) {
            $conf_path = "$dir/lazysite.conf";

            # SM932: this read decides whether the engine has a second sink, so
            # it may not fail in silence. It had no else branch at all, which is
            # the four-state defect SM917 swept out of the store readers - and
            # the one place it could not be fixed the same way, because
            # cannot_read() logs through log_event and log_event arrives here.
            # $! is captured immediately and reported at the end of the sub.
            if ( open my $fh, '<', $conf_path ) {    # not a store - site config
                while ( my $l = <$fh> ) {
                    $want{audit}    //= $1 if $l =~ /^forward_audit\s*:\s*(\S+)/;
                    $want{diag}     //= $1 if $l =~ /^forward_diagnostics\s*:\s*(\S+)/;
                    $want{facility} //= $1 if $l =~ /^syslog_facility\s*:\s*(\S+)/;
                }
                close $fh;
            }
            elsif ( !$!{ENOENT} ) {
                $conf_error = "$!";
            }
        }
    }
    $FWD{audit} = _conf_bool( $want{audit} );
    my ( $diag_rank, $diag_bad ) = _conf_diag_rank( $want{diag} );
    $FWD{diag} = $diag_rank;
    my $fac = lc( $want{facility} // 'daemon' );
    $fac = 'daemon' unless $fac =~ /^(?:daemon|local[0-7])$/;
    $FWD{facility} = $fac;

    # Both of these are reported through log_event, which re-enters this sub -
    # safe only because %FWD is complete and $FWD{loaded} is already 1. They
    # share one latch: an unreadable conf yields no value to be unrecognised, so
    # the two cannot both be true from the file, and one complaint is enough.
    _forward_conf_warn(
        'cannot read the log forwarding config - forwarding falls back to its defaults',
        $conf_path, $conf_error )
        if defined $conf_error;
    _forward_conf_warn(
        'unrecognised forward_diagnostics value - forwarding WARN and above instead',
        $conf_path, $diag_bad )
        if defined $diag_bad;
    return \%FWD;
}

sub _forward_warn {
    my ($err) = @_;
    $err = defined $err ? "$err" : '';
    $err =~ s/\s+$//;
    # Once per process; incremented BEFORE the nested log_event so its own
    # forward attempt cannot recurse back into a second warning.
    return if $fwd_warned++;
    log_event( 'WARN', 'forwarding', 'log forwarding failed', error => $err );
    return;
}

sub forward_line {
    my ( $stream, $priority, $line ) = @_;
    my $cfg = _forward_conf();

    # SM932: the audit stream stays a boolean; the diagnostics stream carries a
    # THRESHOLD, applied here rather than in log_event because four plugins
    # (audit, form-handler, form-smtp, payment-demo) carry their own log_event
    # copy and call straight into this sub. One gate, five callers.
    if ( $stream eq 'audit' ) {
        return unless $cfg->{audit};
    }
    else {
        return unless defined $cfg->{diag};
        return if _syslog_rank($priority) < $cfg->{diag};
    }
    if ( defined $ENV{LAZYSITE_SYSLOG_DUMP} && length $ENV{LAZYSITE_SYSLOG_DUMP} ) {
        my $ok = eval {
            open my $fh, '>>', $ENV{LAZYSITE_SYSLOG_DUMP} or die "$!\n";
            print {$fh} "$priority $line\n";
            close $fh;
            1;
        };
        _forward_warn("syslog dump: $@") unless $ok;
        return;
    }
    my $ok = eval {
        require Sys::Syslog;
        unless ($syslog_open) {
            Sys::Syslog::openlog( 'lazysite', 'ndelay,pid', $cfg->{facility} );
            $syslog_open = 1;
        }
        Sys::Syslog::syslog( $priority, '%s', $line );
        1;
    };
    _forward_warn($@) unless $ok;
    return;
}

# SM110 phase 2: the host-keyed page cache. An alias host's rendered pages
# live at lazysite/cache/hosts/<host>/<rel>.html (written by the processor,
# mirroring the page's docroot-relative path). Every surface that removes or
# overwrites a page's sibling .html cache must ALSO drop the per-host copies,
# or an alias host keeps serving the stale render after an edit.
#
# unlink_host_copies($docroot, $abs_html): given the SIBLING cache path
# ($docroot/<rel>.html), unlink <rel>.html under every host slot. Returns the
# number removed. Guards against traversal in the rel path (callers pass
# sysop/user-derived paths).
sub unlink_host_copies {
    my ( $docroot, $abs_html ) = @_;
    return 0 unless defined $docroot && length $docroot && defined $abs_html;
    my $hosts = Lazysite::Paths::lazysite_dir($docroot) . "/cache/hosts";
    return 0 unless -d $hosts;
    ( my $rel = $abs_html ) =~ s{^\Q$docroot\E/?}{};
    return 0 unless length $rel && $rel =~ /\.html\z/;
    return 0 if index( $rel, 'lazysite/' ) == 0;                # never a slot path itself
    return 0 if $rel =~ m{(?:^|/)\.\.(?:/|$)} || $rel =~ /\0/;  # no traversal
    my $n = 0;
    opendir my $dh, $hosts or return 0;
    for my $h ( readdir $dh ) {
        next if $h =~ /^\./;
        my $copy = "$hosts/$h/$rel";
        $n++ if -f $copy && unlink $copy;
    }
    closedir $dh;
    return $n;
}

# unlink_host_page($docroot, $host, $rel_html): remove ONE host's copy of a page
# (lazysite/cache/hosts/<host>/<rel>.html), so a per-host cache entry can be
# cleared surgically without touching the other language/domain siblings.
# Returns 1 if a file was removed. Host must be DNS-shaped; the rel path is
# traversal-guarded (callers pass operator/user-derived values).
sub unlink_host_page {
    my ( $docroot, $host, $rel ) = @_;
    return 0 unless defined $docroot && length $docroot;
    return 0 unless defined $host && $host =~ /\A[A-Za-z0-9.-]+\z/ && $host !~ /\.\./;
    ( my $r = ( $rel // '' ) ) =~ s{^/+}{};
    return 0 unless length $r && $r =~ /\.html\z/;
    return 0 if $r =~ m{(?:^|/)\.\.(?:/|$)} || $r =~ /\0/;
    my $copy = Lazysite::Paths::lazysite_dir($docroot) . "/cache/hosts/$host/$r";
    return ( -f $copy && unlink $copy ) ? 1 : 0;
}

# clear_host_cache($docroot): remove the whole hosts tree. Used where a sweep
# already drops every sibling cache (clear-all, theme/layout activation, nav
# change, backup restore) - wholesale removal is the simple, always-correct
# choice there; everything regenerates on the next request per host.
sub clear_host_cache {
    my ($docroot) = @_;
    return 0 unless defined $docroot && length $docroot;
    my $hosts = Lazysite::Paths::lazysite_dir($docroot) . "/cache/hosts";
    return 0 unless -d $hosts;
    require File::Path;
    File::Path::remove_tree( $hosts, { safe => 1 } );
    return 1;
}

1;
