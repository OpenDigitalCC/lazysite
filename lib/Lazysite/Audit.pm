package Lazysite::Audit;

# SM078/SM077: the shared audit-trail writer. Every state-changing path - the
# manager control API (cookie ui / token api), WebDAV (dav), the MCP server
# (mcp), and the users tool run from the shell (cli) - appends here so the
# trail is complete regardless of entry point.
# Format: ts | user | action | target | ip | status | origin. Origin is last so
# older 5-/6-field readers keep their column positions. Context: $LAZYSITE_DIR.
#
# One entry per material operation (audit-completeness round): each web
# surface audits its own requests (manager-api's generic POST block, the auth
# wrapper's _audit_auth, dav, mcp, oauth). The users tool audits inside its
# cmd_* functions ONLY when invoked from the command line - under --api its
# entries are suppressed, because the calling surface has already recorded the
# request with the real web actor, origin and client IP. So a given operation
# yields exactly one line whichever door it came through.
#
# Robustness (the 0.7.5 field defect): the log is created umask-proof at 0664
# (sysopen + chmod), so on the setgid logs dir a CLI-created file stays
# appendable by the www-data CGI and vice versa; an owned file that lost its
# group-write bit is healed before appending; and a failed write is never
# silent - it WARNs through log_event (once per process) naming the lost
# action. The append itself stays a single print (atomic under PIPE_BUF).
# install.pl carries a format-matched inline copy of this writer (it must not
# load the lib) - keep the two in sync.

use strict;
use warnings;
use POSIX ();
use Fcntl qw(O_WRONLY O_APPEND O_CREAT);
use Exporter 'import';
use Lazysite::Util ();

our @EXPORT_OK = qw(audit_log audit_read_log audit_trail_state audit_reads_state records_read);

our $LAZYSITE_DIR;

my $write_warned;    # WARN once per process, not once per lost entry

sub _warn_once {
    my ( $act, $why ) = @_;
    return if $write_warned++;
    Lazysite::Util::log_event( 'WARN', 'audit',
        'audit write failed - entry lost', action => $act, error => $why );
    return;
}

# THE AUDIT TRAIL'S OWN SWITCH (SM222, ruled 2026-09-10 and 2026-09-11).
#
# `audit_trail: off` in lazysite.conf stops the trail recording. It is its own
# setting rather than an extension toggle, because the registry cannot say "on
# unless switched off": `extensions:` lists what is on, and absence there means both
# "switched off" and "never asked". So here ABSENCE IS ON, and only an explicit
# `off` stops it. A value that is neither on nor off also reads as ON - an audit
# trail that cannot tell what it was told keeps recording, which is the safe way
# to be wrong.
#
# OFF STOPS COLLECTION AND KEEPS WHAT WAS COLLECTED (SM798's ruling). Nothing here
# touches the file that exists.
#
# The form handler writes audit lines without loading this module, so it carries
# a marked copy of this reader; t/lint/130 runs both over the same confs.
my %_TRAIL_MEMO;    # conf path => [ mtime, size, state ]

sub audit_trail_state {
    my ($lzdir) = @_;
    $lzdir //= $LAZYSITE_DIR;
    return 'on' unless defined $lzdir;
    my $conf = "$lzdir/lazysite.conf";
    my @st   = stat $conf;
    return 'on' unless @st;
    my $memo = $_TRAIL_MEMO{$conf};
    return $memo->[2] if $memo && $memo->[0] == $st[9] && $memo->[1] == $st[7];
    my $state = 'on';
    if ( open my $fh, '<', $conf ) {
        while ( my $l = <$fh> ) {
            next unless $l =~ /^audit_trail\s*:\s*(\S+)\s*$/;
            $state = lc($1) eq 'off' ? 'off' : 'on';
        }
        close $fh;
    }
    $_TRAIL_MEMO{$conf} = [ $st[9], $st[7], $state ];
    return $state;
}

# SM1325 (ruling 50, T-17): THE READ AUDIT, BY CHOICE.
#
# SM943 ruling 1 keeps a successful read off the trail - site activity, and
# noise. A site may ask for the reads of its pages and files by an AI (an MCP
# tool or a control-API token) to be recorded as well: `audit_reads: on` in
# lazysite.conf. Here ABSENCE IS OFF, the other way round from the trail's own
# switch, because this one records more about who read what: only an explicit
# `on` (or true/yes/enabled) turns it on, and a value it cannot read is off.
#
# ITS OWN FILE (ruling 97): logs/audit-reads.log, beside audit.log, rotated by
# the same logrotate stanza (lazysite/logs/*.log) and forwarded as the trail
# is - so reads never push a change off the Audit page's change view, which
# keeps the newest 5,000 rows. `audit_trail: off` stops it too. The manager
# switches it (ruling 96) with the trail's own gate: Manager::Config.
#
# THE READS, named once for both doors: the ones that hand back a page's or a
# file's content. A listing, a search or a status is not one.
our %CONTENT_READ = (
    api => { map { $_ => 1 } qw(git-show) },    # file-download is audited always
    mcp => { map { $_ => 1 } qw(read_file read_page view_version preview_page) },
);
my %_READS_MEMO;                                # conf path => [ mtime, size, state ]

sub audit_reads_state {
    my ($lzdir) = @_;
    $lzdir //= $LAZYSITE_DIR;
    return 'off' unless defined $lzdir;
    my $conf = "$lzdir/lazysite.conf";
    my @st   = stat $conf;
    return 'off' unless @st;
    my $memo = $_READS_MEMO{$conf};
    return $memo->[2] if $memo && $memo->[0] == $st[9] && $memo->[1] == $st[7];
    my $state = 'off';
    if ( open my $fh, '<', $conf ) {
        while ( my $l = <$fh> ) {
            next unless $l =~ /^audit_reads\s*:\s*(\S*)\s*$/;
            $state = ( $1 =~ /\A(?:on|true|yes|enabled)\z/i ) ? 'on' : 'off';
        }
        close $fh;
    }
    $_READS_MEMO{$conf} = [ $st[9], $st[7], $state ];
    return $state;
}

# Is this successful read on this door one the site asked to have recorded?
sub records_read {
    my ( $origin, $name, $lzdir ) = @_;
    return 0 unless defined $origin && defined $name && $CONTENT_READ{$origin}{$name};
    return audit_reads_state($lzdir) eq 'on' ? 1 : 0;
}

# SM1325: one successful read, on its own file (see above). The line is the
# trail's shape, status `ok`, so one parser reads both.
sub audit_read_log {
    my ( $user, $act, $target, $ip, $origin ) = @_;
    return unless defined $LAZYSITE_DIR;
    return if audit_trail_state() eq 'off';
    my $line = _line( $user, $act, $target, $ip, 'ok', $origin, '' );
    _append_line( $act, $line, 'audit-reads.log' );
    Lazysite::Util::forward_line( 'audit', 'info', $line );
    return;
}

sub _line {
    my ( $user, $act, $target, $ip, $status, $origin, $detail ) = @_;
    my $ts = POSIX::strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime );
    $_ = defined $_ ? "$_" : '' for ( $user, $act, $target, $ip, $status, $origin, $detail );
    s/[|\r\n]+/ /g for ( $user, $act, $target, $ip, $status, $origin, $detail );
    # 8th field (detail, e.g. a failure reason) appended only when present, so
    # older 7-field readers/lines stay valid.
    my $line = "$ts | $user | $act | $target | $ip | $status | $origin";
    $line .= " | $detail" if length $detail;
    return $line;
}

sub audit_log {
    my ( $user, $act, $target, $ip, $status, $origin, $detail ) = @_;
    return unless defined $LAZYSITE_DIR;
    return if audit_trail_state() eq 'off';    # the switch: see above
    my $line = _line( $user, $act, $target, $ip, $status, $origin, $detail );

    _append_line( $act, $line );
    # External forwarding (the 'Logging & forwarding' extension): best-effort,
    # independent of the file append, so an entry that could not land on disk
    # can still reach the operator's syslog.
    Lazysite::Util::forward_line( 'audit', 'info', $line );
    return;
}

# The file append, with every failure mode made LOUD (via _warn_once) instead
# of dropped: unmakeable dir, unopenable/unwritable file, failed print.
sub _append_line {
    my ( $act, $line, $name ) = @_;
    my $dir = "$LAZYSITE_DIR/logs";
    unless ( -d $dir || mkdir($dir) ) {
        _warn_once( $act, "cannot create $dir: $!" );
        return;
    }
    my $file = "$dir/" . ( $name // 'audit.log' );
    my @s    = stat $file;
    # Self-heal: a file created 0644 by an older writer (or a stray umask)
    # locks the other identity out; if we own it, restore group-append now.
    if ( @s && !( $s[2] & 0020 ) && $s[4] == $> ) {
        chmod 0664, $file;
    }
    my $fh;
    unless ( sysopen $fh, $file, O_WRONLY | O_APPEND | O_CREAT, 0664 ) {
        _warn_once( $act, "cannot append to $file: $!" );
        return;
    }
    # sysopen's mode is still filtered by the umask - re-assert 0664 on the
    # file we just created so the group (www-data on a setgid logs dir) can
    # append from the other identity.
    chmod 0664, $file unless @s;
    print {$fh} "$line\n"
        or _warn_once( $act, "write to $file failed: $!" );
    close $fh;
    return;
}

1;
