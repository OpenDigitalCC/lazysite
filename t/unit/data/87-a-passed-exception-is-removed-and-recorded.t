#!/usr/bin/perl
# SM1356, ruling 164: A SCHEDULE'S EXCEPTION IS REMOVED ONCE ITS DATE HAS PASSED,
# PROVIDED THE LOG KEEPS THE TRAIL - the removal and the exception it removed
# are recorded, so the history can be read back.
#
#   * the sweep removes the exceptions whose last day is before today in the
#     site's zone, and only those - a range still running, one to come and
#     every weekly period stay;
#   * each removal is an audit-trail line carrying the row it removed, and
#     removed_exceptions reads them back as they were;
#   * with the audit trail off, NOTHING is removed and the sweep says why: a
#     removal the trail cannot hold would lose the history the ruling keeps;
#   * the daemon carries it: the schedule-exceptions job, under manage_data.
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
use Lazysite::Data::Schedule ();
use Lazysite::Data::Tables   qw(apply_schema insert_row read_rows);
use Lazysite::Daemon::Service::Scheduler ();

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

sub site {
    my (%o) = @_;
    my $docroot = site_tempdir();
    setup_test_site($docroot);
    make_path("$docroot/lazysite/db/tables");
    open my $cf, '>>', "$docroot/lazysite/lazysite.conf" or die $!;
    print {$cf} "audit_trail: off\n" if $o{trail_off};
    close $cf;
    spit( "$docroot/lazysite/db/tables/opening.yaml", "title: Opening hours\nschedule: true\npublic: true\n" );
    apply_schema( $docroot, 'opening' );
    insert_row( $docroot, 'opening', { kind => 'period', day => 'mon', opens => '09:00', closes => '17:00' } );
    insert_row( $docroot, 'opening', { kind => 'exception', date_from => '2026-12-25', closed => 'true', note => 'Christmas | Day' } );
    insert_row( $docroot, 'opening', { kind => 'exception', date_from => '2026-12-31', date_until => '2027-01-02', closed => 'true' } );
    insert_row( $docroot, 'opening', { kind => 'exception', date_from => '2027-04-03', opens => '10:00', closes => '14:00' } );
    return $docroot;
}

sub kinds {
    my ($docroot) = @_;
    my $r = read_rows( $docroot, 'opening', as => 'operator' );
    return join ',', map { $_->{kind} eq 'period' ? 'period' : $_->{date_from} }
        sort { $a->{id} <=> $b->{id} } @{ $r->{rows} };
}

my $NOW = timegm( 0, 0, 12, 1, 0, 2027 );    # 1 January 2027, noon UTC

subtest 'a passed exception is removed, and the removal is recorded with it' => sub {
    my $d = site();
    my $r = Lazysite::Data::Schedule::sweep_passed( $d, actor => 'jobs', now => $NOW );
    ok( $r->{ok}, 'the sweep runs' );
    is( $r->{removed}, 1, 'one exception had passed' );
    is( kinds($d), 'period,2026-12-31,2027-04-03',
        'Christmas Day is gone; the range still running, the one to come and the period stay' );

    my $back = Lazysite::Data::Schedule::removed_exceptions($d);
    is( scalar @$back, 1, 'the trail holds the removal' );
    is( $back->[0]{actor}, 'jobs', 'naming who removed it' );
    is( $back->[0]{table}, 'opening', 'and from which schedule' );
    is( $back->[0]{row}{date_from}, '2026-12-25', 'with the exception it removed' );
    is( $back->[0]{row}{note}, 'Christmas | Day', 'whole, even a value carrying the trail\'s own separator' );
    ok( $back->[0]{row}{closed}, 'closed, as it was' );

    my $again = Lazysite::Data::Schedule::sweep_passed( $d, actor => 'jobs', now => $NOW );
    is( $again->{removed}, 0, 'a second sweep finds nothing more' );

    my $later = Lazysite::Data::Schedule::sweep_passed( $d, actor => 'jobs', now => timegm( 0, 0, 12, 3, 0, 2027 ) );
    is( $later->{removed}, 1, 'a range goes once its LAST day has passed' );
};

subtest 'with the audit trail off, nothing is removed' => sub {
    my $d = site( trail_off => 1 );
    my $r = Lazysite::Data::Schedule::sweep_passed( $d, actor => 'jobs', now => $NOW );
    is( $r->{removed}, 0, 'nothing removed' );
    is( $r->{kept}, 1, 'the passed exception is kept' );
    like( $r->{reason}, qr/the audit trail is off/, 'and the sweep says why' );
    is( kinds($d), 'period,2026-12-25,2026-12-31,2027-04-03', 'every row is still there' );
};

subtest 'the daemon carries it' => sub {
    my $job = Lazysite::Daemon::Service::Scheduler::jobs()->{'schedule-exceptions'};
    ok( $job, 'a schedule-exceptions job is in the closed set' );
    is( $job->{needs}, 'manage_data', 'under manage_data, the grant that deletes a row' );
    my $d = site();
    my $r = $job->{run}->( docroot => $d, actor => 'jobs', now => $NOW );
    ok( $r->{ok}, 'it runs' );
    is( $r->{detail}{removed}, 1, 'and reports what it removed, in numbers' );
};

done_testing();
