#!/usr/bin/perl
# SM767: THE INSTALLER LOADS NO LIB. install.pl runs from an unpacked tarball
# with no lib in @INC; a `require Lazysite::...` in it dies on the host and
# passes in the suite, because `prove -l` lends every child PERL5LIB=lib.
# The 0.13.5 deploy died that way, after SM753 pointed read_retention at
# Lazysite::Util. The rule was already in the file's own comments ("the
# installer must not load the lib - keep the two in sync"); this holds it,
# and holds the two copies of the retention reader together.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";

my $root = "$FindBin::Bin/../..";
open my $fh, '<', "$root/install.pl" or die $!;
my @lines = <$fh>;
close $fh;

my @loads;
for my $i ( 0 .. $#lines ) {
    my $l = $lines[$i];
    next if $l =~ /^\s*#/;
    push @loads, ( $i + 1 ) . ": $l" =~ s/\s+$//r if $l =~ /^\s*(?:use|require)\s+Lazysite::/;
}
is_deeply( \@loads, [], 'install.pl neither uses nor requires a Lazysite:: module' )
    or diag join "\n", @loads;

# the retention reader's default is the engine's default
require Lazysite::Util;
my $src = join '', @lines;
my ($inst_default) = $src =~ /sub read_retention \{.*?my \$default\s*=\s*(\d+);/s;
is( $inst_default, $Lazysite::Util::BACKUP_RETENTION_DEFAULT,
    "install.pl's retention default ($inst_default) is Lazysite::Util's ($Lazysite::Util::BACKUP_RETENTION_DEFAULT)" );

done_testing;
