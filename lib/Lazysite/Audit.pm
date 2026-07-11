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

our @EXPORT_OK = qw(audit_log);

our $LAZYSITE_DIR;

my $write_warned;    # WARN once per process, not once per lost entry

sub _warn_once {
    my ( $act, $why ) = @_;
    return if $write_warned++;
    Lazysite::Util::log_event( 'WARN', 'audit',
        'audit write failed - entry lost', action => $act, error => $why );
    return;
}

sub audit_log {
    my ( $user, $act, $target, $ip, $status, $origin, $detail ) = @_;
    return unless defined $LAZYSITE_DIR;
    my $ts = POSIX::strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime );
    $_ = defined $_ ? "$_" : '' for ( $user, $act, $target, $ip, $status, $origin, $detail );
    s/[|\r\n]+/ /g for ( $user, $act, $target, $ip, $status, $origin, $detail );
    # 8th field (detail, e.g. a failure reason) appended only when present, so
    # older 7-field readers/lines stay valid.
    my $line = "$ts | $user | $act | $target | $ip | $status | $origin";
    $line .= " | $detail" if length $detail;

    _append_line( $act, $line );
    # External forwarding (the 'Logging & forwarding' plugin): best-effort,
    # independent of the file append, so an entry that could not land on disk
    # can still reach the operator's syslog.
    Lazysite::Util::forward_line( 'audit', 'info', $line );
    return;
}

# The file append, with every failure mode made LOUD (via _warn_once) instead
# of dropped: unmakeable dir, unopenable/unwritable file, failed print.
sub _append_line {
    my ( $act, $line ) = @_;
    my $dir = "$LAZYSITE_DIR/logs";
    unless ( -d $dir || mkdir($dir) ) {
        _warn_once( $act, "cannot create $dir: $!" );
        return;
    }
    my $file = "$dir/audit.log";
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
