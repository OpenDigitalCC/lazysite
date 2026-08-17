#!/usr/bin/perl
# SM340: the export cache was written every run and never read.
#
# `_load_export_cache` accepted version 1. The first-party ingester writes
# version 2. So on the DEFAULT path the load returned undef, `|| {}` supplied an
# empty hash, and the cache was discarded on every single call - the per-file
# byte offsets, the entire point of the incremental design, had never once been
# used.
#
# HOW IT WAS FOUND, because it decides how this file is written. Not by reading
# the version numbers - that is how it survived. It was found by SABOTAGE: set
# the stored offsets to a value that a working cache would act on, and see
# whether the answer changes. A check that can only confirm will confirm a
# broken thing; a check that can come back wrong is evidence.
#
# So every assertion below is built to be able to fail. The first attempt at the
# sabotage set the offsets to 99,999,999, which is PAST THE END of the log - and
# the ingester resets an over-long offset to zero, correctly, because that is
# what a truncated log looks like. It read the same whether the cache was
# honoured or not, and proved nothing. The version here claims the log is
# exactly consumed, which a working cache must act on and a discarded one
# cannot see.
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

# A docroot on the FIRST-PARTY path, which is the default and the one that was
# broken. A fixture without first-party logs falls back to the server-log path,
# whose cache did load - which is exactly why this went unseen for so long, and
# why the fixture that first measured SM338 showed the intended behaviour.
sub fixture {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/cache");
    make_path("$d/lazysite/logs");
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "site_url: https://demo.example.io\nfirst_party: true\n";
    close $cf;
    return $d;
}

sub log_event {
    my ( $d, $when, $path, $status, $visitor, $ref ) = @_;
    my $day = strftime( '%Y%m%d', localtime($when) );
    open my $fh, '>>', "$d/lazysite/logs/access-$day.jsonl" or die $!;
    print $fh encode_json( {
            t => $when,
            p => $path,
            s => $status,
            b => 100,
            u => 'Mozilla/5.0 Chrome/120',
            v => $visitor,
            r => ( $ref // '-' ),
    } ) . "\n";
    close $fh;
}

sub export {
    my ($d) = @_;
    local $ENV{DOCUMENT_ROOT} = $d;
    my $out = qx($^X \Q$plugin\E --export --window 30 2>/dev/null);
    return decode_json($out);
}

sub read_cache {
    my ($d) = @_;
    open my $fh, '<', "$d/lazysite/cache/stats-export.json" or return undef;
    local $/;
    return decode_json(<$fh>);
}

sub write_cache {
    my ( $d, $c ) = @_;
    open my $fh, '>', "$d/lazysite/cache/stats-export.json" or die $!;
    print $fh encode_json($c);
    close $fh;
}

subtest 'the shape check does not depend on where it sits in the file' => sub {
    # The first fix declared `our %CACHE_SHAPES = (1 => ..., 2 => ...)` beside
    # the loader. The dispatch that reaches the loader runs EARLIER in the file
    # than that line, so the hash was still empty when consulted and every cache
    # was rejected - the same symptom as the original bug, for a completely
    # different reason. This file already carries three comments warning about
    # that trap for its regexes and its month map.
    my $src = do { open my $fh, '<', $plugin or die $!; local $/; <$fh> };
    like( $src, qr/sub _known_cache_shape \{/,
        'the check is a sub, which is bound at compile time' )
        or diag( 'A package variable assigned at file scope is not available to '
            . 'code that runs above its assignment, and the dispatch does.' );
    # Comments stripped first: the source explains the earlier mistake by
    # naming it, and the first version of this assertion matched that prose and
    # reported the defect still present. A test that reads documentation as
    # code will fail hardest on the code that documents itself best.
    my $code = join "\n", grep { !/^\s*#/ } split /\n/, $src;
    unlike( $code, qr/our\s+%CACHE_SHAPES/,
        'and not a package hash assigned below the dispatch that reads it' );
};

subtest 'a stored offset actually governs what is read' => sub {
    # THE SABOTAGE. Claim the log is exactly consumed and empty the buckets. A
    # loaded cache has nothing new to read and nothing to report from, so it
    # must answer zero. A discarded cache rebuilds from the log and answers five.
    my $d   = fixture();
    my $now = time() - 600;
    log_event( $d, $now + $_, '/article', 200, "visitor-$_" ) for 1 .. 5;

    my $first = export($d);
    is( $first->{totals}{human_visits}, 5, 'five requests, five human visits' );

    my $c = read_cache($d);
    ok( $c && ( $c->{v} // 0 ) == 2, 'the first-party cache was written, at v2' )
        or diag explain $c;

    for my $f ( keys %{ $c->{files} || {} } ) {
        $c->{files}{$f} = -s "$d/lazysite/logs/$f";    # legitimately consumed
    }
    $c->{days}   = {};
    $c->{events} = [];
    write_cache( $d, $c );

    my $second = export($d);
    is( $second->{totals}{human_visits}, 0,
        'the stored offset was honoured and the log was not re-read' )
        or diag( 'Five means the cache was discarded and the whole log '
            . 're-ingested, which is the defect: the offsets are the entire '
            . 'point of the incremental design and were never used.' );
};

subtest 'a second call does not re-read what the first already consumed' => sub {
    # THIS SUBTEST WAS REWRITTEN. Its first version checked that the offset
    # advanced to the end of the file and that events were not duplicated - and
    # both were true of the BROKEN code too, because rebuilding from scratch
    # every call lands on the same offset and produces the same events. It read
    # like a test of incrementality and could not fail on the defect it named.
    #
    # This version rewrites a line the reader has already passed, in place and
    # at the same byte length so no offset shifts. An incremental reader never
    # looks at those bytes again and keeps reporting what it read the first
    # time. A rebuilding reader sees the new content. The two answers differ,
    # which is the only reason the check is worth running.
    my $d   = fixture();
    my $now = time() - 600;
    log_event( $d, $now + $_, '/article', 200, "v$_" ) for 1 .. 3;

    my $first = export($d);
    is_deeply( [ map { $_->{key} } @{ $first->{top_pages} || [] } ], ['/article'],
        'the first call reports what is in the log' );

    my ($log) = glob "$d/lazysite/logs/access-*.jsonl";
    my $body = do { open my $fh, '<', $log or die $!; local $/; <$fh> };
    ( my $rewritten = $body ) =~ s{"/article"}{"/changed"}g;
    is( length($rewritten), length($body),
        'the rewrite is byte-for-byte the same length, so no offset moves' );
    open my $out, '>', $log or die $!;
    print $out $rewritten;
    close $out;

    my $second = export($d);
    is_deeply( [ map { $_->{key} } @{ $second->{top_pages} || [] } ], ['/article'],
        'the second call does not re-read bytes it had already consumed' )
        or diag( 'Reporting /changed means the whole log was ingested again. '
            . 'That is the defect measured in the field as ~3.5s on every '
            . 'call, with window=1 costing what window=365 cost.' );
};

subtest 'a promotion reaches back to what an earlier batch already counted'
    => sub {
    # THE REGRESSION THE FIX INTRODUCES, and the reason it is not a one-line
    # change. While the cache was discarded every call, a probe arriving late
    # always reclassified that visitor's earlier requests - by brute force,
    # because the whole log was re-read. With the cache honoured those events
    # are already counted under `human` and the promoting batch has to reach
    # back for them.
    #
    # It matters because the scanner's homepage hit is precisely what SM213
    # classifies per visitor to remove, and SM332 needs five distinct 404s that
    # may well arrive either side of a call.
    my $d   = fixture();
    my $now = time() - 600;

    # Batch one: a homepage hit and two probes, under the threshold of five.
    log_event( $d, $now,      '/',                    200, 'sweeper' );
    log_event( $d, $now + 10, '/wp-json/batch/v1',    404, 'sweeper' );
    log_event( $d, $now + 20, '/wp/wp-json/batch/v1', 404, 'sweeper' );
    my $one = export($d);
    is( $one->{totals}{human_visits}, 3,
        'two probes is under the threshold, so nothing is promoted yet' );

    # Batch two: three more distinct probes. The threshold is crossed HERE.
    log_event( $d, $now + 60, '/blog/wp-json/batch/v1', 404, 'sweeper' );
    log_event( $d, $now + 70, '/old/wp-json/batch/v1',  404, 'sweeper' );
    log_event( $d, $now + 80, '/test/wp-json/batch/v1', 404, 'sweeper' );
    my $two = export($d);

    is( $two->{totals}{human_visits}, 0,
        'the homepage hit from the FIRST batch is no longer counted human' )
        or diag( 'Three means the reach-back did not happen: those events were '
            . 'tallied before the promotion and stayed where they were put. '
            . 'That is the scanner homepage hit SM213 exists to remove, and '
            . 'it would be the top journey on the site.' );

    is_deeply( [ map { $_->{key} } @{ $two->{top_pages} || [] } ], [],
        'and it is out of top_pages, not merely relabelled' )
        or diag( 'A reach-back that rewrote the event ring without moving the '
            . 'aggregates would look correct in the sample and be wrong in '
            . 'every number anybody reads.' );

    is( ( $two->{referrers}{direct} // -1 ), 0,
        'the referrer it was counted under is reversed too' );
    is( $two->{traffic_classes}{scanner}{visits}, 6,
        'all six requests are the scanner, across both batches' );
    };

subtest 'reversal cannot drive a count below nothing' => sub {
    # A reach-back subtracts from buckets. If it ever ran twice for the same
    # event, or against a bucket that did not contain it, the arithmetic would
    # go negative and a negative page view is a number that can only come from
    # a bug. The ring's class is rewritten as it is reconciled, which is what
    # makes it once-only, and this is the assertion that it worked.
    my $d   = fixture();
    my $now = time() - 600;
    log_event( $d, $now,      '/',             200, 'sweeper' );
    log_event( $d, $now + 10, '/wp-login.php', 404, 'sweeper' );
    export($d);
    export($d);    # a second call must not reconcile the same events again
    my $r = export($d);

    cmp_ok( $r->{totals}{human_visits}, '>=', 0, 'human visits is not negative' );
    for my $c ( sort keys %{ $r->{traffic_classes} || {} } ) {
        cmp_ok( $r->{traffic_classes}{$c}{visits}, '>=', 0,
            "the $c class is not negative" );
    }
    for my $p ( @{ $r->{top_pages} || [] } ) {
        cmp_ok( $p->{count}, '>', 0, "top_pages entry $p->{key} is positive" );
    }
    is( $r->{traffic_classes}{scanner}{visits}, 2,
        'and the promotion is applied exactly once, not once per call' );
};

subtest 'the ring carries reconciliation fields that are NOT exported' => sub {
    # The reach-back needs the day and the referrer of an already-counted event.
    # Those live in the cache ring. The export used to hand the ring out
    # verbatim, so adding a field to it would have published a referrer attached
    # to a visitor token - which is a privacy change arriving as a side effect
    # of a performance fix.
    my $d   = fixture();
    my $now = time() - 600;
    log_event( $d, $now, '/article', 200, 'someone', 'https://referrer.example/x' );
    my $r = export($d);

    my $c = read_cache($d);
    ok( $c->{events}[0]{ref}, 'the ring keeps the referrer for reconciliation' );
    ok( $c->{events}[0]{day}, 'and the day, so it can find the bucket' );

    my $ev = $r->{events}[0];
    ok( $ev, 'an event was exported' ) or return;
    is_deeply( [ sort keys %$ev ], [qw(class path status t visitor)],
        'the exported event carries exactly the published fields' )
        or diag( 'The ring is internal working state. Handing it out verbatim '
            . 'means any field added for internal use is published by '
            . 'accident - the export must enumerate what it publishes.' );

    # Scoped to the EVENTS, which is the concern. The referrer host also
    # appears in the aggregate top-referrers list, legitimately and by design -
    # the first version of this matched the whole document and flagged that,
    # which would have read as a privacy leak in a feature working correctly.
    # What must not happen is a referrer travelling beside a visitor token.
    unlike( encode_json( $r->{events} ), qr/referrer\.example/,
        'the per-event referrer does not leave with the visitor token' );
    like( encode_json( $r->{referrers} ), qr/referrer\.example/,
        'while the aggregate referrer list still reports the host, as it should' );
};

done_testing();
