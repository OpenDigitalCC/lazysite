#!/usr/bin/perl
# SM392: one sweep behind a shared address must not reclassify everyone behind it.
#
# _visitor_key is hmac(ymd|ip) - date and address, no actor - so the unit being
# promoted to `scanner` was AN ADDRESS. One sweep took the whole address for the
# day, whatever else arrived from it.
#
# MEASURED IN THE FIELD: eleven AI user-agents on real 200 pages, GOOGLEBOT
# INCLUDED AS A CONTROL, all classified scanner, because the token had been
# promoted earlier and the user-agent was no longer consulted. A search crawler
# on an existing page reading as a scanner is the control failing.
#
# It lands hardest on the traffic an operator most wants separated: AI
# assistants fetch from provider-operated address pools shared by every user of
# that assistant. Corporate NAT and carrier CGNAT are the same shape for people.
#
# TWO THINGS THIS MUST NOT DO, and both are asserted below:
#   the promotion must still work - SM213 and SM332's reach-back are correct
#   the user-agent must NOT enter the COUNTING token, or one person with two
#   browsers becomes two visitors
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

my $d = tempdir( 'lazysite-nat-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
make_path( "$d/lazysite/logs", "$d/lazysite/stats" );
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_url: https://d.example.io\nfirst_party_analytics: on\n";
close $cf;

my $ymd = do { my @t = gmtime; sprintf '%04d%02d%02d', $t[5] + 1900, $t[4] + 1, $t[3] };
my $now = time();
open my $lf, '>', "$d/lazysite/logs/access-$ymd.jsonl" or die $!;
my $i = 0;
sub ev {
    my ( $path, $status, $ua ) = @_;
    printf {$lf} qq({"t":%d,"p":"%s","s":%d,"ch":"page","v":"SHAREDNAT","ua":"%s"}\n),
        $now + $i++, $path, $status, $ua;
}

# ONE ADDRESS. A scanner sweeping, a search crawler on a real page, and a
# person. All three share the counting token, as they would behind a NAT.
ev( $_, 404, 'python-requests/2.31' )
    for qw(/wp-json/batch/v1 /wp/ /wordpress/ /blog/ /old/ /test/);
ev( '/about',   200, 'Mozilla/5.0 (compatible; Googlebot/2.1)' );
ev( '/pricing', 200, 'Mozilla/5.0 Chrome/120' );
close $lf;

my $out = `DOCUMENT_ROOT=\Q$d\E $^X \Q$PLUGIN\E --export --window 30 2>/dev/null`;
my $r   = eval { decode_json($out) } || {};
my $tc  = $r->{traffic_classes}      || {};

subtest 'the sweep is still caught' => sub {
    is( $tc->{scanner}{visits}, 6, 'the scanner’s six missing paths are scanner' )
        or diag( 'Weakening the promotion is the wrong fix and would show up '
            . 'here. SM213 and SM332 are correct.' );
};

subtest 'and it does not take the address with it' => sub {
    is( $tc->{bot}{visits}, 1,
        'Googlebot on a real page is still a bot' )
        or diag( 'This is the control from the field report. A search crawler '
            . 'classified as a scanner means the user-agent was never '
            . 'consulted - the address had already decided.' );
    is( $tc->{human}{visits}, 1,
        'and the person behind the same address is still human' )
        or diag( 'On a corporate NAT or a carrier CGNAT this is every visitor '
            . 'behind one sweep.' );
};

subtest 'the counting token is unchanged, so visitors are not split' => sub {
    # The whole point of the counting token is that one person is one visitor.
    # Putting the user-agent into it would make a person with two browsers into
    # two, which breaks the number the feature exists to produce.
    is( $r->{totals}{unique_visitors}, 1,
        'three clients behind one address are ONE unique visitor' )
        or diag( 'If this is 3 the user-agent has leaked into the counting '
            . 'token, which is the fix that is worse than the defect.' );
};

done_testing();
