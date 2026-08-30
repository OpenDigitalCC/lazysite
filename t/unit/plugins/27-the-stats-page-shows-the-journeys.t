#!/usr/bin/perl
# SM399: the third surface for SM393's trails.
#
# SM393 recorded the ordered journeys, SM394 gave an agent a way to read them,
# and the operator - the person the manager exists for - still could not see
# them at all. Three surfaces, and the human one was last.
#
# THE PANEL SHOWS ONLY WHAT TRAILS UNIQUELY ANSWER. Entry pages, exit pages and
# depth are already rendered on this page by SM363, from the aggregates over
# EVERY visit. Trails are capped at 2000 a day and expire after 30, so a second
# copy of those figures would disagree with the first on any busy site, and an
# operator would have no way to tell which was wrong. Asserted below, because
# "we deliberately did not add it" is invisible to a reader of the diff.
#
# WHAT IS ASSERTED
#   the plugin declares the day as a CHOICE, built from the files that exist
#   the choice list follows the files - an expired day stops being offered
#   the route counts cover the WHOLE day even when the sample is capped
#   the panel says so on the page, so a reader is never left to work it out
#   the panel adds NO inline event handlers - it must not grow the CSP debt
#   every CSS class it uses actually exists in the manager stylesheet
#   visitor-supplied paths are escaped
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root   = repo_root();
my $plugin = "$root/plugins/stats.pl";
my $pagef  = "$root/starter/manager/stats.md";
plan skip_all => "no $plugin" unless -f $plugin && -f $pagef;

my $page = do { open my $fh, '<', $pagef or die $!; local $/; <$fh> };

# ---------------------------------------------------------------------
# The plugin side
# ---------------------------------------------------------------------
my $now = time();
# SM600: THE DAY COMES FROM THE RECORDS, NOT FROM NOW.
#
# This fixture stamps its records 90 minutes back so the session is older than
# SESSION_GAP and the export closes it into a trail. It used to derive the day
# it asks for from `$now`, and for the 90 minutes after UTC midnight those are
# opposite sides of midnight: written under yesterday, asked for today. The
# same commit passed its release gate at 23:18 UTC and failed at 00:20.
#
# `$now` itself stays the real clock, deliberately: the export decides what is
# old enough to close by comparing against the real time, so back-dating $now
# stops sessions closing at all and no trail is written.
my $rec   = $now - 5400;
my @gm    = gmtime($rec);
my $today = sprintf '%04d-%02d-%02d', $gm[5] + 1900, $gm[4] + 1, $gm[3];
my $ymd   = sprintf '%04d%02d%02d',   $gm[5] + 1900, $gm[4] + 1, $gm[3];

# $n visits that all took the SAME route, plus one that took another. Aged past
# SESSION_GAP so the export closes them - an open visit has no trail.
sub build {
    my ($n) = @_;
    my $d = tempdir( 'lazysite-journeys-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    make_path( "$d/lazysite/logs", "$d/lazysite/stats", "$d/lazysite/cache" );
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_url: https://d.example.io\n";
    close $cf;

    open my $lf, '>', "$d/lazysite/logs/access-$ymd.jsonl" or die $!;
    my $ev = sub {
        my ( $ago, $path, $tok ) = @_;
        printf {$lf} qq({"t":%d,"p":"%s","s":200,"ch":"page","v":"%s","ua":"Mozilla/5.0 Chrome/120"}\n),
            $now - $ago, $path, $tok;
    };
    for my $v ( 1 .. $n ) {
        $ev->( 5400, '/',        "V$v" );
        $ev->( 5360, '/pricing', "V$v" );
        $ev->( 5300, '/contact', "V$v" );
    }
    $ev->( 5200, '/about', 'ODD' );
    $ev->( 5180, '/',      'ODD' );
    close $lf;

    `DOCUMENT_ROOT=\Q$d\E $^X \Q$plugin\E --export --window 30 2>/dev/null`;
    return $d;
}

sub run_action {
    my ( $d, @a ) = @_;
    my $args = join ' ', map { quotemeta } @a;
    my $out  = `DOCUMENT_ROOT=\Q$d\E $^X \Q$plugin\E $args 2>/dev/null`;
    return decode_json( $out || '{}' );
}

{
    my $d = build(3);

    my $desc = run_action( $d, '--describe' );
    my ($act) = grep { $_->{id} eq 'trails' } @{ $desc->{actions} || [] };
    ok( $act, 'the plugin declares a trails action' ) or BAIL_OUT('no trails action');
    is( $act->{run}, 'action', 'as a parameterised action' );
    is_deeply( [ map { $_->{id} } @{ $act->{choices} || [] } ], [$today],
        'and offers the day as a CHOICE, built from the file that exists' );

    my $v = run_action( $d, '--action', 'trails', '--choice', $today );
    ok( $v->{ok}, 'the action answers' ) or diag( $v->{error} // '' );
    is( $v->{visits}, 4, 'it counts every recorded visit' );

    my ($top) = @{ $v->{journeys} || [] };
    is( $top->{key}, '/ > /pricing > /contact',
        'the route is the ordered sequence, which no aggregate can answer' );
    is( $top->{count}, 3, 'and three visits that took it are ONE row counted three times' );

    # The panel must not duplicate what SM363 already renders from the
    # aggregates over every visit.
    ok( !exists $v->{entries}, 'it does not re-derive entry pages' );
    ok( !exists $v->{exits},   'nor exit pages' );
    ok( !exists $v->{depth},   'nor the depth histogram' );

    # An expired day stops being offered the moment its file goes.
    unlink "$d/lazysite/stats/trails/$today.json" or die $!;
    my $desc2 = run_action( $d, '--describe' );
    my ($act2) = grep { $_->{id} eq 'trails' } @{ $desc2->{actions} || [] };
    is_deeply( $act2->{choices}, [], 'a deleted day is no longer offered' );

    my $gone = run_action( $d, '--action', 'trails', '--choice', $today );
    ok( !$gone->{ok}, 'and asking for it is refused rather than answered emptily' );

    ok( !run_action( $d, '--action', 'nope' )->{ok}, 'an unknown action is refused' );
    ok( !run_action( $d, '--action', 'trails', '--choice', 'nonsense' )->{ok},
        'and a malformed day is refused' );
}

# The load-bearing one: a day bigger than the response cap must still count its
# routes over the WHOLE day, or the headline is derived from a sample and looks
# like the day.
{
    my $d = build(220);
    my $v = run_action( $d, '--action', 'trails', '--choice', $today );
    cmp_ok( $v->{visits}, '>', 200, 'the day holds more than the response cap' );
    ok( $v->{truncated}, 'so the sample is truncated' );
    cmp_ok( scalar @{ $v->{trails} }, '<=', 200, 'and the sample is capped' );
    is( $v->{summary_covers}, $v->{visits},
        'but the route counts cover the whole day, not the sample' );
    my ($top) = @{ $v->{journeys} || [] };
    is( $top->{count}, 220,
        'proved by the count exceeding what the sample could have seen' );
}

# ---------------------------------------------------------------------
# The page side
# ---------------------------------------------------------------------
like( $page, qr/id="trail-day"/,         'the page has a day picker' );
like( $page, qr/action_id:\s*'trails'/,  'and calls the trails action' );
like( $page, qr/params:\s*\{\s*choice:/, 'passing the day as a choice' );
like( $page, qr/initTrails\(p\)/,        'wired from the descriptor already fetched' );
like( $page, qr/summary_covers/,         'the page reads the whole-day figure' );
like( $page, qr/This list is a sample/,  'and says on the page when it is showing one' );
like( $page, qr/sesc\(st\.p\)/,          'visitor-supplied paths are escaped' );

# NO NEW INLINE HANDLERS. Inline event attributes are the entire reason the
# manager breaks under an enforcing CSP - a nonce does not apply to them - so
# new UI is bound with addEventListener from a script block that already passes.
my ($journeys) = $page =~ m{(// SM399: the journeys panel.*)}s;
$journeys //= '';
ok( length $journeys, 'the journeys code can be isolated' );
unlike( $journeys, qr/\bon(?:click|change|input|submit)\s*=/,
    'the journeys panel adds no inline event handlers' );
like( $journeys, qr/addEventListener/, 'it binds its listener instead' );

# Every CSS class it uses must exist, or it renders unstyled and nobody notices
# until they look at it.
my $css = do {
    open my $fh, '<', "$root/starter/lazysite/manager/assets/manager-classic.css" or die $!;
    local $/;
    <$fh>;
};
# BOTH the card markup and the classes the script emits. An earlier version of
# this check scanned only the script, and a bad class on the day picker - which
# lives in the card - sailed through it.
my ($card) = $page
    =~ m{(<div class="mg-card">\s*<div class="mg-card-header">\s*<span class="mg-card-title">Visitor journeys.*?)<div class="mg-card">}s;
ok( length( $card // '' ), 'the journeys card markup can be isolated' );

my %used = map { $_ => 1 } ( ( $journeys . ( $card // '' ) ) =~ /class="([^"]*mg-[^"]*)"/g );
my %seen;
for my $attr ( keys %used ) {
    for my $c ( grep { /^mg-/ } split ' ', $attr ) { $seen{$c} = 1 }
}
for my $c ( sort keys %seen ) {
    ok( $css =~ /\.\Q$c\E\b/, "the panel's class $c exists in the stylesheet" );
}

done_testing();
