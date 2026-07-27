package Lazysite::Util;

# Shared helpers for the modular lazysite scripts (auth, dav, manager-api, the
# users tool). The processor stays self-contained and does NOT use this module -
# see docs/feature-requests/SM079-modular-refactor.md.
#
# Each script sets $Lazysite::Util::COMPONENT after `use`, so log lines are
# attributed to the right component.

use strict;
use warnings;
use POSIX ();
use Exporter 'import';

our @EXPORT_OK = qw(log_event const_eq unlink_host_copies unlink_host_page clear_host_cache forward_line service_enabled secure_write_perms);

our $COMPONENT = 'lazysite';

# SM215: make a just-written file owner/group/mode-safe so a helper run under sudo
# (as root) never leaves a file the web-server (www-data) CGI cannot access. The
# parent directory is provisioned <site-user>:<web-group> (and is setgid), so we
# INHERIT owner+group from it rather than hard-code www-data: as root, chown both
# (only root can); unprivileged, set the group only (best-effort - a non-root CLI
# is normally already the file's owner, and chown-to-another-user would just fail).
# Call on the temp file BEFORE rename (same directory), or on the final path. Mode
# is applied explicitly. Best-effort throughout: never dies on a chown/chmod fail.
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
# LAZYSITE_LOG_FORMAT. Component comes from $COMPONENT. Emitted diagnostics
# are also forwarded to syslog when forward_diagnostics is on (see below).
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
# forward_audit / forward_diagnostics / syslog_facility in lazysite.conf turn
# on best-effort syslog copies of the two streams: audit-trail lines (the pipe
# format, at LOG_INFO) and log_event diagnostics (at their mapped priority).
# Config resolution rides the same path as log_level: an env override wins
# (LAZYSITE_FORWARD_AUDIT / LAZYSITE_FORWARD_DIAGNOSTICS /
# LAZYSITE_SYSLOG_FACILITY), else ONE cheap peek at lazysite.conf per process
# (located via $Lazysite::Audit::LAZYSITE_DIR, else DOCUMENT_ROOT); the result
# is cached, so a request pays at most one small-file read - and syslog is
# only opened when a stream is actually enabled. Sys::Syslog is core Perl.
#
# Forwarding failure NEVER propagates: everything is eval-guarded, with a
# single WARN per process. Test seam (test-only): LAZYSITE_SYSLOG_DUMP=<file>
# appends "<priority> <line>" to that file instead of calling syslog, so tests
# can assert what would have been forwarded without a running syslogd.

my %FWD;           # cached forwarding config (per process)
my $fwd_warned;    # WARN once per process on forwarding failure
my $syslog_open;

sub _conf_bool {
    my $v = lc( $_[0] // '' );
    return $v =~ /^(?:1|on|yes|true|enabled)$/ ? 1 : 0;
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
    open my $fh, '<', "$docroot/lazysite/lazysite.conf" or return 0;
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
    unless ( defined $want{audit} && defined $want{diag} && defined $want{facility} ) {
        my $dir =
            defined $Lazysite::Audit::LAZYSITE_DIR ? $Lazysite::Audit::LAZYSITE_DIR
            : defined $ENV{DOCUMENT_ROOT}          ? "$ENV{DOCUMENT_ROOT}/lazysite"
            :                                        undef;
        if ( defined $dir && open my $fh, '<', "$dir/lazysite.conf" ) {
            while ( my $l = <$fh> ) {
                $want{audit}    //= $1 if $l =~ /^forward_audit\s*:\s*(\S+)/;
                $want{diag}     //= $1 if $l =~ /^forward_diagnostics\s*:\s*(\S+)/;
                $want{facility} //= $1 if $l =~ /^syslog_facility\s*:\s*(\S+)/;
            }
            close $fh;
        }
    }
    $FWD{audit} = _conf_bool( $want{audit} );
    $FWD{diag}  = _conf_bool( $want{diag} );
    my $fac = lc( $want{facility} // 'daemon' );
    $fac = 'daemon' unless $fac =~ /^(?:daemon|local[0-7])$/;
    $FWD{facility} = $fac;
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
    return unless $cfg->{ $stream eq 'audit' ? 'audit' : 'diag' };
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
# operator/user-derived paths).
sub unlink_host_copies {
    my ( $docroot, $abs_html ) = @_;
    return 0 unless defined $docroot && length $docroot && defined $abs_html;
    my $hosts = "$docroot/lazysite/cache/hosts";
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
    my $copy = "$docroot/lazysite/cache/hosts/$host/$r";
    return ( -f $copy && unlink $copy ) ? 1 : 0;
}

# clear_host_cache($docroot): remove the whole hosts tree. Used where a sweep
# already drops every sibling cache (clear-all, theme/layout activation, nav
# change, backup restore) - wholesale removal is the simple, always-correct
# choice there; everything regenerates on the next request per host.
sub clear_host_cache {
    my ($docroot) = @_;
    return 0 unless defined $docroot && length $docroot;
    my $hosts = "$docroot/lazysite/cache/hosts";
    return 0 unless -d $hosts;
    require File::Path;
    File::Path::remove_tree( $hosts, { safe => 1 } );
    return 1;
}

1;
