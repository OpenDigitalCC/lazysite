#!/usr/bin/perl
# SM941 AV1: the invariants of ONE report, asserted against ONE call.
#
# This is the test the reporter asked for, and the reason they asked for a test
# rather than a fix: three contradictions were visible in a single call's output
# on two live sites, which means nothing was checking the arithmetic. Until the
# invariants are written down, "which counter is right" is a question with no
# referee.
#
# What was wrong, on the instrument:
#
#   totals.human_visits   15,979      and by_day[].human summed to 18,849
#   totals.unique_visitors 4,359      across 4,241 visits, on another site
#   totals.human_visits == totals.pageviews, the SAME SCALAR under two names
#
# Each of those is checkable from the output with no fixture at all. So the
# assertions below are deliberately about RELATIONSHIPS between fields rather
# than about particular numbers: a test pinning "pageviews == 3" tells you the
# fixture still has three pages in it, and would have passed happily on every
# day of the defect. These fail whenever two fields disagree, whatever the
# traffic is.
#
# THE FIXTURE IS DELIBERATELY MIXED: pages, an asset, a 404, an empty
# user-agent, a declared bot and an AI fetcher. Every counter has something in
# it, so no invariant can hold by both sides being zero (the vacuous pass this
# project has been bitten by before).
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json encode_json);
use POSIX qw(strftime);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);

my $plugin = repo_root() . '/plugins/stats.pl';
plan skip_all => "no $plugin" unless -f $plugin;

# SM754 / lint 118: site_tempdir, not a bare tempdir. The engine writes BESIDE
# a docroot (the private store, and ../plugins on the Hestia layout) and
# File::Temp only cleans the directory it made, so a bare tempdir leaks its
# siblings into /tmp - including a stray plugins/stats.pl that once made a
# "plugin not found" assertion pass for the wrong reason.
my $d = site_tempdir();
mkdir "$d/lazysite";
mkdir "$d/lazysite/$_" for qw(logs cache stats);
open my $cf, '>', "$d/lazysite/stats.conf" or die $!;
print {$cf} "window_days: 30\n";
close $cf;

# `ua`, not `u` - the key the processor's own writer emits and the ingester
# reads. Three fixtures in this directory said `u` and so fed an EMPTY
# user-agent to the classifier for their whole life, which the old `human`
# fall-through hid. Writing the records through one helper keyed the right way
# is the cheapest way not to repeat that.
my $now = time() - 3600;
my $day = strftime( '%Y%m%d', gmtime($now) );    # Q14g: the writer's name, a UTC day
open my $lf, '>', "$d/lazysite/logs/access-$day.jsonl" or die $!;
my $t = 0;

sub rec {
    my ( $path, $status, $ua, $visitor ) = @_;
    print {$lf} encode_json( {
            t  => $now + ( $t += 5 ),
            p  => $path,
            s  => $status,
            b  => 1024,
            ch => 'page',
            ua => $ua,
            v  => $visitor,
    } ) . "\n";
}

my $BROWSER = 'Mozilla/5.0 (X11; Linux x86_64) Chrome/121.0 Safari/537.36';
rec( '/',        200, $BROWSER, 'reader-a' );
rec( '/about',   200, $BROWSER, 'reader-a' );
rec( '/contact', 200, $BROWSER, 'reader-b' );
rec( '/css/site.css', 200, $BROWSER,     'reader-a' );    # an asset
rec( '/missing',      404, $BROWSER,     'reader-b' );    # not a visit
rec( '/also-missing', 404, $BROWSER,     'reader-b' );
rec( '/',             200, '',            'silent-c' );   # NO user-agent
rec( '/',             200, 'Googlebot/2.1', 'crawler-d' );
rec( '/',             200, 'ClaudeBot/1.0', 'ai-e' );
close $lf;

my $out = qx($^X \Q$plugin\E --export --window 30 --docroot \Q$d\E 2>&1);
my $r   = eval { decode_json($out) };
ok( $r && $r->{ok}, 'the report was produced' )
    or do { diag( substr $out, 0, 400 ); done_testing(); exit };

my $U = 'unattributed';

# --- the fixture reached every counter ---------------------------------------
#
# FIRST, because every invariant below is satisfied by a report full of zeroes.
subtest 'every counter the invariants cover has something in it' => sub {
    cmp_ok( $r->{totals}{pageviews},  '>', 0, 'page views' );
    cmp_ok( $r->{totals}{asset_hits}, '>', 0, 'asset hits' );
    cmp_ok( $r->{totals}{error_hits}, '>', 0, 'error hits' );
    cmp_ok( $r->{traffic_classes}{$U}{visits}, '>', 0, "the $U class" );
    cmp_ok( $r->{traffic_classes}{no_agent}{visits}, '>', 0, 'the no_agent class' )
        or diag( 'An empty user-agent used to fall through to `human`. If this '
            . 'is zero the fixture is not exercising the case that put 4,227 '
            . 'requests a day in the audience figure.' );
    cmp_ok( $r->{traffic_classes}{bot}{visits}, '>', 0, 'the bot class' );
    cmp_ok( $r->{traffic_classes}{ai}{visits},  '>', 0, 'the ai class' );
};

# --- invariant 1: the three counters sum to their class ----------------------
subtest 'the visit counters sum to the class they are drawn from' => sub {
    my $sum = $r->{totals}{pageviews} + $r->{totals}{asset_hits}
        + $r->{totals}{error_hits};
    is( $sum, $r->{traffic_classes}{$U}{visits},
        "pageviews + asset_hits + error_hits == $U visits" )
        or diag( 'This is the 2,870 gap: `cls` counted every request in the '
            . 'class and `hits` excluded successful asset fetches, so the two '
            . 'reported totals differed by exactly asset_hits - which no '
            . 'projection published, leaving nothing to reconcile them with.' );
};

# --- invariant 2: totals and by_day agree ------------------------------------
subtest 'totals and by_day agree about the same window' => sub {
    my $by_day = 0;
    $by_day += ( $_->{$U} // 0 ) for @{ $r->{by_day} || [] };
    is( $by_day, $r->{traffic_classes}{$U}{visits},
        "by_day sums to the $U total" )
        or diag( 'The report published 15,979 in totals and 18,849 in by_day '
            . 'and called both complete.' );
};

# --- invariant 3: a unique visitor cannot visit less than once ---------------
subtest 'unique visitors cannot outnumber their own visits' => sub {
    cmp_ok( $r->{totals}{unique_visitors}, '<=',
        $r->{traffic_classes}{$U}{visits},
        'unique_visitors <= the visits of the class it counts' )
        or diag( 'On opendigital.cc this was 4,359 unique visitors across '
            . '4,241 visits. The cause was that unique_visitors summed EVERY '
            . 'class while the visits beside it were one class.' );

    is( $r->{totals}{unique_visitors}, $r->{traffic_classes}{$U}{visitors},
        'and it is the same count traffic_classes reports for that class' )
        or diag( 'Two fields naming the same population must not be computed '
            . 'two ways - that is how the contradiction above arose.' );
};

# --- invariant 4: status_codes covers a population the report names ----------
subtest 'status_codes sums to a population the report names' => sub {
    # WRITING THIS FOUND THE GAP. `status_codes` counts the `unattributed`
    # class alone - the increment sits below _apply_event's early return - and
    # the report named that nowhere, so nine requests produced six statuses
    # with nothing to account for the other three. The behaviour is right (a
    # scanner sweep would otherwise bury a site's real 404s); the denominator
    # was missing.
    #
    # So the assertion reads the DECLARED population rather than assuming one.
    # That way it tests the pair - the number and the claim about it - and a
    # future change that broadens the histogram without updating the
    # declaration fails here rather than quietly publishing a new meaning.
    is( $r->{populations}{status_codes}, 'unattributed',
        'the report declares which callers status_codes counts' )
        or diag( 'SM888 S3: four figures on one screen, each a count of '
            . 'something different, none of them saying which.' );

    my $codes = 0;
    $codes += $_ for values %{ $r->{status_codes} || {} };
    is( $codes, $r->{traffic_classes}{$U}{visits},
        'and it sums to exactly that population' );

    # The population it does NOT cover is still in the report, so nothing is
    # lost - it is in traffic_classes, where a reader asking about bots looks.
    my $all = 0;
    $all += $_->{visits} for values %{ $r->{traffic_classes} || {} };
    cmp_ok( $all, '>', $codes,
        'the other classes are counted elsewhere, not dropped' );
};

# --- invariant 5: the report says how it counted -----------------------------
subtest 'the report states its own basis and scope' => sub {
    is( $r->{schema_version}, '3', 'schema_version is declared' );
    cmp_ok( $r->{counting_basis}, '>=', 4, 'counting_basis is declared' );
    is_deeply( $r->{counting_basis_in_window}, [ $r->{counting_basis} ],
        'and a single-basis window says so, in one entry' );
    is( $r->{window_scoped}{by_day}, JSON::PP::true,
        'by_day is marked window-scoped' );
    is( $r->{window_scoped}{months}, JSON::PP::false,
        'and months is marked NOT window-scoped' )
        or diag( 'This is the finding that was CORRECT BEHAVIOUR reading as '
            . 'broken: months covers all history on purpose, and the report '
            . 'said so nowhere, so months summing to 2.6x the window read as '
            . 'a leak.' );
    ok( !exists $r->{window_scoped}{events},
        'and events is absent rather than given a boolean that would lie' );
};

# --- invariant 6: no field claims to count people ----------------------------
subtest 'nothing in the report claims to have measured a person' => sub {
    ok( !exists $r->{totals}{human_visits},
        'totals.human_visits is gone' )
        or diag( 'It was the same scalar as pageviews under a name that '
            . 'asserted something the engine never measured.' );
    ok( !exists $r->{traffic_classes}{human},
        'and there is no `human` class' );
    like( $r->{notes}, qr/UPPER BOUND/,
        'the notes say the group is an upper bound on people' );
    like( $r->{notes}, qr/no_agent/,
        'and that empty user-agents are counted outside it' );
};

done_testing();
