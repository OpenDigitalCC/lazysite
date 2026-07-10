#!/usr/bin/perl
# 2026-07-10 review D2: shellcheck was declared tooling but had no gate - run
# by hand only. Every tracked shell script must pass at -S error (the same
# bar the review ran). Skips cleanly where shellcheck is not installed; the
# release path asserts the tool exists separately (tools/release.sh), so a
# release host cannot skip this silently.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

plan skip_all => 'shellcheck not installed (release hosts assert it)'
    if system('shellcheck --version >/dev/null 2>&1') != 0;

my @scripts = grep { length } split /\n/,
    qx(git -C \Q$root\E ls-files -- '*.sh');
ok( @scripts >= 5, 'found the tracked shell scripts (' . @scripts . ')' );

for my $s (@scripts) {
    my $out = qx(shellcheck -S error \Q$root\E/\Q$s\E 2>&1);
    is( $? >> 8, 0, "$s clean at shellcheck -S error" ) or diag($out);
}

done_testing();
