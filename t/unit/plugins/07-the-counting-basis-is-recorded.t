#!/usr/bin/perl
# SM338: a change in what a number MEANS must be visible in the data.
#
# SM329 stopped an image counting as a page view. That is a change of basis, not
# a change of traffic, and it lands on a store where **a closed day file is
# written once and never rewritten**. So every day already rolled up keeps its
# old, asset-inflated `pageviews` for ever, and every day after the upgrade does
# not. The series carries a step at whatever date each instance upgrades.
#
# WHY THAT IS NOT A COSMETIC PROBLEM. It has already happened once, on a live
# instance, and could not be settled. An operator asked why traffic dropped on
# 27 July and assumed a new classifier had gone in. Answering needed data from
# before `data_from`, which no longer existed, and the honest conclusion was
# that the question could never be answered. The same question is guaranteed to
# be asked about this release's step, some weeks after the person who changed
# the counting has moved on.
#
# AND THE MONTH IS WORSE THAN THE DAY. The current month's rollup is refreshed on
# every call, so in the month an instance upgrades it sums days counted one way
# and days counted the other into one total. That total is not so much wrong as
# not a measurement of anything, and the month-on-month delta built from it is
# the first number anybody looks at.
#
# The remedy is one small integer per day, written at the time. The alternative
# is a question nobody can answer.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(decode_json encode_json);
use POSIX      qw(strftime);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $plugin = repo_root() . '/plugins/stats.pl';
ok( -f $plugin, 'the stats plugin is present' );

my $src = do { open my $fh, '<', $plugin or die $!; local $/; <$fh> };

subtest 'the basis is declared, and what each value means is written down' => sub {
    like( $src, qr/our \$COUNTING_BASIS = 2;/,
        'there is one canonical basis, and it is not a literal at each use' );
    like( $src, qr/1 - assets counted as page views/,
        'basis 1 is described' );
    like( $src, qr/2 - assets counted separately/,
        'and so is basis 2' )
        or diag( 'A bare integer in a data file is not a record of anything. '
            . 'The meaning has to be written where the number is produced.' );
};

subtest 'a bucket that predates the field is basis 1, not unknown' => sub {
    # THE CASE THAT MATTERS ON UPGRADE. Every existing instance has day buckets
    # in its export cache with no basis key at all, and they were definitely
    # counted somehow. Treating them as unknown would discard the one fact this
    # is here to preserve.
    my ($sub) = $src =~ /(sub _basis_of \{.*?\n\}\n)/s;
    ok( $sub, 'the reader was found' ) or return;
    eval "package BasisCheck; $sub 1;" or die $@;

    is_deeply( [ BasisCheck::_basis_of( {} ) ], [1],
        'a bucket with no basis key reads as basis 1' );
    is_deeply( [ BasisCheck::_basis_of( { basis => {} } ) ], [1],
        'and so does an empty set' );
    is_deeply( [ BasisCheck::_basis_of( { basis => { 2 => 1 } } ) ], [2],
        'a marked bucket reads as what it was marked' );
    is_deeply( [ BasisCheck::_basis_of( { basis => { 1 => 1, 2 => 1 } } ) ],
        [ 1, 2 ], 'and a bucket counted both ways reports both, in order' );
};

subtest 'the durable day and the index both carry it' => sub {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/cache");
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "site_url: https://demo.example.io\n";
    close $cf;

    my $log = "$d/access.log";
    my $now = strftime( '%d/%b/%Y:%H:%M:%S +0000', localtime );
    open my $lf, '>', $log or die $!;
    print $lf qq{1.2.3.4 - - [$now] "GET $_ HTTP/1.1" 200 100 "-" }
        . qq{"Mozilla/5.0 Chrome/120"\n}
        for qw(/article /assets/img/a.jpg);
    close $lf;

    local $ENV{DOCUMENT_ROOT}       = $d;
    local $ENV{LAZYSITE_ACCESS_LOG} = $log;
    my $r = decode_json(qx($^X \Q$plugin\E --export --window 30 2>/dev/null));
    ok( $r->{ok}, 'the export ran' ) or return;

    my $today = strftime( '%Y-%m-%d', localtime );
    my $day   = decode_json( do {
            open my $fh, '<', "$d/lazysite/stats/daily/$today.json" or die $!;
            local $/;
            <$fh>;
    } );
    is( $day->{counting_basis}, 2, 'a day counted now records basis 2' );
    ok( !$day->{counting_basis_mixed}, 'and is not mixed' );

    my $idx = decode_json( do {
            open my $fh, '<', "$d/lazysite/stats/index.json" or die $!;
            local $/;
            <$fh>;
    } );
    my ($row) = grep { $_->{date} eq $today } @{ $idx->{days} || [] };
    ok( $row, 'the index has the day' ) or return;
    is( $row->{counting_basis}, 2,
        'and the index row carries it, which is where the step is SEEN' )
        or diag( 'The by_day series is what a reader plots. A step in it with '
            . 'nothing alongside to explain it is exactly the 27 July '
            . 'question, asked again and equally unanswerable.' );
};

subtest 'a month spanning the change says it is mixed' => sub {
    # THE UPGRADE MORNING, built by the real writer rather than by hand. A
    # hand-authored cache is how the first version of this subtest passed
    # incorrectly: it omitted the `v` key, the loader rejected it as
    # unrecognised, and the prior day was silently absent from the run - so the
    # month was not mixed, the assertion failed, and it failed for a reason
    # that had nothing to do with what it was testing.
    #
    # So: run the export for real to get a genuine cache, then remove ONLY the
    # field that did not exist before this release. That is precisely what an
    # existing instance's cache looks like on the morning it upgrades, and
    # every other part of the shape is whatever the writer actually writes.
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/cache");
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "site_url: https://demo.example.io\n";
    close $cf;

    my $log   = "$d/access.log";
    my $prior = time() - 86400;
    my $when  = strftime( '%d/%b/%Y:%H:%M:%S +0000', localtime($prior) );
    open my $lf, '>', $log or die $!;
    print $lf qq{1.2.3.4 - - [$when] "GET /article HTTP/1.1" 200 100 "-" }
        . qq{"Mozilla/5.0 Chrome/120"\n};
    close $lf;

    local $ENV{DOCUMENT_ROOT}       = $d;
    local $ENV{LAZYSITE_ACCESS_LOG} = $log;
    my $first = decode_json(qx($^X \Q$plugin\E --export --window 30 2>/dev/null));
    ok( $first->{ok}, 'a first run establishes a real cache' ) or return;

    my $cache_path = "$d/lazysite/cache/stats-export.json";
    my $cache      = decode_json( do {
            open my $fh, '<', $cache_path or die $!;
            local $/;
            <$fh>;
    } );
    my $prior_day = strftime( '%Y-%m-%d', localtime($prior) );
    my $today     = strftime( '%Y-%m-%d', localtime );
    my ($mon)     = $today     =~ /^(\d{4}-\d{2})/;
    my ($pm)      = $prior_day =~ /^(\d{4}-\d{2})/;

SKIP: {
        skip 'the run crossed a month boundary; both days must be in one month',
            3
            if $pm ne $mon;
        ok( delete $cache->{days}{$prior_day}{basis},
            'the prior day is aged back to the pre-upgrade shape' )
            or diag( 'If this field was not there to delete, the fixture is no '
                . 'longer reproducing an upgrade and the assertion below '
                . 'proves nothing.' );
        open my $ch, '>', $cache_path or die $!;
        print $ch encode_json($cache);
        close $ch;

        # A second day's traffic, counted under the new basis.
        my $now = strftime( '%d/%b/%Y:%H:%M:%S +0000', localtime );
        open my $ap, '>>', $log or die $!;
        print $ap qq{1.2.3.5 - - [$now] "GET /article HTTP/1.1" 200 100 "-" }
            . qq{"Mozilla/5.0 Chrome/120"\n};
        close $ap;

        my $r = decode_json(qx($^X \Q$plugin\E --export --window 30 2>/dev/null));
        ok( $r->{ok}, 'the export ran over a cache in the pre-upgrade shape' );

        my $m = decode_json( do {
                open my $fh, '<', "$d/lazysite/stats/monthly/$mon.json" or die $!;
                local $/;
                <$fh>;
        } );
        ok( $m->{counting_basis_mixed},
            'the month says its days were not all counted the same way' )
            or diag( 'This month sums a day of asset-inflated pageviews and a '
                . 'day of real ones into one total. Reporting that total '
                . 'without saying so is the defect - the number is not wrong, '
                . 'it is not a measurement of anything.' );
    }
};

done_testing();
