#!/usr/bin/perl
# Ruling 206 (item 15 of the 0.16.9 fault survey): THE CONNECTOR CALL SWEEP
# LEAVES A DAMAGED RECORD AS FOUND.
#
# Connectors::sweep (the scheduler's connectors-sweep job) skipped a line of
# lazysite/connectors/calls.jsonl that would not decode, so it was left out of
# what was kept, and the rewrite that expires old calls deleted it - healing the
# file by erasing the damage and a row of the record with it. Now the sweep
# reports the fault, naming the store, the line and `lazysite check`, and leaves
# the file byte-identical; once the line is repaired, it sweeps as before.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);
use Lazysite::Manager::Connectors ();

sub spit  { my ( $p, $t ) = @_; open my $fh, '>:raw', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return undef; local $/; my $t = <$fh>; close $fh; return $t }

my $d = site_tempdir();
make_path("$d/lazysite/connectors");
my $rec = "$d/lazysite/connectors/calls.jsonl";
my $old = '{"at":' . ( time - 40 * 86400 ) . ',"connector":"crm","state":"answered"}' . "\n";
my $new = '{"at":' . time . ',"connector":"crm","state":"unanswered"}' . "\n";

subtest 'absent: nothing to sweep' => sub {
    my $s = Lazysite::Manager::Connectors::sweep($d);
    ok( $s->{ok}, 'ok' );
    is( $s->{kept}, 0, 'nothing kept' );
};

subtest 'a line that is not a record: the sweep refuses and rewrites nothing' => sub {
    my $damaged = $old . "{\"at\": 17\n" . $new;
    spit( $rec, $damaged );
    my $err = '';
    my $s;
    {
        local *STDERR;
        open STDERR, '>', \$err or die $!;
        $s = Lazysite::Manager::Connectors::sweep($d);
        close STDERR;
    }
    ok( !$s->{ok}, 'the sweep reports a fault' );
    like( $s->{error}, qr/lazysite\/connectors\/calls\.jsonl holds a line that is not a call record \(line 2\)/,
        'naming the store and the line' );
    like( $s->{error}, qr/Nothing was swept.*`lazysite check --docroot <docroot>` names the fault/,
        'and the check' );
    is( slurp($rec), $damaged, 'the record is byte-identical - the old call was not expired either' );
    like( $err, qr/cannot tell - lazysite\/connectors\/calls\.jsonl/, 'the log names it' );
};

subtest 'once repaired, the sweep expires the old call' => sub {
    spit( $rec, $old . $new );
    my $s = Lazysite::Manager::Connectors::sweep($d);
    ok( $s->{ok}, 'swept' );
    is( $s->{expired},    1, 'the old call expired' );
    is( $s->{unanswered}, 1, 'the unanswered one counted' );
    is( slurp($rec), $new, 'and only the new one is kept' );
};

done_testing();
