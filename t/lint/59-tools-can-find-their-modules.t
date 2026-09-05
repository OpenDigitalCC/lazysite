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

# SM752: PLUGINS TOO, and the reason is that the property was never about
# tools.
#
# plugins/daemon.pl shipped in 0.13.0 with `require Lazysite::Daemon::Supervisor`
# and no bootstrap. The manager runs a plugin action as a SUBPROCESS, exactly as
# it runs a tool, so the require died - and a plugin action that dies prints
# nothing to stdout, so the manager reported "Action produced no output". The
# field met it in the state the release was proudest of: plugin enabled, runtime
# not started, which is the moment the Status button exists for.
#
# This test's own comment already said it "asserts the property rather than the
# six files". It asserted the property over one directory. The hazard is any
# script started as a subprocess with a bare @INC, and plugins are that.
my $root = repo_root();

my @scripts;
for my $dir (qw(tools plugins)) {
    opendir my $dh, "$root/$dir" or die "$dir/: $!";
    push @scripts, map { "$dir/$_" } sort grep { /\.pl$/ } readdir $dh;
    closedir $dh;
}
cmp_ok( scalar @scripts, '>=', 25, 'found the scripts to check' );

my @unbootstrapped;
for my $t (@scripts) {
    open my $fh, '<', "$root/$t" or die "$t: $!";
    local $/;
    my $src = <$fh>;
    close $fh;

    # Does it load a Lazysite module at all? One that does not needs nothing.
    next unless $src =~ /^\s*(?:use|require)\s+Lazysite::/m;

    push @unbootstrapped, $t unless $src =~ /unshift \@INC/;
}

is_deeply( \@unbootstrapped, [],
    'every script that loads a Lazysite module can locate it' )
    or diag( "Without a bootstrap (tools/ and plugins/): @unbootstrapped\n"
        . 'These run from the repo and die on a tarball or Hestia install. '
        . 'Copy the BEGIN block from tools/lazysite-users.pl.' );

# And the bootstrap has to run BEFORE the load it exists for, which a plain
# "is the string present" check cannot see.
#
# TEXTUAL ORDER ONLY MEANS EXECUTION ORDER FOR A COMPILE-TIME LOAD, and
# extending this test to plugins/ is what made that matter. A `use Lazysite::X`
# at the top runs when the file is compiled, so a bootstrap below it is too
# late and the position comparison is exactly right.
#
# A `require Lazysite::X` INSIDE A SUB does not run then - it runs when the sub
# is called, which may be long after a bootstrap that sits below it in the
# file. plugins/form-handler.pl is the shape: four lazy requires between lines
# 174 and 1235, and `_locate_lib` at 1256, called before any of them. It is
# correct, and the first version of this extension failed it - a lint reporting
# a working file as broken because it read position as sequence.
#
# So the ordering claim is made only where it can be true: a top-level `use`.
# Where the loads are lazy, the presence check above is what can be asserted
# statically, and the rest is the file's own business.
for my $t (@scripts) {
    open my $fh, '<', "$root/$t" or die "$t: $!";
    local $/;
    my $src = <$fh>;
    close $fh;
    next unless $src =~ /unshift \@INC/;

    my ($first_use) = $src =~ /^(\s*use\s+Lazysite::)/m;
    next unless defined $first_use;

    my $boot = index( $src, 'unshift @INC' );
    my $load = index( $src, $first_use );
    cmp_ok( $boot, '<', $load,
        "$t: the bootstrap runs before the compile-time load" );
}

done_testing();
