#!/usr/bin/perl
# WORK-PLAN-0153 Q14a: a static work counter in the bench baseline equals the code.
#
# tools/bench.pl gates on WORK counters - counts about the code, not the host.
# work_users_tool_statements (SM685) is the size of the script compiled on every
# credential check. SM962/SM963 grew it by 19 statements on purpose, and nothing
# noticed until the release gate refused main after landing: the count could only
# move at a cut, so every deliberate growth would have failed every gate until the
# next one. A count read from the source alone is now held here instead, at branch
# time: change the code, update the count in the same commit, and say why.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $raw  = qx($^X \Q$root/tools/bench.pl\E --work 2>/dev/null);
my $now  = eval { decode_json($raw) };
ok( ref $now eq 'HASH' && %$now, 'bench.pl --work reports the static counters' ) or diag($raw);

my $base = do {
    open my $fh, '<', "$root/dist/config/bench-baseline.json" or die $!;
    local $/;
    decode_json(<$fh>);
};
for my $k ( sort keys %{ $now || {} } ) {
    is( $base->{ops}{$k}, $now->{$k}, "$k matches the code" )
        or diag( "The code now counts $now->{$k}. If the change is intended, set "
            . "ops.$k to $now->{$k} in dist/config/bench-baseline.json in this commit "
            . 'and say why in the commit message; if not, the code grew by accident.' );
}

done_testing();
