#!/usr/bin/perl
# SM336: a session has a boundary, and sequence is recorded.
#
# Everything durable was a MARGINAL COUNT - top pages, top referrers, class
# shares, status codes. Nothing paired one dimension with another and nothing
# recorded order, so the question a site owner asks first - how do people move
# through my site, and where do they give up - was answerable only from a
# rolling 5,000-event sample, and never for any period already past.
#
# THE PREREQUISITE IS THE BOUNDARY. Visitor tokens are day-scoped, not
# session-scoped. The brief that raised this found a token showing `/login`
# followed by `/contact` 47,458 seconds apart - thirteen hours, counted as a
# two-page journey when it is two visits on the same network a day apart.
# Without a boundary every depth, trail and dwell figure is wrong in the same
# direction: too deep, too long, too connected.
#
# WHAT IS STORED IS AN AGGREGATE, never a path. A hundred visitors going
# `/ -> /products -> /contact` is one counter of 100 on each edge, not a hundred
# stored journeys. The session state itself lives in the export cache beside
# SM213's scanner map - transient, salt-obsoleting, and never written into a
# durable day file.
#
# AND CLASSIFICATION QUALITY IS A PREREQUISITE, not an adjacent concern. Until
# SM332 a WordPress sweep ran as `human`, and modelling transitions against that
# data made `/ -> /wp-json/batch/v1` the most travelled journey on the site. A
# site owner shown that would conclude their most popular journey is a
# vulnerability scan.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(decode_json encode_json);
use POSIX      qw(strftime mktime);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $plugin = repo_root() . '/plugins/stats.pl';
ok( -f $plugin, 'the stats plugin is present' );

sub site {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/cache");
    make_path("$d/lazysite/logs");
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "site_url: https://demo.example.io\nfirst_party: true\n";
    close $cf;
    return $d;
}

sub ev {
    my ( $d, $when, $path, %o ) = @_;
    my $day = strftime( '%Y%m%d', localtime($when) );
    open my $fh, '>>', "$d/lazysite/logs/access-$day.jsonl" or die $!;
    print $fh encode_json( {
            t => $when,
            p => $path,
            s => ( $o{status} // 200 ),
            b => 100,
            u => 'Mozilla/5.0 Chrome/120',
            v => ( $o{visitor} // 'reader' ),
            r => ( $o{ref}     // '-' ),
    } ) . "\n";
    close $fh;
}

sub day_of {
    my ( $d, $when ) = @_;
    my $p = "$d/lazysite/stats/daily/" . strftime( '%Y-%m-%d', localtime($when) ) . ".json";
    return undef unless -f $p;
    return decode_json( do { open my $fh, '<', $p or die $!; local $/; <$fh> } );
}

sub run {
    my ($d) = @_;
    local $ENV{DOCUMENT_ROOT} = $d;
    open my $ph, '-|', $^X, $plugin, '--export', '--window', 30
        or die "cannot run: $!";
    my $out = do { local $/; <$ph> };
    close $ph;
    return eval { decode_json($out) };
}

# Yesterday at 01:00 local, so the day closes and its rollup is final - AND so
# a thirteen-hour gap still lands inside the same day. Anchoring to a time of
# day rather than to `time() - 86400` matters: the first version of this used
# the latter, the 47,458-second gap crossed midnight, and the two events went
# into different day files. The test then read one of them and reported a
# missing session, which is the day-boundary logic working correctly and looked
# exactly like the boundary being broken.
my @Y    = localtime( time() - 86400 );
my $BASE = POSIX::mktime( 0, 0, 1, $Y[3], $Y[4], $Y[5] );

subtest 'a thirteen-hour gap is two visits, not a two-page journey' => sub {
    # The measured case: same token, same day, 47,458 seconds apart.
    #
    # The field example was `/login` followed by `/contact`, and this fixture
    # used those paths at first - which produced ONE session, correctly. `/login`
    # is a system path the engine already excludes from page counting, so it is
    # not a step in a journey either and never opens a session. Worth knowing
    # about the brief's own example: that particular pair would not have been
    # modelled as a two-page journey even without a boundary, because half of it
    # is not a page.
    #
    # The defect it illustrates is real and general, so the fixture uses two
    # content paths and keeps the measured gap.
    my $d = site();
    ev( $d, $BASE,          '/about' );
    ev( $d, $BASE + 47_458, '/contact' );
    run($d);

    my $day = day_of( $d, $BASE ) or return fail('no day rollup');
    is( $day->{sessions}, 2, 'two sessions' )
        or diag( 'One means the boundary is not applied, and every depth, '
            . 'trail and dwell figure is too deep, too long and too '
            . 'connected in consequence.' );
    is_deeply( $day->{journeys}{transitions}, [],
        'and no transition between them' )
        or diag( 'A transition across a thirteen-hour gap is a journey the '
            . 'visitor never made.' );
    is( $day->{journeys}{depth}{'1'}, 2, 'both are single-page visits' );
};

subtest 'a real journey is recorded as an aggregate' => sub {
    my $d = site();
    for my $v (qw(a b c)) {
        ev( $d, $BASE + 10, '/',         visitor => $v, ref => 'https://ref.example/x' );
        ev( $d, $BASE + 40, '/products', visitor => $v );
        ev( $d, $BASE + 90, '/contact',  visitor => $v );
    }
    run($d);
    my $day = day_of( $d, $BASE ) or return fail('no day rollup');

    my %edge = map { ( $_->{key} => $_->{count} ) } @{ $day->{journeys}{transitions} };
    is( $edge{'/>/products'},        3, 'three visitors on the first edge' );
    is( $edge{'/products>/contact'}, 3, 'and three on the second' )
        or diag( 'One counter per edge is the whole design - it reconstructs a '
            . 'flow diagram without retaining anybody\'s path.' );

    is( $day->{sessions},             3, 'three sessions' );
    is( $day->{journeys}{depth}{'3'}, 3, 'each three pages deep' );

    my ($entry) = @{ $day->{journeys}{entry} };
    is( $entry->{key}, '/', 'the entry page is where they arrived' );
    my ($exit) = @{ $day->{journeys}{exit} };
    is( $exit->{key}, '/contact', 'and the exit page is where they stopped' )
        or diag( 'The exit page is the most actionable field a content owner '
            . 'can be given: it names where the argument fails.' );

    my ($landing) = @{ $day->{journeys}{landing} };
    is( $landing->{key}, 'ref.example>/',
        'the referrer is paired with the page it landed on' )
        or diag( 'The difference between "we get traffic from X" and "traffic '
            . 'from X arrives on the wrong page".' );
};

subtest 'dwell comes from timestamps that already exist' => sub {
    my $d = site();
    ev( $d, $BASE,       '/a', visitor => 'z' );
    ev( $d, $BASE + 5,   '/b', visitor => 'z' );    # 5s on /a
    ev( $d, $BASE + 200, '/c', visitor => 'z' );    # 195s on /b
    run($d);
    my $day = day_of( $d, $BASE ) or return fail('no day rollup');

    is( $day->{journeys}{dwell}{under_10s}, 1, 'a short read is bucketed short' );
    is( $day->{journeys}{dwell}{over_120s}, 1, 'and a long one long' );

    my $total = 0;
    $total += $_ for values %{ $day->{journeys}{dwell} };
    is( $total, 2, 'two dwells from three pages - the LAST page has none' )
        or diag( 'The last page of a session has no successor and therefore no '
            . 'dwell. That is correct rather than missing, and inventing one '
            . 'would be guessing.' );
};

subtest 'a broken internal link names its source' => sub {
    # The owner was being told the destination and never the source, so a
    # one-edit fix was undiscoverable.
    my $d = site();
    ev( $d, $BASE, '/gone',
        status => 404, ref => 'https://demo.example.io/about' );
    ev( $d, $BASE + 5, '/gone',
        status => 404, ref => 'https://someone-else.example/x' );
    run($d);
    my $day = day_of( $d, $BASE ) or return fail('no day rollup');

    my @from = map { $_->{key} } @{ $day->{journeys}{not_found_from} };
    is_deeply( \@from, ['/gone>/about'],
        'the internal referrer is recorded, the external one is not' )
        or diag( 'Internal-only keeps it small and keeps it about their own '
            . 'site - an external site linking to a page you removed is not a '
            . 'broken link you can fix.' );
};

subtest 'a scanner has no journey' => sub {
    # Classification quality is a PREREQUISITE. Modelled against pre-SM332 data,
    # the top journey on the instrument was a WordPress sweep.
    my $d = site();
    my $t = $BASE;
    ev( $d, $t, '/', visitor => 'sweeper' );
    for my $p ( qw(/wp-json/batch/v1 /wp/wp-json/batch/v1 /blog/wp-json/batch/v1
        /old/wp-json/batch/v1 /test/wp-json/batch/v1) )
    {
        $t += 5;
        ev( $d, $t, $p, status => 404, visitor => 'sweeper' );
    }
    run($d);
    my $day = day_of( $d, $BASE ) or return fail('no day rollup');

    is_deeply( $day->{journeys}{transitions}, [],
        'the sweep contributes no transitions' )
        or diag( 'Its homepage hit would otherwise be the start of the most '
            . 'travelled journey on the site, which is what made SM332 a '
            . 'prerequisite for this rather than an adjacent concern.' );
    is( $day->{sessions}, 0, 'and no session at all' );
};

subtest 'an image is not a step in a journey' => sub {
    # SM329, applied to sequence: an asset is not an entry page, not an exit
    # page and not a transition.
    my $d = site();
    ev( $d, $BASE,     '/article',          visitor => 'q' );
    ev( $d, $BASE + 2, '/assets/img/a.jpg', visitor => 'q' );
    ev( $d, $BASE + 4, '/about',            visitor => 'q' );
    run($d);
    my $day = day_of( $d, $BASE ) or return fail('no day rollup');

    my @edges = map { $_->{key} } @{ $day->{journeys}{transitions} };
    is_deeply( \@edges, ['/article>/about'],
        'the image is not a step between the two pages' )
        or diag( 'One article with four images would otherwise generate four '
            . 'transitions per human page view.' );
    is( $day->{journeys}{depth}{'2'}, 1, 'and the visit is two pages deep' );
};

subtest 'the durable file holds no path belonging to anybody' => sub {
    # The privacy commitment, asserted rather than described. Everything above
    # is a counter; the session state that produced it must not reach disk.
    my $d = site();
    ev( $d, $BASE,     '/',  visitor => 'privacy-check' );
    ev( $d, $BASE + 5, '/x', visitor => 'privacy-check' );
    run($d);

    my $raw = do {
        my $p = "$d/lazysite/stats/daily/"
            . strftime( '%Y-%m-%d', localtime($BASE) ) . '.json';
        open my $fh, '<', $p or die $!;
        local $/;
        <$fh>;
    };
    unlike( $raw, qr/privacy-check/,
        'no visitor token in the durable day file' )
        or diag( 'The token is used within the day and discarded, exactly as '
            . 'it was before this filing. Sequence is recorded as aggregates '
            . 'so that stays true.' );
};

done_testing();
