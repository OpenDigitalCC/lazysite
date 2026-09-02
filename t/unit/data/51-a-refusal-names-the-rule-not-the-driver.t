#!/usr/bin/perl
# SM713 and SM730: two refusals that told a caller nothing they could act on.
#
# Both were reported in the same field session as a capability refusal reading
# "Insufficient capability for data-tables (needs manage_data)" - the same kind
# of event answered to very different standards, and the weaker answers in the
# places with less context to fall back on.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Data::Tables    ();
use Lazysite::Manager::Common ();

subtest 'SM713: a database error crosses the wire without the engine internals' => sub {
    my $raw = 'DBD::SQLite::db do failed: no such table: t_demo at '
        . '/home/ispadmin/web/example.com/cgi-bin/../lib/Lazysite/Data/Tables.pm line 453.';
    my $out = Lazysite::Data::Tables::_clean_db_error($raw);

    like( $out, qr/no such table: t_demo/, 'the actionable part survives' );
    unlike( $out, qr{/home/|ispadmin|\.pm|line \d+},
        'the absolute path, the account name, the file and the line are gone' );
    unlike( $out, qr/DBD::|do failed/,
        "and the driver's own vocabulary, which no caller can act on" );

    is( Lazysite::Data::Tables::_clean_db_error(undef),
        'the database refused the operation',
        'an empty error still says something' );
    is( Lazysite::Data::Tables::_clean_db_error('   at /x/y.pm line 9.'),
        'the database refused the operation',
        'and a string that is ONLY internals does not become empty' );
};

subtest 'SM730: a blocked upload names the rule' => sub {
    # The blockers knew why and returned a bare 1. Every caller uses them in
    # boolean context, so a truthy reason changes nothing for them and gives
    # the ones that report to a person something to report.
    my $src = do {
        open my $fh, '<', "$FindBin::Bin/../../../lib/Lazysite/Manager/Common.pm"
            or die $!;
        local $/; <$fh>;
    };
    unlike( $src, qr/'blocked path access'[^;]*;\s*\n\s*return 1;/s,
        'the path blocker no longer returns a bare 1' );
    unlike( $src, qr/blocked by config \(extension\)'[^;]*;\s*\n\s*return 1;/s,
        'nor the extension blocker' );

    my $up = do {
        open my $fh, '<', "$FindBin::Bin/../../../lib/Lazysite/Manager/Upload.pm"
            or die $!;
        local $/; <$fh>;
    };
    unlike( $up, qr/error => 'Blocked target'/,
        'the upload path no longer answers "Blocked target"' );
    like( $up, qr/my \$why = is_blocked_path/,
        'it takes the reason from the blocker rather than inventing one' );
};

done_testing();
