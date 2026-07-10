#!/usr/bin/perl
# WP-7 (D5 security): a lightweight, committed secrets gate over tracked
# source - catches hardcoded private keys, cloud access-key ids, and assigned
# credential literals. A floor, not a substitute for gitleaks (install that
# for a thorough scan); this runs anywhere with just git.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
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

# Planted fixtures: prove each pattern CAN detect before trusting its
# silence. The private-key pattern starts with '-', which git grep parsed as
# an option - that check passed on empty output (2026-07-10 review, D1:
# invalid-test inside a lint gate). `-e` pins every pattern as a pattern.
my %plant = (
    'hardcoded private key'   => "-----BEGIN RSA PRIVATE KEY-----\n",
    'cloud access key id'     => "key = AKIAABCDEFGHIJKLMNOP\n",
    'assigned secret literal' => "my \$password = \"AbCdEf123456789012\";\n",
);
my $plant_dir = tempdir( CLEANUP => 1 );
for my $name ( sort keys %checks ) {
    ( my $fname = $name ) =~ s/\W+/-/g;
    open my $pf, '>', "$plant_dir/$fname.txt" or die $!;
    print {$pf} $plant{$name};
    close $pf;
    my $out = qx(git -C \Q$plant_dir\E grep --no-index -nIE -e \Q$checks{$name}\E -- \Q$fname.txt\E 2>&1);
    isnt( $out, '', "$name pattern detects a planted fixture (self-test)" );
}

for my $name ( sort keys %checks ) {
    my @args = ( 'git', '-C', $root, 'grep', '-nIE', '-e', $checks{$name},
        '--', '.', @exclude );
    open my $p, '-|', @args or do { fail("cannot run git grep for $name"); next };
    my $out = do { local $/; <$p> } // '';
    close $p;
    is( $out, '', "no $name in tracked source" ) or diag($out);
}

done_testing();
