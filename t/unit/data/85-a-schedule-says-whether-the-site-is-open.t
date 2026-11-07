#!/usr/bin/perl
# SM1356: A SCHEDULE - weekly opening periods and their exceptions - says, at a
# given moment and in the site's time zone, whether the site is open, when that
# changes, and what is coming.
#
# Held here, against the module and through the data layer's own doors:
#
#   * a `schedule: true` table has the engine's fields; a descriptor may not
#     redeclare them, and a row the schedule could not read is refused at the
#     write, by name;
#   * "open now" across a period boundary - including two periods on one day
#     and one that runs past midnight - and `expires`, the next change of
#     state (or local midnight), which is how long a page showing it may be
#     cached;
#   * an exception: a closed date replaces the week's hours, other hours
#     replace them, and the next exception is the one still to come;
#   * the site's zone across a change of the clocks, spring and autumn, read
#     from the zone itself (Europe/London, 2026: 29 March and 25 October);
#   * a zone the host does not know is UTC, and says so.
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use Time::Local qw(timegm);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(setup_test_site site_tempdir);

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}
use Lazysite::Data::Descriptor qw(load_descriptor);
use Lazysite::Data::Schedule   ();
use Lazysite::Data::Tables     qw(apply_schema insert_row update_row read_rows);

plan skip_all => 'the host has no zoneinfo for Europe/London'
    unless Lazysite::Data::Schedule::valid_zone('Europe/London');

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

my $TZ = 'Europe/London';
sub at { my ( $y, $mo, $d, $h, $mi ) = @_; return timegm( 0, $mi, $h, $d, $mo - 1, $y ) }    # UTC

my @week = (
    { kind => 'period', day => 'mon', opens => '09:00', closes => '12:00' },
    { kind => 'period', day => 'mon', opens => '13:00', closes => '17:00' },
    { kind => 'period', day => 'tue', opens => '09:00', closes => '17:00' },
    { kind => 'period', day => 'fri', opens => '18:00', closes => '01:00' },    # past midnight
);

subtest 'the table: the engine\'s fields, its own refusals' => sub {
    my $d = load_descriptor( 'opening', { title => 'Opening hours', schedule => 'true', public => 'true' } );
    ok( $d->{ok}, 'a schedule needs no fields of its own' ) or diag explain $d;
    ok( $d->{schedule}, 'and says it is one' );
    is_deeply( [ sort keys %{ $d->{fields} } ],
        [qw(closed closes date_from date_until day kind note opens)], 'the engine gives it its fields' );
    is( $d->{key}, 'id', 'keyed by an automatic id' );

    my $clash = load_descriptor( 'opening', { schedule => 'true', fields => { opens => { type => 'text' } } } );
    ok( !$clash->{ok}, 'a descriptor redeclaring one of them is refused' );
    like( $clash->{error}, qr/'opens' is one of a schedule's own fields/, 'by name' );

    my $extra = load_descriptor( 'opening', { schedule => 'true', fields => { venue => { type => 'text' } } } );
    ok( $extra->{ok} && $extra->{fields}{venue}, 'a field of its own beside them is kept' );

    my $keyed = load_descriptor( 'opening', { schedule => 'true', key => 'note' } );
    ok( !$keyed->{ok}, 'a key other than the automatic id is refused' );

    my $plain = load_descriptor( 'plain', { fields => { a => { type => 'text' } } } );
    ok( !exists $plain->{schedule}, 'a table that does not say schedule is not one' );
};

subtest 'a row the schedule could not read is refused at the write' => sub {
    my $docroot = site_tempdir();
    setup_test_site($docroot);
    make_path("$docroot/lazysite/db/tables");
    spit( "$docroot/lazysite/db/tables/opening.yaml", "title: Opening hours\nschedule: true\n" );
    ok( apply_schema( $docroot, 'opening' )->{ok}, 'the schedule table is created' );

    my $ok = insert_row( $docroot, 'opening', { kind => 'period', day => 'mon', opens => '09:00', closes => '17:00' } );
    ok( $ok->{ok}, 'a period is written' ) or diag explain $ok;

    my $bad = insert_row( $docroot, 'opening', { kind => 'period', day => 'mon', opens => '9am', closes => '17:00' } );
    ok( !$bad->{ok}, 'a time that is not HH:MM is refused' );
    like( $bad->{error}, qr/opens '9am' is not a time/, 'naming the field and the value' );
    is( $bad->{rule}, 'schedule', 'as a schedule refusal' );

    my $noday = insert_row( $docroot, 'opening', { kind => 'period', opens => '09:00', closes => '17:00' } );
    like( $noday->{error} // '', qr/a period needs day/, 'a period with no day is refused' );

    my $neither = insert_row( $docroot, 'opening', { kind => 'exception', date_from => '2026-12-25' } );
    like( $neither->{error} // '', qr/either closed or has other hours/, 'an exception that is neither closed nor other hours is refused' );

    my $backwards = insert_row( $docroot, 'opening',
        { kind => 'exception', date_from => '2026-12-25', date_until => '2026-12-24', closed => 'true' } );
    like( $backwards->{error} // '', qr/date_until .* is before date_from/, 'a range that ends before it starts is refused' );

    my $upd = update_row( $docroot, 'opening', $ok->{key}, { closes => '25:00' }, as => 'operator' );
    ok( !$upd->{ok}, 'an update is held to the same times' );
    my $rows = read_rows( $docroot, 'opening', as => 'operator' );
    is( scalar @{ $rows->{rows} }, 1, 'and nothing refused was written' );
};

subtest 'open now, across a period boundary' => sub {
    # Monday 2 March 2026 (GMT, no summer time yet).
    my $s = Lazysite::Data::Schedule::state( \@week, $TZ, at( 2026, 3, 2, 11, 59 ) );
    ok( $s->{open}, '11:59 on a Monday is open' );
    is( $s->{label}, 'Open now until 12:00', 'until the morning period closes' );
    is( $s->{expires}, at( 2026, 3, 2, 12, 0 ), 'and expires as it closes' );

    $s = Lazysite::Data::Schedule::state( \@week, $TZ, at( 2026, 3, 2, 12, 0 ) );
    ok( !$s->{open}, '12:00 is the lunch closure' );
    is( $s->{label}, 'Opens at 13:00', 'and opens again at 13:00' );
    is( $s->{expires}, at( 2026, 3, 2, 13, 0 ), 'which is when it expires' );

    $s = Lazysite::Data::Schedule::state( \@week, $TZ, at( 2026, 3, 2, 17, 30 ) );
    is( $s->{label}, 'Opens tomorrow at 09:00', 'after the last period, tomorrow' );
    is( $s->{expires}, at( 2026, 3, 3, 0, 0 ), 'expiring at midnight, when "tomorrow" becomes "today"' );

    $s = Lazysite::Data::Schedule::state( \@week, $TZ, at( 2026, 3, 3, 17, 30 ) );
    is( $s->{label}, 'Opens Friday at 18:00', 'further ahead, the day by name' );

    # Saturday 00:30 is inside Friday's 18:00-01:00.
    $s = Lazysite::Data::Schedule::state( \@week, $TZ, at( 2026, 3, 7, 0, 30 ) );
    ok( $s->{open}, 'a period past midnight is open the next morning' );
    is( $s->{label}, 'Open now until 01:00', 'until it closes' );

    my %mon = map { $_->{day} => $_ } @{ $s->{week} };
    is_deeply( $mon{mon}{periods}, [ { opens => '09:00', closes => '12:00' }, { opens => '13:00', closes => '17:00' } ],
        'the week lists a day\'s periods in order' );
    ok( $mon{sun}{closed}, 'and a day with none as closed' );
};

subtest 'an exception replaces the week' => sub {
    my @rows = (
        @week,
        { kind => 'exception', date_from => '2026-03-02', closed => 1, note => 'Stocktake' },
        { kind => 'exception', date_from => '2026-03-03', opens => '10:00', closes => '14:00' },
        { kind => 'exception', date_from => '2026-03-20', date_until => '2026-03-22', closed => 1 },
        { kind => 'exception', date_from => '2026-02-01', closed => 1 },    # passed
    );
    my $s = Lazysite::Data::Schedule::state( \@rows, $TZ, at( 2026, 3, 2, 10, 0 ) );
    ok( !$s->{open}, 'a closed date is closed at an hour the week is open' );
    is( $s->{label}, 'Opens tomorrow at 10:00', 'and the next opening is the next day\'s exception hours' );
    ok( $s->{today}{exception} && $s->{today}{closed}, 'today says it is an exception, closed' );
    is( $s->{next_exception}{label}, 'Closed Monday 2 March', 'the next exception is today\'s, still in force' );
    is( $s->{next_exception}{note}, 'Stocktake', 'with its note' );
    ok( !grep( { $_->{date_from} eq '2026-02-01' } @{ $s->{exceptions} } ), 'a passed exception is not listed' );

    $s = Lazysite::Data::Schedule::state( \@rows, $TZ, at( 2026, 3, 3, 15, 0 ) );
    ok( !$s->{open}, 'other hours replace the week\'s: 15:00 on the 3rd is closed' );
    is( $s->{next_exception}{label}, 'Tuesday 3 March: open 10:00 to 14:00',
        'and the next exception names its hours' ) or diag explain $s->{next_exception};

    $s = Lazysite::Data::Schedule::state( \@rows, $TZ, at( 2026, 3, 4, 9, 0 ) );
    is( $s->{next_exception}{label}, 'Closed Friday 20 March to Sunday 22 March', 'a range is named as one' );
};

subtest 'the site\'s zone, across a change of the clocks' => sub {
    # Spring: at 01:00 UTC on 29 March 2026 London goes from 01:00 GMT to 02:00 BST.
    my @spring = ( { kind => 'period', day => 'sat', opens => '22:00', closes => '02:00' },
        { kind => 'period', day => 'sun', opens => '09:00', closes => '17:00' } );
    my $s = Lazysite::Data::Schedule::state( \@spring, $TZ, at( 2026, 3, 29, 0, 30 ) );
    ok( $s->{open}, '00:30 GMT on the night the clocks go forward is open' );
    is( $s->{expires}, at( 2026, 3, 29, 1, 0 ), 'and 02:00 local that night is 01:00 UTC, the moment the clocks change' );
    $s = Lazysite::Data::Schedule::state( \@spring, $TZ, at( 2026, 3, 29, 1, 30 ) );
    is( $s->{label}, 'Opens at 09:00', 'after it, closed' );
    is( $s->{expires}, at( 2026, 3, 29, 8, 0 ), '09:00 BST is 08:00 UTC' );

    # Autumn: at 01:00 UTC on 25 October 2026 London goes from 02:00 BST back to 01:00 GMT.
    my @autumn = ( { kind => 'period', day => 'sun', opens => '00:00', closes => '03:00' } );
    $s = Lazysite::Data::Schedule::state( \@autumn, $TZ, at( 2026, 10, 24, 23, 30 ) );
    ok( $s->{open}, '00:30 BST on the night the clocks go back is open' );
    is( $s->{expires}, at( 2026, 10, 25, 3, 0 ), '03:00 GMT that night is 03:00 UTC - four hours after midnight BST' );

    # The same wall-clock period in summer and in winter is an hour apart in UTC.
    my @mon = ( { kind => 'period', day => 'mon', opens => '09:00', closes => '17:00' } );
    my $summer = Lazysite::Data::Schedule::state( \@mon, $TZ, at( 2026, 6, 1, 6, 0 ) );
    my $winter = Lazysite::Data::Schedule::state( \@mon, $TZ, at( 2026, 12, 7, 6, 0 ) );
    is( $summer->{expires}, at( 2026, 6, 1, 8, 0 ),  'in summer 09:00 opens at 08:00 UTC' );
    is( $winter->{expires}, at( 2026, 12, 7, 9, 0 ), 'in winter at 09:00 UTC' );
};

subtest 'a zone the host does not know is UTC, and says so' => sub {
    my $docroot = site_tempdir();
    setup_test_site($docroot);
    open my $cf, '>>', "$docroot/lazysite/lazysite.conf" or die $!;
    print {$cf} "time_zone: Mars/Olympus_Mons\n";
    close $cf;
    my ( $tz, $why ) = Lazysite::Data::Schedule::site_zone($docroot);
    is( $tz, 'UTC', 'read as UTC' );
    like( $why, qr/time_zone 'Mars\/Olympus_Mons' is not a zone this host knows/, 'and the reason names it' );
    is( Lazysite::Data::Schedule::valid_zone('../../etc/passwd'), undef, 'a path is never a zone' );
    is( Lazysite::Data::Schedule::valid_zone('Europe/London'), 'Europe/London', 'a real zone is' );
};

subtest 'the opening hours as schema.org says them' => sub {
    my @rows = ( @week, { kind => 'exception', date_from => '2026-12-25', closed => 1 } );
    my $spec = Lazysite::Data::Schedule::opening_hours_spec( \@rows, $TZ, at( 2026, 12, 1, 9, 0 ) );
    my ($fri) = grep { ( $_->{dayOfWeek} // '' ) eq 'https://schema.org/Friday' } @$spec;
    is_deeply( $fri, { '@type' => 'OpeningHoursSpecification', dayOfWeek => 'https://schema.org/Friday',
            opens => '18:00', closes => '01:00' }, 'a period, with its day as a schema.org day' );
    my ($xmas) = grep { $_->{validFrom} } @$spec;
    is_deeply( $xmas, { '@type' => 'OpeningHoursSpecification', validFrom => '2026-12-25',
            validThrough => '2026-12-25', opens => '00:00', closes => '00:00' },
        'a closed date as schema.org spells closed' );
};

done_testing();
