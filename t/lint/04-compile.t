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
    # SM557: a clean exit is not a clean compile. `local $Pkg::VAR` on a
    # package only require'd at runtime warned "used only once: possible typo"
    # on every run of the script (twice per form POST), and the exit code
    # never said so. A deliberate single mention carries `no warnings 'once'`.
    unlike( $out, qr/used only once/, "no used-only-once warning: $rel" );
}

done_testing();
