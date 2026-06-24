package Lazysite::Auth::Settings;

# Per-user access-mechanism settings (lazysite/auth/user-settings.json) and the
# single-use consume lock, shared by the users tool and the dav endpoint
# (SM079). Context is $AUTH_DIR, set by each script after `use`.

use strict;
use warnings;
use Fcntl qw(:flock);
use Lazysite::Util qw(log_event);
use Exporter 'import';

our @EXPORT_OK = qw(read_settings write_settings _consume_lock);

our $AUTH_DIR;    # "$DOCROOT/lazysite/auth", set by the script

sub _settings_file { "$AUTH_DIR/user-settings.json" }

# JSON object keyed by username. Unparseable content yields defaults (empty)
# plus a WARN, so a corrupt file cannot wedge management.
sub read_settings {
    require JSON::PP;
    my $file = _settings_file();
    return {} unless -f $file;
    open my $fh, '<:utf8', $file or do {
        log_event( 'WARN', 'settings', 'cannot read user-settings.json', error => "$!" );
        return {};
    };
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $data = eval { JSON::PP::decode_json( $raw // '{}' ) };
    if ( !$data || ref $data ne 'HASH' ) {
        log_event( 'WARN', 'settings', 'user-settings.json unparseable; using defaults' );
        return {};
    }
    return $data;
}

# Single writer; write-temp-then-rename. Group-writable (0660) so the CLI and a
# www-data CGI both manage it.
sub write_settings {
    my ($data) = @_;
    require JSON::PP;
    my $file = _settings_file();
    my $json = JSON::PP->new->canonical->pretty->encode($data);
    my $tmp  = "$file.tmp.$$";
    open my $fh, '>:utf8', $tmp or die "Cannot write $file: $!\n";
    flock( $fh, LOCK_EX );
    print {$fh} $json;
    flock( $fh, LOCK_UN );
    close $fh;
    chmod 0660, $tmp;
    rename $tmp, $file
        or die "Cannot rename settings file into place: $!\n";
}

# Exclusive lock held until the returned handle goes out of scope (the caller's
# function returns) or the process exits - serialises single-use redemption so
# the same secret cannot be consumed twice. Fail-open (undef) if unlockable.
sub _consume_lock {
    my $path = "$AUTH_DIR/.consume.lock";
    open my $lk, '>', $path or return undef;
    flock( $lk, LOCK_EX ) or do { close $lk; return undef };
    return $lk;
}

1;
