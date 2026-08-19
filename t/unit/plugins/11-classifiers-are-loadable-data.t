#!/usr/bin/perl
# SM391: the visitor classifiers are data, updatable without editing the engine.
#
# Every pattern in stats.pl is a signature list, and signature lists date. SM332
# is the proof: `/wp-login.php` was caught by the `.php` rule and its modern
# replacement `/wp-json/batch/v1` was caught by nothing, so a WordPress
# enumeration ran as `human`. The gap existed because updating a signature meant
# editing, testing and RELEASING the engine.
#
# THREE FAILURE DIRECTIONS, which are what this actually tests:
#
#   a broken ruleset must fall back to the built-ins, not disarm the classifier
#   a bad single rule must cost that rule and not the file
#   the ruleset in force must be ATTRIBUTABLE in the output
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

my $d = tempdir( 'lazysite-rules-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
make_path( "$d/lazysite/logs", "$d/lazysite/stats" );
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_url: https://d.example.io\nfirst_party_analytics: on\n";
close $cf;

# 'Zephyrus' is deliberately a word NO built-in matches. The first version of
# this fixture used 'ZanyNewCrawler', which contains "crawl" - so the built-in
# already classified it and the test proved nothing in either direction.
#
# 'curl/8' is here for a different reason: it is matched by a BUILT-IN rule, so
# emptying the ruleset changes its class. Without a client that depends on a
# built-in, "the built-ins still apply" cannot be observed at all - the first
# version of this fixture had only an unmatched UA and a browser, so disarming
# the classifier entirely left every assertion passing.
my @UAS = ( 'Mozilla/5.0 Chrome/120', 'Zephyrus/2.0', 'curl/8' );

my $ymd = do { my @t = gmtime; sprintf '%04d%02d%02d', $t[5] + 1900, $t[4] + 1, $t[3] };
open my $lf, '>', "$d/lazysite/logs/access-$ymd.jsonl" or die $!;
my $now = time();
my $i   = 0;
for my $ua (@UAS) {
    printf {$lf} qq({"t":%d,"p":"/p%d","s":200,"ch":"page","v":"v%d","ua":"%s"}\n),
        $now, $i, $i, $ua;
    $i++;
}
close $lf;

sub export_now {
    my $out = `DOCUMENT_ROOT=\Q$d\E $^X \Q$PLUGIN\E --export --window 30 2>/dev/null`;
    return eval { decode_json($out) } || {};
}

sub ruleset {
    my ($body) = @_;
    my $f = "$d/lazysite/stats/classifiers.json";
    if ( defined $body ) {
        open my $fh, '>', $f or die $!;
        print {$fh} $body;
        close $fh;
    }
    else { unlink $f }
    return;
}

ruleset(undef);
my $base = export_now();

subtest 'with no ruleset, the built-ins apply and say so' => sub {
    is( $base->{classifier_version}, 'built-in', 'the output names the ruleset' )
        or diag( '"the numbers changed" and "the rules changed" are different '
            . 'answers, and a reader cannot tell them apart without this.' );
    is( $base->{traffic_classes}{human}{visits}, 2,
        'an unknown client counts as human' )
        or diag( 'If this is not 2 the fixture UA is already matched by a '
            . 'built-in, and the override below would prove nothing.' );
};

subtest 'a ruleset adds a signature with no code change' => sub {
    ruleset('{"version":"test-1","rules":{"bot":"bot|crawl|spider|zephyrus"}}');
    my $r = export_now();
    is( $r->{classifier_version}, 'test-1', 'the ruleset is named in the output' );
    is( $r->{traffic_classes}{bot}{visits}, 2,
        'the new signature classifies, AND the built-in curl match survives' )
        or diag( 'A ruleset EXTENDS the built-ins. Replacing them would mean '
            . 'an operator adding one crawler silently loses curl, wget and '
            . 'the rest - and the loss shows up as a quiet rise in the human '
            . 'count rather than as an error.' );
    is( $r->{traffic_classes}{human}{visits}, 1, 'and the browser still does not' )
        or diag( 'An override that catches everything is worse than one that '
            . 'catches nothing: it empties the class an operator reads.' );
};

subtest 'a broken ruleset falls back rather than disarming' => sub {
    ruleset('not json at all');
    my $r = export_now();
    is( $r->{classifier_version}, 'built-in', 'it reverts to the built-ins' );
    is( $r->{traffic_classes}{human}{visits}, 2,
        'and classifies exactly as it did with no file' );
    is( $r->{traffic_classes}{bot}{visits}, 1,
        'the BUILT-IN rules are still applying - curl is still a bot' )
        or diag( 'The alternative - classifying nothing, or everything as '
            . 'human - is a silent and total failure of the thing an operator '
            . 'reads numbers from.' );
};

subtest 'one bad rule costs that rule, not the file' => sub {
    # An unclosed group will not compile. The other rule in the same file must
    # still apply, or a single typo disarms everything beside it.
    ruleset('{"version":"test-2","rules":{"bot":"bot|crawl|zephyrus","ai":"(unclosed"}}');
    my $r = export_now();
    is( $r->{classifier_version}, 'test-2', 'the ruleset is still in force' );
    is( $r->{traffic_classes}{bot}{visits}, 2,
        'the rule that compiles still classifies' )
        or diag( 'A file rejected wholesale for one bad pattern makes every '
            . 'edit an all-or-nothing risk, which is how people stop editing.' );
};

done_testing();
