#!/usr/bin/perl
# SM956: the owner's rule - "a visit with more than five pages at under
# ten-second gaps is not a person" - drives the classifier.
#
# Read as a RUN: a sixth page view inside ten seconds of the fifth, each inside
# ten of the one before, moves the source from `unattributed` to `bot`, and the
# move is counted in `bot_paced` so it can be inspected. Half of this file is
# what must NOT move: five quick pages, a run broken by one slow gap, a single
# request (no gap to judge), a page whose assets arrive in a burst, and two
# readers on one address.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(decode_json);
use POSIX      qw(strftime);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);

my $plugin = repo_root() . '/plugins/stats.pl';
plan skip_all => "no $plugin" unless -f $plugin;

# One export run against a hand-built access log. Each request is
# [ ip, path, status, offset-seconds, user-agent? ].
sub export_log { return export_into( undef, @_ ) }

# Q14g (SM974): 01:00 UTC yesterday, not `time() - 3600`. A stats day is a UTC
# day, and an hour back from the hour after midnight is yesterday, so the
# rollup read as "today" was absent. A fixed point inside one UTC day holds at
# any hour and in any zone; every run below spans seconds.
my $BASE     = int( time() / 86400 ) * 86400 - 86400 + 3600;
my $BASE_DAY = strftime( '%Y-%m-%d', gmtime $BASE );

# The same, into an existing docroot by appending to its log - a second batch,
# read with the cache from the first honoured.
sub export_into {
    my ( $d, @req ) = @_;
    if ( !defined $d ) {
        $d = site_tempdir();
        make_path("$d/lazysite/cache");
        open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
        print $cf "site_url: https://demo.example.io\n";
        close $cf;
    }
    my $log  = "$d/access.log";
    my $base = $BASE;
    open my $lf, '>>', $log or die $!;
    for my $r (@req) {
        my ( $ip, $path, $status, $offset, $ua ) = @$r;
        # gmtime: the stamp says +0000, and the plugin reads the offset.
        my $when = strftime( '%d/%b/%Y:%H:%M:%S +0000', gmtime( $base + $offset ) );
        print $lf qq{$ip - - [$when] "GET $path HTTP/1.1" $status 100 "-" "}
            . ( $ua // 'Mozilla/5.0 Chrome/120' ) . qq{"\n};
    }
    close $lf;
    local $ENV{DOCUMENT_ROOT}       = $d;
    local $ENV{LAZYSITE_ACCESS_LOG} = $log;
    my $out = qx($^X \Q$plugin\E --export --window 30 2>/dev/null);
    my $r   = decode_json($out);
    $r->{_docroot} = $d;
    return $r;
}

sub classes {
    my ($r) = @_;
    my %c;
    $c{ $_->{class} }++ for @{ $r->{events} || [] };
    return \%c;
}

sub day_rollup {
    my ($r) = @_;
    open my $fh, '<', "$r->{_docroot}/lazysite/stats/daily/$BASE_DAY.json" or return {};
    local $/;
    return decode_json(<$fh>);
}

# n page views from one address, $gap seconds apart, starting at $from.
sub run_of {
    my ( $ip, $n, $gap, $from ) = @_;
    $from //= 0;
    return map { [ $ip, "/page-$ip-$from-$_", 200, $from + $_ * $gap ] } 0 .. $n - 1;
}

subtest 'six pages two seconds apart: a bot, every one of them' => sub {
    my $r = export_log( run_of( '203.0.113.1', 6, 2 ) );
    is_deeply( classes($r), { bot => 6 }, 'all six page views are bot - the earlier five reached back' )
        or diag( explain classes($r) );
    is( $r->{traffic_classes}{unattributed}{visits} // 0, 0, 'none is counted as a possible person' );
    cmp_ok( day_rollup($r)->{bot_paced} // 0, '>', 0,
        'and the rollup says these bots were inferred from pace' )
        or diag('Requirement 2: the reclassification must be inspectable, not taken on trust.');
};

subtest 'five quick pages stay: the rule is MORE than five' => sub {
    my $r = export_log( run_of( '203.0.113.2', 5, 2 ) );
    is_deeply( classes($r), { unattributed => 5 }, 'five page views, unattributed' );
};

subtest 'a run broken by one slow gap stays' => sub {
    my $r = export_log( run_of( '203.0.113.3', 3, 2, 0 ), run_of( '203.0.113.3', 3, 2, 20 ) );
    is_deeply( classes($r), { unattributed => 6 },
        'six pages with a 16-second gap in the middle - two runs of three' );
};

subtest 'a gap of exactly ten seconds is not under ten' => sub {
    my $r = export_log( run_of( '203.0.113.4', 7, 10 ) );
    is_deeply( classes($r), { unattributed => 7 }, 'seven pages ten seconds apart stay' );
};

subtest 'a single request has no gap to judge' => sub {
    my $r = export_log( [ '203.0.113.5', '/', 200, 0 ] );
    is_deeply( classes($r), { unattributed => 1 }, 'one request, unattributed' )
        or diag('An empty gap list is never "all gaps under ten seconds".');
};

subtest 'a page and its assets in a burst stay' => sub {
    my @req = ( [ '203.0.113.6', '/', 200, 0 ],
        map { [ '203.0.113.6', "/assets/a$_.css", 200, 0 ] } 1 .. 10 );
    my $c = classes( export_log(@req) );
    ok( !$c->{bot}, 'assets are not page views, so a page load is not a run' )
        or diag( explain $c );
};

subtest 'two readers on one address are two runs' => sub {
    # Interleaved, two seconds apart overall: each browser makes three page
    # views. Keyed on the address alone this would be one run of six.
    my @req;
    for my $i ( 0 .. 5 ) {
        push @req, [ '203.0.113.7', "/p$i", 200, $i * 2, ( $i % 2 ? 'Mozilla/5.0 Firefox/130' : undef ) ];
    }
    my $c = classes( export_log(@req) );
    ok( !$c->{bot}, 'neither is promoted' ) or diag( explain $c );
};

subtest 'a run that spans two reads reaches back' => sub {
    # Three page views are read, counted as unattributed and cached; three more
    # arrive in the next read and complete the run. The first three must move -
    # the reach-back over the event ring - or the earlier half of every paced
    # run stays counted as a person.
    my $first = export_log( run_of( '203.0.113.8', 3, 2, 0 ) );
    is_deeply( classes($first), { unattributed => 3 }, 'after the first read, three unattributed' );
    my $r = export_into( $first->{_docroot}, run_of( '203.0.113.8', 3, 2, 6 ) );
    is_deeply( classes($r), { bot => 6 }, 'after the second, all six are bot' )
        or diag( explain classes($r) );
    is( $r->{traffic_classes}{unattributed}{visits} // 0, 0, 'and none is still counted as a person' );
};

done_testing();
