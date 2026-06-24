#!/usr/bin/perl
# WP-1 (D1 code quality): enforce the curated Perl::Critic profile
# (.perlcriticrc) over the production scripts at severity 4. The deliberately
# disabled policies are documented in the profile and in
# docs/architecture/code-quality.md. Skips cleanly where perlcritic is not
# installed - it is a host dev tool, not a runtime dependency.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
chomp( my $critic = `which perlcritic 2>/dev/null` );
plan skip_all => 'perlcritic not installed' unless $critic;
plan skip_all => 'no profile' unless -f "$root/.perlcriticrc";

my @scripts = sort glob("$root/*.pl $root/tools/*.pl $root/plugins/*.pl");
ok( scalar @scripts, 'found production scripts to lint' );

# One invocation over all scripts; --quiet prints only violations, so clean
# means empty output.
my $list = join ' ', map { "'$_'" } @scripts;
my $out = `cd '$root' && perlcritic --profile '$root/.perlcriticrc' --quiet $list 2>&1`;
is( $out, '', 'all production scripts pass the lazysite perlcritic profile (severity 4)' )
    or diag("perlcritic violations:\n$out");

done_testing();
