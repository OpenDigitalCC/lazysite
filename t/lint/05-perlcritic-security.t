#!/usr/bin/perl
# Eight-dimension review D6 (security): run the security-themed Perl::Critic
# policies over the production set at severity 1 (the broadest), independent of
# the curated profile's exclusions. Green at introduction; the gate exists so a
# future security-flagged construct refuses the build rather than landing
# silently. Skips cleanly where perlcritic is not installed (host dev tool).
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
chomp( my $critic = `which perlcritic 2>/dev/null` );
plan skip_all => 'perlcritic not installed' unless $critic;

my @scripts = sort glob("$root/*.pl $root/tools/*.pl $root/plugins/*.pl $root/lib/Lazysite/*.pm $root/lib/Lazysite/*/*.pm");
ok( scalar @scripts, 'found production scripts to lint' );

my $list = join ' ', map { "'$_'" } @scripts;
my $out = `cd '$root' && perlcritic --theme security --severity 1 --quiet $list 2>&1`;
is( $out, '', 'no security-themed perlcritic violations at severity 1' )
    or diag("security violations:\n$out");

done_testing();
