#!/usr/bin/env perl
# SM1083 coverage in parts: each group has its OWN inputs digest - its code
# files, the tests the area map selects for its prefixes, its floor lines. A
# change in one group's file moves that group's digest and no other's; `all`
# moves with any. A stub tree, nothing instrumented.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_cmd);

my $root = repo_root();
my $d    = tempdir( CLEANUP => 1 );

sub spit {
    my ( $p, $t ) = @_;
    ( my $dir = $p ) =~ s{/[^/]+$}{};
    make_path($dir);
    open my $f, '>', $p or die "$p: $!";
    print {$f} $t;
    close $f;
}
make_path("$d/tools");
copy( "$root/tools/$_", "$d/tools/$_" ) or die "$_: $!" for qw(coverage-groups.pl precheck-areas.pl);
spit( "$d/lazysite-processor.pl",      "print 1;\n" );
spit( "$d/lazysite-auth.pl",           "print 2;\n" );
spit( "$d/t/unit/processor/01-a.t",    "ok 1;\n" );
spit( "$d/t/unit/auth/01-b.t",         "ok 1;\n" );
spit( "$d/dist/config/coverage-floor", "floor=75\nbranch_floor=62\n" );
spit( "$d/dist/config/coverage-floor-groups", "[processor]\nstatus=pre-rebaseline\n[auth]\nbranch_floor[lazysite-auth.pl]=60\n" );

sub groups {
    my $o = $_[0] eq '--rows-of-the-map' ? run_cmd( $^X, "$d/tools/precheck-areas.pl", '--rows' ) : run_cmd( $^X, "$d/tools/coverage-groups.pl", @_ );
    chomp $o;
    $o;
}

my @list = split /\n/, groups('--list');
is( scalar @list, 9, 'nine groups' );
like( $list[0], qr/^processor\tlazysite-processor\.pl\tlazysite-processor\//, 'a group is a name and its prefixes' );

is( groups( '--files', 'processor' ), 'lazysite-processor.pl', 'the processor group gates its CGI' );

# Every prefix a group names is a row of the area map, and every row is in
# exactly one group: the groups ARE the map, gathered.
my %rows = map { ( split /\t/ )[0] => 1 } split /\n/, groups('--rows-of-the-map');
my %in_group;
for my $l (@list) {
    my ( $name, @prefixes ) = split /\t/, $l;
    $in_group{$_}++ for @prefixes;
}
is_deeply( [ grep { !$rows{$_} } sort keys %in_group ], [], 'every prefix a group names is a row of the area map' );
is_deeply( [ grep { !$in_group{$_} } sort keys %rows ], [], 'and every row of the map is in a group' );
is_deeply( [ grep { $in_group{$_} > 1 } sort keys %in_group ], [], 'none in two' );
is( groups( '--tests', 'processor' ), 't/unit/processor/01-a.t', 'and runs the tests the area map names for it' );
is( groups( '--tests', 'auth' ), 't/unit/auth/01-b.t', 'auth runs its own' );
is( groups( '--floor', 'auth' ), "floor=75\nbranch_floor=62\nbranch_floor[lazysite-auth.pl]=60",
    'a group\'s floor is the general floor plus its own lines' );
like( groups( '--floor', 'processor' ), qr/^status=pre-rebaseline$/m, 'the status line is carried' );

my ( $p1, $a1, $all1 ) = map { ( groups( '--digest', $_ ) =~ /^([0-9a-f]{64}) \Q$_\E$/ )[0] } qw(processor auth all);
ok( $p1 && $a1 && $all1, 'each digest is 64 hex and names its group' );
isnt( $p1, $a1, 'two groups differ' );

spit( "$d/lazysite-processor.pl", "print 3;\n" );
my ( $p2, $a2, $all2 ) = map { ( groups( '--digest', $_ ) =~ /^([0-9a-f]{64})/ )[0] } qw(processor auth all);
isnt( $p2, $p1, 'a changed processor file moves the processor digest' );
is( $a2, $a1, 'and not the auth digest' );
isnt( $all2, $all1, 'all moves with any group' );

spit( "$d/t/unit/auth/01-b.t", "ok 2;\n" );
my $a3 = ( groups( '--digest', 'auth' ) =~ /^([0-9a-f]{64})/ )[0];
isnt( $a3, $a2, 'a changed test moves the group it is selected for' );
is( ( groups( '--digest', 'processor' ) =~ /^([0-9a-f]{64})/ )[0], $p2, 'and no other' );

spit( "$d/dist/config/coverage-floor-groups", "[processor]\nstatus=pre-rebaseline\n[auth]\nbranch_floor[lazysite-auth.pl]=61\n" );
isnt( ( groups( '--digest', 'auth' ) =~ /^([0-9a-f]{64})/ )[0], $a3, 'a changed floor line moves its group' );
is( ( groups( '--digest', 'processor' ) =~ /^([0-9a-f]{64})/ )[0], $p2, 'and no other' );

like( groups( '--state', "$d/store" ), qr/^processor\t[0-9a-f]{64}\tstale\t1 gated file\(s\)/m, 'with no record a gated group is stale' );
like( groups( '--state', "$d/store" ), qr/^data\t[0-9a-f]{64}\tnothing-gated\t/m, 'a group with no gated file says so' );
done_testing;
