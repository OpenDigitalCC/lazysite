package Lazysite::Manager::Common;

# Shared path / deny / write / respond helpers for the manager (SM079). The
# per-request ambient context ($DOCROOT, $action, $auth_user) is set by the
# dispatcher as package variables, so the handler bodies that use these helpers
# move verbatim. The deny list @BLOCKED_PATHS is owned here.

use strict;
use warnings;
use Cwd qw(realpath);
use File::Basename qw(dirname);
use JSON::PP qw(encode_json);
use Lazysite::Util qw(log_event);
use Exporter 'import';

our @EXPORT_OK = qw(validate_path is_blocked_path write_file_checked respond);

our $DOCROOT;          # set by the script
our $action    = '';   # current request action (for log attribution)
our $auth_user = '';   # current request user (for log attribution)

our @BLOCKED_PATHS = (
    'lazysite/auth/.secret',
    'lazysite/forms/.secret',
    'lazysite/auth/users',
    'lazysite/auth/groups',
    'lazysite/auth/user-settings.json',
);

# Resolve a relative path under DOCROOT, rejecting traversal (realpath must stay
# within DOCROOT). Returns { ok, full, rel } or { ok=>0, error }.
sub validate_path {
    my ($rel_path) = @_;
    return { ok => 0, error => "No path" } unless $rel_path;

    $rel_path =~ s{^/+}{};

    my $full = "$DOCROOT/$rel_path";
    my $check = -e $full ? $full : dirname($full);
    my $real = realpath($check);

    return { ok => 0, error => "Invalid path" }
        unless $real && index( $real, $DOCROOT ) == 0;

    return { ok => 1, full => $full, rel => $rel_path };
}

# The hard deny list (exact paths) plus the *.pl rule.
sub is_blocked_path {
    my ($rel_path) = @_;
    for my $blocked (@BLOCKED_PATHS) {
        if ( $rel_path eq $blocked ) {
            log_event( 'WARN', $action, 'blocked path access', path => $rel_path, user => $auth_user );
            return 1;
        }
    }
    if ( $rel_path =~ /\.pl$/ ) {
        log_event( 'WARN', $action, 'blocked path access', path => $rel_path, user => $auth_user );
        return 1;
    }
    return 0;
}

# Write a file, cleaning up the partial on any failure. Returns (ok, error).
sub write_file_checked {
    my ( $path, $content ) = @_;
    open my $fh, '>:utf8', $path
        or return ( 0, "Cannot write file: $!" );
    unless ( print {$fh} $content ) {
        my $err = "$!";
        close $fh;
        unlink $path;
        return ( 0, "Write failed: $err" );
    }
    unless ( close $fh ) {
        my $err = "$!";
        unlink $path;
        return ( 0, "Close failed: $err" );
    }
    return ( 1, undef );
}

# Emit a JSON response (200).
sub respond {
    my ($data) = @_;
    binmode( STDOUT, ':utf8' );
    print "Status: 200 OK\r\n";
    print "Content-Type: application/json; charset=utf-8\r\n\r\n";
    print encode_json($data);
}

1;
