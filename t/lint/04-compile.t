#!/usr/bin/perl
# Eight-dimension review D1 (correctness): the framework's mechanical gate for
# this dimension is `perl -c` - a hallucinated import or symbol in a rarely
# exercised script must refuse the build, not wait for whichever test happens
# to load it. Sweeps the same production set as the perlcritic gate.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my @scripts = sort glob("$root/*.pl $root/tools/*.pl $root/plugins/*.pl $root/lib/Lazysite/*.pm $root/lib/Lazysite/*/*.pm");
ok( scalar @scripts, 'found production scripts to compile' );

for my $s (@scripts) {
    my $out = `$^X -I'$root/lib' -c '$s' 2>&1`;
    my $rc  = $? >> 8;
    ( my $rel = $s ) =~ s{^\Q$root\E/}{};
    is( $rc, 0, "perl -c: $rel" ) or diag($out);
}

done_testing();
