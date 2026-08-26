#!/usr/bin/perl
# SM394: the read side of SM393.
#
# SM393 recorded the trails and nothing could read them. The agent that asked
# for them has no host access and sees only what analyse_visitors returns, so
# the data accumulated for an operator on the box and for nobody else. A feature
# whose requester cannot observe it is indistinguishable from one that does not
# work, which is why the selector is its own change rather than a later polish.
#
# WHAT IS ASSERTED
#   --trails returns the day's visits, with the sequence intact
#   --index lists which days HAVE trails, so a caller need not guess dates
#   that list comes from the directory, not the index file - trail files expire
#     and an index entry would outlive the file it names
#   a day with no trails says SO, and says why it might be missing
#   a malformed day is refused rather than guessed at
#   the response cap truncates, and SAYS it truncated and by how much
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $PLUGIN = repo_root() . '/plugins/stats.pl';
plan skip_all => "no $PLUGIN" unless -f $PLUGIN;

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
my $TODAY = sprintf '%04d-%02d-%02d', $gm[5] + 1900, $gm[4] + 1, $gm[3];
my $YMD   = sprintf '%04d%02d%02d',   $gm[5] + 1900, $gm[4] + 1, $gm[3];

# $visitors visits, each of $steps pages, all aged past SESSION_GAP so the
# export closes them and they become trails.
sub build {
    my ( $visitors, $steps ) = @_;
    my $d = tempdir( 'lazysite-sel-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    make_path( "$d/lazysite/logs", "$d/lazysite/stats", "$d/lazysite/cache" );
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_url: https://d.example.io\n";
    close $cf;

    open my $lf, '>', "$d/lazysite/logs/access-$YMD.jsonl" or die $!;
    for my $v ( 1 .. $visitors ) {
        for my $s ( 1 .. $steps ) {
            printf {$lf} qq({"t":%d,"p":"/p%d","s":200,"ch":"page","v":"V%d","ua":"Mozilla/5.0 Chrome/120"}\n),
                $rec + ( $s * 10 ), $s, $v;
        }
    }
    close $lf;
    return $d;
}

sub ask {
    my ( $d, @sel ) = @_;
    my $args = join ' ', map { quotemeta } @sel;
    my $out  = `DOCUMENT_ROOT=\Q$d\E $^X \Q$PLUGIN\E --export $args 2>/dev/null`;
    return decode_json( $out || '{}' );
}

# --- an ordinary day ---------------------------------------------------
{
    my $d = build( 3, 4 );
    my $r = ask( $d, '--trails', $TODAY );

    ok( $r->{ok}, 'the selector answers' ) or diag( $r->{error} // 'no error given' );
    is( $r->{date},   $TODAY, 'the reply names the day it is for' );
    is( $r->{visits}, 3,      'all three visits are there' );
    ok( !$r->{truncated}, 'a small day is not truncated' );

    my $t = $r->{trails}[0];
    is_deeply( [ map { $_->{p} } @{ $t->{steps} } ],
        [ '/p1', '/p2', '/p3', '/p4' ],
        'the sequence survives the round trip in order' );
    is( $t->{entry}, '/p1', 'entry is carried' );
    is( $t->{exit},  '/p4', 'exit is carried' );
    ok( defined $t->{steps}[0]{gap},       'the step gap is carried' );
    ok( length( $t->{steps}[0]{c} // '' ), 'the class at the time is carried' );

    # Discovery: a caller that does not know which days exist.
    my $ix = ask( $d, '--index' );
    is_deeply( $ix->{trail_days}, [$TODAY], 'the index lists the days that have trails' );

    # The list must follow the FILES, not an index entry - trails expire and the
    # rollups do not, so an index-derived list would name days that are gone.
    unlink "$d/lazysite/stats/trails/$TODAY.json" or die $!;
    my $ix2 = ask( $d, '--index' );
    is_deeply( $ix2->{trail_days}, [],
        'a deleted trail file leaves the index listing it no longer' );
}

# --- nothing there, and nonsense ---------------------------------------
{
    my $d = build( 1, 2 );

    my $none = ask( $d, '--trails', '2001-01-01' );
    ok( !$none->{ok}, 'a day with no trails is not reported as success' );
    like( $none->{error}, qr/trails/i,
        'and the refusal is about TRAILS, not the generic day/month rollup' );
    like( $none->{error}, qr/expired|never recorded/i,
        'and says why it might be missing, which the caller cannot otherwise tell' );

    my $bad = ask( $d, '--trails', 'not-a-day' );
    ok( !$bad->{ok}, 'a malformed day is refused' );
    like( $bad->{error}, qr/YYYY-MM-DD/, 'and the refusal says the shape it wanted' );
}

# --- the response cap --------------------------------------------------
{
    # More visits than the response cap, so the reply must shorten - and must
    # not pretend it is the whole day while doing it.
    my $d = build( 260, 2 );
    my $r = ask( $d, '--trails', $TODAY );

    ok( $r->{ok}, 'a large day still answers' );
    cmp_ok( $r->{visits}, '>', 200, 'the day really does hold more than the cap' );
    is( $r->{returned},           200, 'the reply is capped' );
    is( scalar @{ $r->{trails} }, 200, 'and the list is the length it claims' );
    ok( $r->{truncated}, 'and it SAYS it was truncated' );
    cmp_ok( $r->{visits}, '>', $r->{returned},
        'the reply states the size of the day as well as the size of the answer' );
}

done_testing();
