#!/usr/bin/perl
# SM332: promote a scanner by behaviour, not only by signature.
#
# WHAT WAS MEASURED on edge/0.10.11: six visitor tokens, 27 events, every one a
# 404, every one classified `human`:
#
#   /wp-json/batch/v1            /old/wp-json/batch/v1
#   /wp/wp-json/batch/v1         /test/wp-json/batch/v1
#   /wordpress/wp-json/batch/v1  /dev/wp-json/batch/v1
#   /blog/wp-json/batch/v1       /backup/wp-json/batch/v1
#   /wp/                         /config
#
# That is one visitor walking a list of guesses at where a WordPress install
# might be mounted, and it is exactly the behaviour SM213's visitor-level
# classification was built to catch.
#
# WHY IT ESCAPED. `_is_probe` had four triggers and all four are signatures.
# `/wp-login.php` is caught by the `.php` rule; its modern replacement
# `/wp-json/batch/v1` is extensionless, is not a secrets file and is not an SPA
# manifest, so it is caught by nothing. Adding `/wp-json` to a list would close
# this instance and not the next one - the general problem is that signature
# lists date, and this one dates precisely.
#
# WHY 4% OF EVENTS MATTERS. Classification gates everything built on top of it.
# Modelled against the same data, the most travelled journey on the site was
# `/ -> /wp-json/batch/v1`. A site owner shown that would conclude their most
# popular journey is a vulnerability scan.
#
# WHAT THIS FILE PROTECTS IN THE OTHER DIRECTION. A real person generates 404s -
# stale bookmarks, a broken menu - and SM213 records that `not_found.plausible`
# exists to surface exactly that reader, because a person hitting a real-looking
# missing page is signal for the site owner. Three of the five subtests below
# are about NOT catching them.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(decode_json);
use POSIX      qw(strftime);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $plugin = repo_root() . '/plugins/stats.pl';
ok( -f $plugin, 'the stats plugin is present' );

# One export run against a hand-built access log. Each request is given an
# explicit offset in seconds so the WINDOW is what is being tested and not the
# speed of the test host.
sub export_log {
    my (%o) = @_;
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/cache");
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "site_url: https://demo.example.io\n";
    close $cf;

    my $log  = "$d/access.log";
    my $base = time() - 3600;
    open my $lf, '>', $log or die $!;
    for my $r ( @{ $o{requests} } ) {
        my ( $ip, $path, $status, $offset ) = @$r;
        my $when = strftime( '%d/%b/%Y:%H:%M:%S +0000',
            localtime( $base + ( $offset // 0 ) ) );
        print $lf qq{$ip - - [$when] "GET $path HTTP/1.1" $status 100 "-" }
            . qq{"Mozilla/5.0 Chrome/120"\n};
    }
    close $lf;

    local $ENV{DOCUMENT_ROOT}       = $d;
    local $ENV{LAZYSITE_ACCESS_LOG} = $log;
    my $out = qx($^X \Q$plugin\E --export --window 30 2>/dev/null);
    my $r   = decode_json($out);
    $r->{_docroot} = $d;
    return $r;
}

sub class_of {
    my ( $r, $path ) = @_;
    my ($ev) = grep { ( $_->{path} // '' ) eq $path } @{ $r->{events} || [] };
    return $ev ? $ev->{class} : '(no such event)';
}

subtest 'the field sweep, replayed' => sub {
    # The measured paths, in the measured shape: one visitor, ten distinct
    # guesses, close together, all missing.
    my $t   = 0;
    my @req = map { [ '203.0.113.9', $_, 404, $t += 4 ] } qw(
        /wp-json/batch/v1           /wp/wp-json/batch/v1
        /wordpress/wp-json/batch/v1 /blog/wp-json/batch/v1
        /old/wp-json/batch/v1       /test/wp-json/batch/v1
        /dev/wp-json/batch/v1       /backup/wp-json/batch/v1
    );
    # And the homepage hit that came with it, which is the one that made the
    # sweep the top journey on the site.
    unshift @req, [ '203.0.113.9', '/', 200, 0 ];
    my $r = export_log( requests => \@req );

    is( class_of( $r, '/wp-json/batch/v1' ), 'scanner',
        'the sweep is classified scanner' )
        or diag( 'Every trigger in the probe list is a signature, and this '
            . 'probe is newer than all of them.' );

    is( class_of( $r, '/' ), 'scanner',
        'and so is the same token\'s homepage hit' )
        or diag( 'SM213 reclassifies ALL of a promoted token\'s events. If the '
            . 'homepage hit stays human the journey metric still reports the '
            . 'scan as the site\'s most popular path.' );

    is( $r->{traffic_classes}{human}{visits}, 0,
        'nothing in this log is a human visit' );

    my $today = strftime( '%Y-%m-%d', localtime );
    my $day   = decode_json( do {
            open my $fh, '<', "$r->{_docroot}/lazysite/stats/daily/$today.json"
                or die $!;
            local $/;
            <$fh>;
    } );
    cmp_ok( $day->{scanner_inferred}, '>', 0,
        'the rollup records that this promotion was inferred, not matched' )
        or diag( 'An operator judging whether the threshold suits their '
            . 'traffic cannot do it if a behavioural promotion is '
            . 'indistinguishable from a signature match.' );
};

subtest 'a reader following stale bookmarks stays human' => sub {
    # THE FALSE POSITIVE THIS IS BUILT TO AVOID. Three dead links from an old
    # bookmark folder, and a real page at the end of it. Under the threshold,
    # and it must stay under it.
    my $r = export_log(
        requests => [
            [ '198.51.100.4', '/old-news',      404, 0 ],
            [ '198.51.100.4', '/2019/about-us', 404, 20 ],
            [ '198.51.100.4', '/team/jane',     404, 40 ],
            [ '198.51.100.4', '/about',         200, 60 ],
        ] );

    is( class_of( $r, '/old-news' ), 'human', 'three missing pages is not a sweep' );
    is( class_of( $r, '/about' ),    'human', 'and the page they did find counts' );
    cmp_ok( scalar @{ $r->{not_found}{plausible} }, '>=', 3,
        'the missing pages are still reported as plausible 404s' )
        or diag( 'SM213 keeps these BY PATH because they tell the site owner '
            . 'what a real reader came looking for. A behavioural promotion '
            . 'that swallowed them would destroy the more useful signal to '
            . 'catch the less useful one.' );
};

subtest 'the same missing path, over and over, is not a sweep' => sub {
    # A broken image reference or a stuck client retries ONE path. Distinct is
    # the whole discriminator, so this is the case that proves it is applied.
    my @req = map { [ '198.51.100.7', '/gone', 404, $_ * 5 ] } 0 .. 11;
    my $r   = export_log( requests => \@req );
    is( class_of( $r, '/gone' ), 'human',
        'twelve requests for one missing path stay human' )
        or diag( 'Counting requests rather than distinct paths turns every '
            . 'stuck client into a scanner.' );
};

subtest 'the window is a window' => sub {
    # Eight distinct 404s is a sweep in four minutes and a bad afternoon spread
    # across an hour. Same paths, same count, same visitor - only the spacing
    # differs, so this isolates the window from the threshold.
    my @paths = map { "/missing-$_" } 1 .. 8;

    my $i     = 0;
    my $tight = export_log(
        requests => [ map { [ '198.51.100.20', $_, 404, $i++ * 20 ] } @paths ] );
    is( class_of( $tight, '/missing-1' ), 'scanner',
        'eight distinct missing paths in under three minutes is a sweep' );

    my $j     = 0;
    my $loose = export_log(
        requests => [ map { [ '198.51.100.21', $_, 404, $j++ * 600 ] } @paths ] );
    is( class_of( $loose, '/missing-1' ), 'human',
        'the same eight spread ten minutes apart are not' )
        or diag( 'Without the window this is "eight 404s in a day", which is a '
            . 'site with eight dead links, not a scanner.' );
};

subtest 'the thresholds are settings, and they are stated' => sub {
    # The filing is explicit that the numbers are a judgement rather than a
    # constant, because how many 404s a real reader generates is a property of
    # the site. `noise_paths` is the precedent.
    my $describe = decode_json(qx($^X \Q$plugin\E --describe 2>/dev/null));
    my %by_key   = map { ( $_->{key} => $_ ) } @{ $describe->{config_schema} || [] };

    ok( $by_key{scanner_404_paths},   'the threshold is exposed as a setting' );
    ok( $by_key{scanner_404_minutes}, 'and so is the window' );
    is( $by_key{scanner_404_paths}{default}, '5',
        'with the default stated rather than hidden in the code' );
    like( $by_key{scanner_404_paths}{note}, qr/scanner/i,
        'and a note saying what raising it does' );
};

done_testing();
