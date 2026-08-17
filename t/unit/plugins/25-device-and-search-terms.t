#!/usr/bin/perl
# SM336 items 6 and 7 - the two the sessions release did not ship - plus a
# defect found while shipping item 7.
#
# ITEM 6, device class. Both ingesters already had the user-agent and both threw
# it away: classify() consumed it and the record kept only its verdict. Three
# counters answer "does mobile matter to me", which decides a great deal of
# design work.
#
# ITEM 7, internal search terms. The highest-signal field on that filing's list
# and the only one carrying a real privacy risk - a search term is the visitor's
# own words, not a fact about a page. It ships OFF, on its own switch, with a
# frequency floor, and it never writes a term down until the floor is reached.
#
# AND THE DEFECT. Item 7 needs the query string, which meant reading where the
# request target is parsed - and finding the query string had been part of the
# counted PATH all along. Every distinct search was its own entry in top_pages,
# so a busy search box quietly pushed the real pages down the list by splitting
# itself into dozens of one-hit entries. Same shape as SM329: something counted
# as a page that is not a distinct page.
#
# DRIVEN THROUGH THE PLUGIN, not by calling its subs. stats.pl runs its main
# body and exits at file scope, so it cannot be loaded for unit calls - and
# driving it the way it actually runs is the better test anyway. Every assertion
# below is against a day rollup the plugin wrote.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(decode_json);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use POSIX      qw(strftime);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $PLUGIN = repo_root() . '/plugins/stats.pl';
ok( -f $PLUGIN, 'stats plugin present' );

my $NOW = strftime( '%d/%b/%Y:%H:%M:%S +0000', localtime );
my $DAY = strftime( '%Y-%m-%d',                localtime );

my %UA = (
    desktop => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120',
    mobile => 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15',
    tablet => 'Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15',

    # The one that catches a naive implementation: every Android tablet says
    # "Android" and only a PHONE also says "Mobile", so an /Android/ test alone
    # reports every tablet as a phone.
    android_tablet =>
        'Mozilla/5.0 (Linux; Android 13; SM-X710) AppleWebKit/537.36 Safari/537.36',
    android_phone =>
        'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 Mobile Safari/537.36',
);

sub line {
    my ( $ip, $target, $ua ) = @_;
    return qq{$ip - - [$NOW] "GET $target HTTP/1.1" 200 100 "-" "$ua"\n};
}

# A site, a log, and whatever stats.conf the case wants.
sub site {
    my ( $conf, @lines ) = @_;
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/cache");
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_url: https://demo.example.io\n";
    close $cf;
    if ( defined $conf ) {
        open my $sf, '>', "$d/lazysite/stats.conf" or die $!;
        print {$sf} $conf;
        close $sf;
    }
    my $log = "$d/access.log";
    open my $lf, '>', $log or die $!;
    print {$lf} @lines;
    close $lf;
    return ( $d, $log );
}

sub day_rollup {
    my ( $d, $log ) = @_;
    local $ENV{DOCUMENT_ROOT}       = $d;
    local $ENV{LAZYSITE_ACCESS_LOG} = $log;
    my $out = qx($^X \Q$PLUGIN\E --export --day \Q$DAY\E 2>/dev/null);
    my $r   = decode_json( $out || '{}' );
    # --day answers { ok, day => {...} }; the rollup is the inner hash.
    return $r->{day} || {};
}

# --- item 6 ------------------------------------------------------------------
subtest 'devices are counted, and a tablet is not a phone' => sub {
    my ( $d, $log ) = site(
        undef,
        line( '10.0.0.1', '/about', $UA{desktop} ),
        line( '10.0.0.2', '/about', $UA{mobile} ),
        line( '10.0.0.3', '/about', $UA{android_phone} ),
        line( '10.0.0.4', '/about', $UA{tablet} ),
        line( '10.0.0.5', '/about', $UA{android_tablet} ),
    );
    my $r = day_rollup( $d, $log );
    is_deeply( $r->{devices}, { desktop => 1, mobile => 2, tablet => 2 },
        'three counters, and Android-without-Mobile lands on tablet' )
        or diag explain $r->{devices};
};

subtest 'an asset carries no device' => sub {
    # The SM329 rule applied to the new counter: a stylesheet is fetched by the
    # same device that fetched the page, so counting it would multiply every
    # visit by however many files the layout loads.
    my ( $d, $log ) = site(
        undef,
        line( '10.0.0.1', '/about',     $UA{mobile} ),
        line( '10.0.0.1', '/theme.css', $UA{mobile} ),
        line( '10.0.0.1', '/app.js',    $UA{mobile} ),
    );
    my $r = day_rollup( $d, $log );
    is_deeply( $r->{devices}, { mobile => 1 },
        'one page view, one device, whatever the page loaded' );
};

# --- the defect --------------------------------------------------------------
subtest 'two searches are one page, not two' => sub {
    my ( $d, $log ) = site(
        undef,
        line( '10.0.0.1', '/search-results?q=widgets', $UA{desktop} ),
        line( '10.0.0.2', '/search-results?q=prices',  $UA{desktop} ),
        line( '10.0.0.3', '/search-results?q=hours',   $UA{desktop} ),
    );
    my $r    = day_rollup( $d, $log );
    my @keys = map { $_->{key} } @{ $r->{top_pages} || [] };
    is_deeply( \@keys, ['/search-results'],
        'one page in top_pages, not one per search' )
        or diag explain $r->{top_pages};
    is( $r->{top_pages}[0]{count}, 3, 'with all three views on it' );
};

# --- item 7 ------------------------------------------------------------------
subtest 'search terms are off unless asked for' => sub {
    my ( $d, $log ) = site(
        undef,
        map { line( "10.0.0.$_", '/search-results?q=shoes', $UA{desktop} ) } 1 .. 6
    );
    my $r = day_rollup( $d, $log );
    ok( !exists $r->{search_terms},
        'nothing recorded, and the key is ABSENT rather than empty' )
        or diag explain $r->{search_terms};
};

subtest 'and a setting that says off means off' => sub {
    # The case the absent-config test above cannot reach, and the one that
    # matters. With no stats.conf at all the value is undef and any
    # implementation returns false, so that test passes even against a reader
    # that treats every defined value as true - which is exactly what sabotaging
    # it showed. A conf that SAYS something is the only way to test the reader.
    for my $value (qw(off no 0 false maybe)) {
        my ( $d, $log ) = site(
            "search_terms: $value\n",
            map { line( "10.0.0.$_", '/search-results?q=shoes', $UA{desktop} ) } 1 .. 6
        );
        my $r = day_rollup( $d, $log );
        ok( !exists $r->{search_terms},
            "'$value' is off" )
            or diag( 'This setting failing open would start recording '
                . "visitors' own words on a site that never asked." );
    }
};

subtest 'and are recorded once turned on' => sub {
    my ( $d, $log ) = site(
        "search_terms: on\n",
        map { line( "10.0.0.$_", '/search-results?q=shoes', $UA{desktop} ) } 1 .. 6
    );
    my $r = day_rollup( $d, $log );
    is_deeply( $r->{search_terms}, [ { key => 'shoes', count => 6 } ],
        'the term and its count' )
        or diag explain $r->{search_terms};
};

subtest 'a one-off is never written down' => sub {
    # The privacy property, and the reason this ships with a floor at all.
    # People type surprising things into search boxes; a term one visitor used
    # once is that person's words and nobody else's.
    my ( $d, $log ) = site(
        "search_terms: on\n",
        line( '10.0.0.1', '/search-results?q=common',       $UA{desktop} ),
        line( '10.0.0.2', '/search-results?q=common',       $UA{desktop} ),
        line( '10.0.0.3', '/search-results?q=common',       $UA{desktop} ),
        line( '10.0.0.4', '/search-results?q=said+it+once', $UA{desktop} ),
        line( '10.0.0.5', '/search-results?q=and+this+too', $UA{desktop} ),
    );
    my $r     = day_rollup( $d, $log );
    my @terms = map { $_->{key} } @{ $r->{search_terms} || [] };
    is_deeply( \@terms, ['common'],
        'only the term that cleared the floor' );

    # And not merely absent from the REPORT - absent from what was written.
    open my $fh, '<', "$d/lazysite/cache/stats-export.json" or die $!;
    my $cache = do { local $/; <$fh> };
    close $fh;
    unlike( $cache, qr/said it once|and this too/,
        'the rare terms are not in the cache either, in any readable form' )
        or diag( 'Below the floor only a hash of the term is counted. If the '
            . 'words reach disk at all, the floor is a reporting filter rather '
            . 'than a privacy property.' );
    like( $cache, qr/common/,
        'while the one that cleared it is stored, as it must be to be reported' );
};

subtest 'terms are normalised before they are counted' => sub {
    # A top-20 list of near-identical spellings is not a report.
    my ( $d, $log ) = site(
        "search_terms: on\n",
        line( '10.0.0.1', '/search-results?q=Red+Widgets',   $UA{desktop} ),
        line( '10.0.0.2', '/search-results?q=red%20widgets', $UA{desktop} ),
        line( '10.0.0.3', '/search-results?q=RED++WIDGETS',  $UA{desktop} ),
    );
    my $r = day_rollup( $d, $log );
    is_deeply( $r->{search_terms}, [ { key => 'red widgets', count => 3 } ],
        'case, encoding and spacing all fold into one term' )
        or diag explain $r->{search_terms};
};

subtest 'a request with no q is not a search' => sub {
    my ( $d, $log ) = site(
        "search_terms: on\n",
        map { line( "10.0.0.$_", '/about?utm_source=news', $UA{desktop} ) } 1 .. 5
    );
    my $r = day_rollup( $d, $log );
    ok( !exists $r->{search_terms}, 'a tracking parameter is not a search term' );
};

done_testing();
