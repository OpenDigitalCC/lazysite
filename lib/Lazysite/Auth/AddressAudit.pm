package Lazysite::Auth::AddressAudit;

# SM1139 (slice B of SM1134): THE AUDIT ROW FOR A REFUSAL BY ADDRESS, once per
# target per address per hour. The ruling (SM1134): "one audit row per refusal per
# address per hour, like SM1115, so a scan cannot fill the trail". SM1115's pattern
# is plugins/form-handler.pl _audit_rate_refusal: a marker per key holding the clock
# hour, written when the row is, and the row skipped while the marker is this hour's.
# This is that pattern for pages, files and the doors that serve them, in one place
# so the processor, WebDAV and the manager API write the same row. SM1140's group
# and manager refusals (Auth::AddressScope::audit_refusal) write through here too,
# so there is one marker store and one row shape for every refusal by address.
#
#   refused( lazysite_dir => $dir, target => '/office/rota', address => $ip,
#            reason => 'not-allowed', lists => ['office'], origin => 'web',
#            user => $name )   # user optional: the account, where the door knows it
#     -> 1 when it wrote the row, 0 when this hour already has one for this target
#        and address (or the marker store could not be opened).
#
# The row is `address-refused <target>`, detail = the reason code decide() gave and
# the list name(s), so the trail says which rule refused without the visitor ever
# being told (the refusal page does not name a list).
#
# THE MARKERS ARE BOUNDED. They live in $lazysite_dir/auth/.address-refused.db
# (DB_File, 0600, as the sign-in limiter's counter is), and the first call of each
# clock hour deletes every marker that is not this hour's, so a scan of ten thousand
# URLs holds ten thousand keys for at most an hour.
#
# A marker store that cannot be opened writes NO row and logs a WARN. The other
# direction - a row for every refused request - is the flood the hourly rule exists
# to stop, and the refusal itself (the 403) does not depend on the audit.

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';
use Fcntl           qw(O_CREAT O_RDWR);
use Lazysite::Util  qw(log_event);
use Lazysite::Audit ();

sub refused (%o) {
    my $dir = $o{lazysite_dir};
    return 0 unless defined $dir && length $dir && -d "$dir/auth";
    my $target  = defined $o{target}  ? $o{target}  : '';
    my $address = defined $o{address} ? $o{address} : '';
    my $hour    = int( time() / 3600 );

    unless ( eval { require DB_File; 1 } ) {
        log_event( 'WARN', $target, 'address refusals are not audited: DB_File is not installed' );
        return 0;
    }
    my %db;
    my $file = "$dir/auth/.address-refused.db";
    eval { tie %db, 'DB_File', $file, O_CREAT | O_RDWR, 0o600 };
    if ( $@ || !tied %db ) {
        log_event( 'WARN', $target, 'address refusals are not audited: the marker store could not be opened',
            file => $file );
        return 0;
    }
    my $key  = "$address $target";
    my $seen = ( $db{$key} // -1 ) == $hour;
    unless ($seen) {
        for my $k ( keys %db ) { delete $db{$k} if ( $db{$k} // -1 ) != $hour }
        $db{$key} = $hour;
    }
    untie %db;
    return 0 if $seen;

    my $lists = join ',', @{ ref $o{lists} eq 'ARRAY' ? $o{lists} : [] };
    no warnings 'once';
    local $Lazysite::Audit::LAZYSITE_DIR = $dir;
    Lazysite::Audit::audit_log( ( $o{user} // '' ), 'address-refused', $target, $address, 'fail',
        ( $o{origin} // 'web' ), join( '; ', grep { length } ( $o{reason}, length $lists ? "lists $lists" : '' ) ) );
    return 1;
}

1;
