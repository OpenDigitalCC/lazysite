#!/usr/bin/perl
# SM1063: the connector sweep counts what it expired and what never answered.
# Its counters were declared after an array in one list assignment, so the
# array took the whole right-hand list and both counters started undef: a
# sweep with nothing to expire reported `expired: null`, and a run record
# with no stuck calls said `unanswered: null`. A count of nothing is 0.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib", "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir);
use JSON::PP;
use Lazysite::Manager::Connectors;

my $d = site_tempdir();
make_path("$d/lazysite/connectors");
my $calls = "$d/lazysite/connectors/calls.jsonl";

sub write_calls {
    open my $f, '>', $calls or die "$calls: $!";
    print {$f} encode_json($_), "\n" for @_;
    close $f;
}

subtest 'a recent answered call: nothing expires, nothing is stuck' => sub {
    write_calls( { call_id => 'new', connector => 'echo', at => time - 60, state => 'answered' } );
    my $s = Lazysite::Manager::Connectors::sweep($d);
    ok( $s->{ok},                 'swept' );
    ok( defined $s->{expired},    'expired is a count, not undef' );
    ok( defined $s->{unanswered}, 'unanswered is a count, not undef' );
    is( $s->{expired},    0, 'none expired' );
    is( $s->{unanswered}, 0, 'none unanswered' );
    is( $s->{kept},       1, 'the one record is kept' );
    my $json = JSON::PP->new->canonical->encode($s);
    unlike( $json, qr/null/, 'the run record carries no null' );
};

subtest 'an old answered call: one expired, none unanswered' => sub {
    write_calls( { call_id => 'old', connector => 'echo', at => time - 400 * 86400, state => 'answered' } );
    my $s = Lazysite::Manager::Connectors::sweep($d);
    is( $s->{expired}, 1, 'one expired' );
    ok( defined $s->{unanswered}, 'unanswered is still a count' );
    is( $s->{unanswered}, 0, 'and it is 0' );
};

subtest 'a recent unanswered call: none expired, one stuck' => sub {
    write_calls( { call_id => 'stuck', connector => 'echo', at => time - 60, state => 'unanswered' } );
    my $s = Lazysite::Manager::Connectors::sweep($d);
    ok( defined $s->{expired}, 'expired is still a count' );
    is( $s->{expired},    0, 'and it is 0' );
    is( $s->{unanswered}, 1, 'one unanswered' );
};

# The same assignment put the two zeros into the kept list: kept was off by
# two, and a sweep that expired anything wrote "00" in front of the first kept
# record, which no longer decoded and was silently dropped by the next read.
subtest 'a sweep that expires one record keeps the rest intact' => sub {
    write_calls(
        { call_id => 'old', connector => 'echo', at => time - 400 * 86400, state => 'answered' },
        { call_id => 'keep', connector => 'echo', at => time - 60, state => 'answered' },
    );
    my $s = Lazysite::Manager::Connectors::sweep($d);
    is( $s->{expired}, 1, 'one expired' );
    is( $s->{kept},    1, 'one kept' );
    open my $f, '<', $calls or die "$calls: $!";
    my @lines = <$f>;
    close $f;
    is( scalar @lines, 1, 'the file holds one line' );
    my $r = eval { decode_json( $lines[0] ) };
    is( $r && $r->{call_id}, 'keep', 'and it is the kept record, still readable' );
};

done_testing;
