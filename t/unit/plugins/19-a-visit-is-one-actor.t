#!/usr/bin/perl
# SM417: a visit is ONE ACTOR's behaviour, and the token alone is an address.
#
# The visitor token is hmac(ymd|ip), so before this change every agent on one
# host - or every person behind one NAT - shared a single session: the field
# measured a four-page walk arriving MERGED with other traffic into one
# 22-step trail. SM392 already separated the PROMOTION key per source
# (token+user-agent) for exactly this reason; the session key now uses the
# same separation, so each actor's walk is its own visit and its own trail.
#
# What must NOT change: unique_visitors counts the bare token (SM392's rule -
# one person with two browsers must not become two visitors). And the change
# is a counting-basis bump (SM338, basis 3): visit counts RISE on
# shared-address traffic, which is the fix, and the day file must SAY it
# counts the new way so the step in the series is attributable to rules, not
# traffic.
#
# Driven end to end through the real writer: log lines in, day file out.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   qw(decode_json);
use POSIX      qw(strftime);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $PLUGIN = repo_root() . '/plugins/stats.pl';
plan skip_all => "no $PLUGIN" unless -f $PLUGIN;

my $d = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/logs", "$d/lazysite/cache" );
open my $cf, '>', "$d/lazysite/stats.conf" or die $!;
print {$cf} "site_url: https://d.example.io\nfirst_party_analytics: on\n";
close $cf;

my $now = time();
# SM600: the day comes from the RECORDS, not from now - inside 90 minutes of
# UTC midnight the two are opposite sides of it, and the fixture then asks for
# a day it never wrote. `$now` stays the real clock, because the export decides
# what is old enough to close by comparing against real time.
my $rec = $now - 5400;
my $ymd = do { my @t = gmtime($rec); sprintf '%04d%02d%02d', $t[5] + 1900, $t[4] + 1, $t[3] };
open my $lf, '>', "$d/lazysite/logs/access-$ymd.jsonl" or die $!;

sub ev {
    my ( $ago, $path, $tok, $ua ) = @_;
    printf {$lf} qq({"t":%d,"p":"%s","s":200,"ch":"page","v":"%s","ua":"%s"}\n),
        $now - $ago, $path, $tok, $ua;
}

# ONE token (one address), TWO actors, walks INTERLEAVED - which is exactly
# how they arrive from a shared host, and what merged before this change.
my $UA_A = 'Mozilla/5.0 Chrome/120';
my $UA_B = 'Mozilla/5.0 Firefox/126';
ev( 5400, '/',        'SHARED', $UA_A );
ev( 5390, '/about',   'SHARED', $UA_B );
ev( 5350, '/pricing', 'SHARED', $UA_A );
ev( 5340, '/contact', 'SHARED', $UA_B );
ev( 5300, '/docs',    'SHARED', $UA_A );
close $lf;

my $cmd = qq{DOCUMENT_ROOT=\Q$d\E $^X \Q$PLUGIN\E --export --window 30};
my $out = `$cmd 2>/dev/null`;
my $res = eval { decode_json($out) };
ok( ref $res eq 'HASH', 'the export ran' ) or BAIL_OUT('no export');

my $day = do {
    my @t = gmtime($rec);    # SM600: the records' day, not the clock's
    sprintf '%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3];
};

subtest 'the two actors are two visits and two trails' => sub {
    my $tf = "$d/lazysite/stats/trails/$day.json";
    ok( -f $tf, 'a trail file exists' ) or return;
    my $doc = decode_json( do { open my $fh, '<', $tf or die $!; local $/; <$fh> } );
    is( scalar @{ $doc->{trails} }, 2, 'TWO trails, not one merged walk' )
        or diag explain $doc->{trails};
    my ($a) = grep { $_->{entry} eq '/' } @{ $doc->{trails} };
    my ($b) = grep { $_->{entry} eq '/about' } @{ $doc->{trails} };
    ok( $a && $b, 'one per actor, each starting where that actor started' );
    is_deeply( [ map { $_->{p} } @{ $a->{steps} } ],
        [ '/', '/pricing', '/docs' ],
        'actor A walked its own three pages, uncontaminated' );
    is_deeply( [ map { $_->{p} } @{ $b->{steps} } ],
        [ '/about', '/contact' ],
        'actor B walked its own two' );
};

subtest 'unique visitors stays ONE - counting keeps the bare token' => sub {
    my $df = "$d/lazysite/stats/daily/$day.json";
    ok( -f $df, 'a day file exists' ) or return;
    my $doc = decode_json( do { open my $fh, '<', $df or die $!; local $/; <$fh> } );
    is( $doc->{unique_visitors}, 1,
        'one address is one visitor, however many actors it carries' );
    is( $doc->{sessions}, 2, 'and two sessions, one per actor' );
    is( $doc->{counting_basis}, 3,
        'the day SAYS it counts the new way (SM338 basis 3) - the visit-count '
            . 'step is attributable to rules, not traffic' );
};

# --- the OTHER ingester ------------------------------------------------------
#
# THIS SECTION EXISTS BECAUSE THE SABOTAGE MATRIX DEMANDED IT. Everything above
# drives the FIRST-PARTY log, which has carried the per-source key since SM392.
# Removing it from the server-log record changed nothing any test could see -
# and the server-log path is exactly where it was MISSING: SM392 added pkey to
# one ingester and every consumer falls back to the bare token when it is
# absent, so per-source promotion had silently never happened on a site whose
# stats come from the web server's own log. Two ingesters, one rule, and only
# one of them was obeying it.
subtest 'the server-log ingester separates by source too' => sub {
    my $sd = tempdir( CLEANUP => 1 );
    make_path( "$sd/lazysite/logs", "$sd/lazysite/cache" );
    open my $c2, '>', "$sd/lazysite/stats.conf" or die $!;
    print {$c2} "site_url: https://d.example.io\n";    # NO first_party_analytics
    close $c2;

    # Common Log Format, which is what find_log's candidates all are.
    my $log = "$sd/server-access.log";
    open my $sl, '>', $log or die $!;
    my @stamp = gmtime($rec);
    my $when  = POSIX::strftime( '%d/%b/%Y:%H:%M:%S +0000', @stamp );
    my $line  = sub {
        my ( $path, $ua ) = @_;
        return qq{198.51.100.7 - - [$when] "GET $path HTTP/1.1" 200 512 "-" "$ua"\n};
    };
    # ONE address, TWO user-agents - the shape that merged before this change.
    print {$sl} $line->( '/',        $UA_A );
    print {$sl} $line->( '/about',   $UA_B );
    print {$sl} $line->( '/pricing', $UA_A );
    close $sl;

    my $out2 = `DOCUMENT_ROOT=\Q$sd\E LAZYSITE_ACCESS_LOG=\Q$log\E $^X \Q$PLUGIN\E --export --window 30 2>/dev/null`;
    my $r2 = eval { decode_json($out2) };
    ok( ref $r2 eq 'HASH', 'the server-log export ran' ) or return;

    my $df = "$sd/lazysite/stats/daily/$day.json";
    ok( -f $df, 'a day file was written from the server log' ) or return;
    my $doc = decode_json( do { open my $fh, '<', $df or die $!; local $/; <$fh> } );
    is( $doc->{unique_visitors}, 1, 'one address is still one visitor' );
    is( $doc->{sessions}, 2,
        'and TWO sessions - the per-source key reached this ingester too' )
        or diag( 'pkey is absent from this ingester\'s record, so every '
            . 'consumer fell back to the bare token: SM392\'s separation was '
            . 'never happening on a server-log site.' );
};

# --- SM417: scanner_inferred, on the FIRST-PARTY path ------------------------
#
# `scanner_by` is written under the PROMOTION key and was read under the
# COUNTING token. Wherever the two differ - every first-party site since SM392
# put pkey on that record - the read missed and scanner_inferred was silently
# 0, so an operator could not tell a behavioural promotion from a signature
# match, which is the only thing the field is for. Nothing caught it because
# the sweep test drives the server-log path, where pkey was absent and the two
# keys happened to be equal. Two ingesters again, one of them exercised.
subtest 'a behavioural promotion is recorded as inferred on the first-party log'
    => sub {
    my $sd = tempdir( CLEANUP => 1 );
    make_path( "$sd/lazysite/logs", "$sd/lazysite/cache" );
    open my $c3, '>', "$sd/lazysite/stats.conf" or die $!;
    print {$c3} "site_url: https://d.example.io\nfirst_party_analytics: on\n";
    close $c3;

    open my $l3, '>', "$sd/lazysite/logs/access-$ymd.jsonl" or die $!;
    # Six distinct 404s inside the window: a SWEEP by behaviour, carrying no
    # probe signature at all, so the promotion can only be the inferred kind.
    printf {$l3} qq({"t":%d,"p":"/gone-%d","s":404,"ch":"page","v":"SWEEPER","ua":"%s"}\n),
        $rec + 300 + $_, $_, $UA_A
        for 0 .. 5;
    close $l3;

    my $o = `DOCUMENT_ROOT=\Q$sd\E $^X \Q$PLUGIN\E --export --window 30 2>/dev/null`;
    ok( length $o, 'the export ran' );

    my $df = "$sd/lazysite/stats/daily/$day.json";
    ok( -f $df, 'a day file exists' ) or return;
    my $doc = decode_json( do { open my $fh, '<', $df or die $!; local $/; <$fh> } );
    cmp_ok( $doc->{scanner_inferred}, '>', 0,
        'the rollup records the promotion as INFERRED, not matched' )
        or diag( 'scanner_by is keyed on the promotion key; reading it with '
            . 'the counting token misses on every first-party site.' );
    };

done_testing();
