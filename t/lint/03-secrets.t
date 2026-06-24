#!/usr/bin/perl
# WP-7 (D5 security): a lightweight, committed secrets gate over tracked
# source - catches hardcoded private keys, cloud access-key ids, and assigned
# credential literals. A floor, not a substitute for gitleaks (install that
# for a thorough scan); this runs anywhere with just git.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

# Contexts where credential-shaped strings are legitimate: tests (fixtures),
# *.example config, docs that show the format, the changelog.
my @exclude = (
    ':(exclude)t/*', ':(exclude)*.example*', ':(exclude)docs/*',
    ':(exclude)CHANGELOG.md',
);

my %checks = (
    'hardcoded private key' => '-----BEGIN [A-Z ]*PRIVATE KEY',
    'cloud access key id'   => 'AKIA[0-9A-Z]{16}',
    'assigned secret literal'
        => '(password|passwd|secret|api[_-]?key|token)[[:space:]]*([:=]|=>)[[:space:]]*["\'][A-Za-z0-9+/=_-]{12,}["\']',
);

for my $name ( sort keys %checks ) {
    my @args = ( 'git', '-C', $root, 'grep', '-nIE', $checks{$name}, '--', '.', @exclude );
    open my $p, '-|', @args or do { fail("cannot run git grep for $name"); next };
    my $out = do { local $/; <$p> } // '';
    close $p;
    is( $out, '', "no $name in tracked source" ) or diag($out);
}

done_testing();
