#!/usr/bin/perl
# SM366: a tool that loads a Lazysite module must be able to find it.
#
# FOUND IN A DEPLOY LOG, which is the only place it could be found. The 0.10.13
# rollout to edge printed:
#
#   Can't locate Lazysite/Paths.pm in @INC ... tools/lazysite-check.pl line 171
#   (some checks could not be auto-repaired - see above)
#
# and the second line is the part that matters: a script that could not START
# was reported as checks that could not be REPAIRED. An operator reading that
# concludes their site has unfixable problems. It has none; the health tool
# never ran.
#
# WHY IT SURVIVED. lazysite-users.pl has carried a BEGIN bootstrap since it was
# written - locate lib/ relative to the script, fall back to the system @INC for
# package installs. Six other tools load Lazysite modules and never got one, so
# they work when something else has already put lib/ on @INC (running from the
# repo, a wrapper that exports PERL5LIB) and die when nothing has. That is every
# tarball and Hestia install, which is how the fleet runs - and it fails
# INCONSISTENTLY, because the deploy script sets things up for some invocations
# and not others. In the same log, lazysite-acl.pl ran fine minutes later.
#
# So this asserts the property rather than the six files: anything under tools/
# that loads a Lazysite module carries the bootstrap.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
opendir my $dh, "$root/tools" or die "tools/: $!";
my @tools = sort grep { /\.pl$/ } readdir $dh;
closedir $dh;
cmp_ok( scalar @tools, '>=', 15, 'found the tools to check' );

my @unbootstrapped;
for my $t (@tools) {
    open my $fh, '<', "$root/tools/$t" or die "$t: $!";
    local $/;
    my $src = <$fh>;
    close $fh;

    # Does it load a Lazysite module at all? A tool that does not needs nothing.
    next unless $src =~ /^\s*(?:use|require)\s+Lazysite::/m;

    push @unbootstrapped, $t unless $src =~ /unshift \@INC/;
}

is_deeply( \@unbootstrapped, [],
    'every tool that loads a Lazysite module can locate it' )
    or diag( "Without a bootstrap: @unbootstrapped\n"
        . 'These run from the repo and die on a tarball or Hestia install. '
        . 'Copy the BEGIN block from tools/lazysite-users.pl.' );

# And the bootstrap has to run BEFORE the load it exists for, which a plain
# "is the string present" check cannot see.
for my $t (@tools) {
    open my $fh, '<', "$root/tools/$t" or die "$t: $!";
    local $/;
    my $src = <$fh>;
    close $fh;
    next unless $src =~ /unshift \@INC/;
    my $boot = index( $src, 'unshift @INC' );
    my ($first_load) = $src =~ /^(\s*(?:use|require)\s+Lazysite::)/m;
    next unless defined $first_load;
    my $load = index( $src, $first_load );
    cmp_ok( $boot, '<', $load, "$t: the bootstrap runs before the load" );
}

done_testing();
