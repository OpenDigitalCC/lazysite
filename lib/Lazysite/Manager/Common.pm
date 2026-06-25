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

our @EXPORT_OK = qw(validate_path is_blocked_path write_file_checked respond
    is_blocked_config is_blocked_upload_target upload_limits load_upload_limits _reset_upload_limits_cache
    _write_conf_key);

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
    # encode_json already emits UTF-8 bytes; print raw (a :utf8 layer would
    # double-encode non-ASCII content into mojibake).
    binmode( STDOUT );
    print "Status: 200 OK\r\n";
    print "Content-Type: application/json; charset=utf-8\r\n\r\n";
    print encode_json($data);
}

our $_upload_limits_cache;

sub load_upload_limits {
    my %limits = (
        max_bytes          => 10 * 1024 * 1024,
        blocked_paths      => [ qw(
            lazysite/auth lazysite/forms lazysite/cache
            lazysite/manager cgi-bin manager
        ) ],
        blocked_extensions => [ qw(pl cgi) ],
        rate_count         => 60,
        rate_bytes         => 500 * 1024 * 1024,
    );

    my $conf_path = "$DOCROOT/lazysite/lazysite.conf";
    return \%limits unless -f $conf_path;

    my $new_key_seen = 0;
    my $old_key_seen = 0;
    open my $fh, '<', $conf_path or return \%limits;
    while (<$fh>) {
        if ( /^manager_upload_max_mb\s*:\s*(\S+)/ ) {
            my $mb = $1;
            if ( $mb =~ /^\d+$/ && $mb > 0 ) {
                $limits{max_bytes} = $mb * 1024 * 1024;
            } else {
                log_event( 'WARN', 'config',
                    'invalid manager_upload_max_mb', value => $mb );
            }
        }
        elsif ( /^manager_blocked_paths\s*:\s*(.+)/ ) {
            my $v = $1;
            $v =~ s/\s+$//;
            if ( length $v ) {
                $limits{blocked_paths} = [
                    map  { my $p = $_; $p =~ s{^/+|/+$}{}g; $p }
                    grep { length }
                    split /\s*,\s*/, $v
                ];
            }
            $new_key_seen = 1;
        }
        elsif ( /^manager_upload_blocked_paths\s*:\s*(.+)/ ) {
            # Deprecated alias; only honoured if the new key
            # is absent. The new-key check happens after the
            # loop because they may appear in either order.
            my $v = $1;
            $v =~ s/\s+$//;
            if ( length $v ) {
                $limits{_deprecated_blocked_paths} = [
                    map  { my $p = $_; $p =~ s{^/+|/+$}{}g; $p }
                    grep { length }
                    split /\s*,\s*/, $v
                ];
            }
            $old_key_seen = 1;
        }
        elsif ( /^manager_upload_blocked_extensions\s*:\s*(.+)/ ) {
            my $v = $1;
            $v =~ s/\s+$//;
            if ( length $v ) {
                $limits{blocked_extensions} = [
                    map  { lc $_ }
                    grep { length }
                    split /\s*,\s*/, $v
                ];
            }
        }
        elsif ( /^manager_upload_rate_count\s*:\s*(\S+)/ ) {
            my $n = $1;
            if ( $n =~ /^\d+$/ ) {
                $limits{rate_count} = $n + 0;
            } else {
                log_event( 'WARN', 'config',
                    'invalid manager_upload_rate_count', value => $n );
            }
        }
        elsif ( /^manager_upload_rate_mb\s*:\s*(\S+)/ ) {
            my $mb = $1;
            if ( $mb =~ /^\d+$/ ) {
                $limits{rate_bytes} = $mb * 1024 * 1024;
            } else {
                log_event( 'WARN', 'config',
                    'invalid manager_upload_rate_mb', value => $mb );
            }
        }
    }
    close $fh;

    # Apply the deprecated alias only if the new key was not set.
    # Log INFO so operators know to rename.
    if ( $old_key_seen && !$new_key_seen
        && exists $limits{_deprecated_blocked_paths} ) {
        $limits{blocked_paths} = delete $limits{_deprecated_blocked_paths};
        log_event( 'INFO', 'config',
            'manager_upload_blocked_paths is deprecated; '
          . 'rename to manager_blocked_paths in lazysite.conf' );
    }
    delete $limits{_deprecated_blocked_paths};

    return \%limits;
}

sub upload_limits {
    $_upload_limits_cache //= load_upload_limits();
    return $_upload_limits_cache;
}

sub is_blocked_config {
    my ( $rel_path, $check_extensions ) = @_;
    my $limits = upload_limits();

    for my $prefix ( @{ $limits->{blocked_paths} } ) {
        next unless length $prefix;
        if ( $rel_path eq $prefix
            || index( $rel_path, "$prefix/" ) == 0 ) {
            log_event( 'WARN', $action, 'blocked by config (path)',
                path => $rel_path, prefix => $prefix,
                user => $auth_user );
            return 1;
        }
    }

    return 0 unless $check_extensions;

    my ($ext) = $rel_path =~ /\.([^.\/]+)$/;
    if ( defined $ext ) {
        my $lc = lc $ext;
        for my $blocked ( @{ $limits->{blocked_extensions} } ) {
            if ( $lc eq $blocked ) {
                log_event( 'WARN', $action,
                    'blocked by config (extension)',
                    path => $rel_path, extension => $lc,
                    user => $auth_user );
                return 1;
            }
        }
    }
    return 0;
}

sub is_blocked_upload_target {
    my ($rel_path) = @_;
    return is_blocked_config( $rel_path, 1 );
}

sub _reset_upload_limits_cache { $_upload_limits_cache = undef }

sub _write_conf_key {
    my ( $key, $value ) = @_;
    return 0 unless defined $key && length $key && defined $value && length $value;
    return 0 unless $key =~ /^[A-Za-z_][A-Za-z0-9_-]*$/;

    my $conf_path = "$DOCROOT/lazysite/lazysite.conf";
    my $content   = '';
    if ( -f $conf_path ) {
        open my $fh, '<:utf8', $conf_path or return 0;
        $content = do { local $/; <$fh> };
        close $fh;
    }

    if ( $content =~ /^$key\s*:/m ) {
        $content =~ s/^$key\s*:.*$/$key: $value/m;
    }
    else {
        $content =~ s/\n?$/\n/;
        $content .= "$key: $value\n";
    }

    my ( $ok, $err ) = write_file_checked( $conf_path, $content );
    return $ok ? 1 : 0;
}

1;
