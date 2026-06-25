package Lazysite::Audit;

# SM078/SM077: the shared audit-trail writer. Every state-changing path - the
# manager control API (cookie ui / token api), WebDAV (dav), and the MCP server
# (mcp) - appends here so the trail is complete regardless of entry point.
# Format: ts | user | action | target | ip | status | origin. Origin is last so
# older 5-/6-field readers keep their column positions. Context: $LAZYSITE_DIR.

use strict;
use warnings;
use POSIX ();
use Exporter 'import';

our @EXPORT_OK = qw(audit_log);

our $LAZYSITE_DIR;

sub audit_log {
    my ( $user, $act, $target, $ip, $status, $origin, $detail ) = @_;
    return unless defined $LAZYSITE_DIR;
    my $dir = "$LAZYSITE_DIR/logs";
    return unless -d $dir || mkdir($dir);
    my $ts = POSIX::strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime );
    $_ = defined $_ ? "$_" : '' for ( $user, $act, $target, $ip, $status, $origin, $detail );
    s/[|\r\n]+/ /g for ( $user, $act, $target, $ip, $status, $origin, $detail );
    open my $fh, '>>', "$dir/audit.log" or return;
    # 8th field (detail, e.g. a failure reason) appended only when present, so
    # older 7-field readers/lines stay valid.
    my $line = "$ts | $user | $act | $target | $ip | $status | $origin";
    $line .= " | $detail" if length $detail;
    print {$fh} "$line\n";
    close $fh;
    return;
}

1;
