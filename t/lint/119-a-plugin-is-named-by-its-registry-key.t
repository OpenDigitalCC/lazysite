#!/usr/bin/perl
# SM759: a plugin's enabled state is keyed by its REGISTRY KEY - `plugins/<name>.pl`
# - because that is what the Plugin Manager writes into lazysite.conf and what
# _enabled_map() reads back. A reader that asks plugin_enabled('daemon.pl') is
# asking about a word the conf never holds, and gets "disabled" forever.
#
# The runtime shipped that way through two edge releases; every fixture had
# written `- daemon.pl` by hand, so the reader and the fixture agreed and the
# writer was never consulted. This holds both halves:
#   - every literal handed to plugin_enabled(), and the two registries that
#     carry a plugin name (Supervisor's $PLUGIN, StartPage's plugin =>), is a
#     registry key;
#   - no test fixture lists a bare plugin name where a conf entry goes.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Find;

my $root = "$FindBin::Bin/../..";
sub slurp { my $f = shift; open my $i, '<', $f or die "$f: $!"; local $/; my $s = <$i>; close $i; $s }

opendir my $pd, "$root/plugins" or die $!;
my @names = grep { /\.pl\z/ } readdir $pd;
closedir $pd;
ok( @names >= 10, 'plugins/ enumerated' );
my $bare = join '|', map { quotemeta } @names;

my @src;
find( { wanted => sub { push @src, $File::Find::name if /\.(pm|pl)\z/ && -f }, no_chdir => 1 },
    "$root/lib", "$root/tools", "$root/plugins" );
push @src, glob("$root/lazysite-*.pl");

my @bad;
for my $f ( sort @src ) {
    my $s   = slurp($f);
    my $rel = $f =~ s{^\Q$root\E/}{}r;
    while ( $s =~ /plugin_enabled\(\s*(['"])([^'"]+)\1/g ) {
        push @bad, "$rel: plugin_enabled('$2')" unless $2 =~ m{^plugins/};
    }
    while ( $s =~ /^\s*our\s+\$PLUGIN\s*=\s*(['"])([^'"]+)\1/mg ) {
        push @bad, "$rel: \$PLUGIN = '$2'" unless $2 =~ m{^plugins/};
    }
    while ( $s =~ /\bplugin\s*=>\s*(['"])([^'"]+)\1/g ) {
        push @bad, "$rel: plugin => '$2'" if $2 =~ /^(?:$bare)$/;
    }
}
is_deeply( \@bad, [], 'every enabled-check names a plugin by its registry key' )
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
is_deeply( \@fix, [], 'no test writes a bare plugin name where a conf entry goes' )
    or diag join "\n", @fix;

done_testing;
