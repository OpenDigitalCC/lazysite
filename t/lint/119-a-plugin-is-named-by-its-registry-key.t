#!/usr/bin/perl
# SM759: an extension's enabled state is keyed by its REGISTRY KEY - `extensions/<name>.pl`
# - because that is what the Extension Manager writes into lazysite.conf and what
# _enabled_map() reads back. A reader that asks extension_enabled('daemon.pl') is
# asking about a word the conf never holds, and gets "disabled" forever.
#
# The runtime shipped that way through two edge releases; every fixture had
# written `- daemon.pl` by hand, so the reader and the fixture agreed and the
# writer was never consulted. This holds both halves:
#   - every literal handed to extension_enabled(), and the two registries that
#     carry an extension name (Supervisor's $EXTENSION, StartPage's extension =>), is a
#     registry key;
#   - no test fixture lists a bare extension name where a conf entry goes.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Find;

my $root = "$FindBin::Bin/../..";
sub slurp { my $f = shift; open my $i, '<', $f or die "$f: $!"; local $/; my $s = <$i>; close $i; $s }

opendir my $pd, "$root/extensions" or die $!;
my @names = grep { /\.pl\z/ } readdir $pd;
closedir $pd;
ok( @names >= 10, 'extensions/ enumerated' );
my $bare = join '|', map { quotemeta } @names;

my @src;
find( { wanted => sub { push @src, $File::Find::name if /\.(pm|pl)\z/ && -f }, no_chdir => 1 },
    "$root/lib", "$root/tools", "$root/extensions" );
push @src, glob("$root/lazysite-*.pl"), glob("$root/lazysite-processor/*.pm");

my @bad;
for my $f ( sort @src ) {
    my $s   = slurp($f);
    my $rel = $f =~ s{^\Q$root\E/}{}r;
    while ( $s =~ /extension_enabled\(\s*(['"])([^'"]+)\1/g ) {
        push @bad, "$rel: extension_enabled('$2')" unless $2 =~ m{^extensions/};
    }
    while ( $s =~ /^\s*our\s+\$EXTENSION\s*=\s*(['"])([^'"]+)\1/mg ) {
        push @bad, "$rel: \$EXTENSION = '$2'" unless $2 =~ m{^extensions/};
    }
    while ( $s =~ /\bextension\s*=>\s*(['"])([^'"]+)\1/g ) {
        push @bad, "$rel: extension => '$2'" if $2 =~ /^(?:$bare)$/;
    }
}
is_deeply( \@bad, [], 'every enabled-check names an extension by its registry key' )
    or diag join "\n", @bad;

# Fixtures: a conf entry written as `- daemon.pl` (in a heredoc or a string)
# or a bare name handed to a fixture helper is the shape that hid this.
# Comment lines are skipped; a line that MEANS the bare name (a negative
# case, a map the processor tolerates by design) says so with the marker
# `bare-name-on-purpose`.
my @tests;
find( { wanted => sub { push @tests, $File::Find::name if /\.t\z/ && -f }, no_chdir => 1 }, "$root/t" );
my @fix;
for my $f ( sort @tests ) {
    next if $f =~ /t\/lint\/119-/;
    my $s   = join "\n", grep { !/^\s*#/ && !/bare-name-on-purpose/ } split /\n/, slurp($f);
    my $rel = $f =~ s{^\Q$root\E/}{}r;
    my $n   = 0;
    while ( $s =~ /(?:^|\\n)\s*-\s+(?:$bare)\s*(?:\\n|$)/mg ) { $n++ }
    while ( $s =~ /(?<![\w\/\$.-])(['"])(?:$bare)\1/g )        { $n++ }
    push @fix, "$rel ($n)" if $n;
}
is_deeply( \@fix, [], 'no test writes a bare extension name where a conf entry goes' )
    or diag join "\n", @fix;

done_testing;
