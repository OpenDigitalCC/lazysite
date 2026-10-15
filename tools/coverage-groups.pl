#!/usr/bin/perl
# tools/coverage-groups.pl - coverage in parts (SM1083, "Coverage in parts").
#
#   perl tools/coverage-groups.pl --list            GROUP<TAB>PREFIX...
#   perl tools/coverage-groups.pl --files GROUP     the GATED files of the group that exist
#   perl tools/coverage-groups.pl --tests GROUP     the .t files the area map selects for it
#   perl tools/coverage-groups.pl --floor GROUP     the group's floor lines, flat, as coverage.sh reads them
#   perl tools/coverage-groups.pl --digest GROUP    "DIGEST GROUP" (or `all`: one digest over every group's)
#   perl tools/coverage-groups.pl --state [STORE]   GROUP<TAB>DIGEST<TAB>pass|stale|nothing-gated<TAB>note
#
# THE RULING (release manager, 2026-10-15): "maybe it can be broken down into
# smaller parts, as i am sure it all isnt needed for every change." A full
# instrumented suite is five hours on this host. The measured files fall into a
# few areas, each exercised by the tests tools/precheck-areas.pl already names
# for it, so each area is measured on its own, from its own inputs digest, into
# its own cover DB, and keeps its own recorded pass under
# tmp/release-gate/coverage-passes/GROUP/DIGEST.json. A run measures only the
# groups whose digest has no recorded pass; the gate needs every group matched.
#
# WHAT A GROUP'S DIGEST COVERS: every code file under the group's prefixes, the
# tests the area map selects for those prefixes, the group's floor lines, and
# the coverage scripts themselves. It does NOT cover the shared modules another
# group owns (lib/Lazysite/*.pm is the `lib` group): a change there re-stales
# `lib`, not every group that calls it. That is the trade the ruling asks for,
# and it is written here so nobody reads a reused pass as more than it is.
#
# THE GROUPS ARE THE AREA MAP'S ROWS, gathered: a prefix belongs to the group
# that names it; `lib` and `tools` take the files no longer prefix claims.
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use File::Find  qw(find);

my $ROOT = $0 =~ m{^(.*)/tools/[^/]+$} ? $1 : '.';

# Group => prefixes (every prefix is a row of the area map; t/lint checks that).
our @GROUPS = (
    [ processor => qw(lazysite-processor.pl lazysite-processor/) ],
    [ manager => qw(lazysite-manager-api.pl lib/Lazysite/Manager/ lib/Lazysite/ControlApi/) ],
    [ auth => qw(lazysite-auth.pl lib/Lazysite/Auth/ lazysite-oauth.pl tools/lazysite-users.pl) ],
    [ data   => qw(lazysite-data.pl lib/Lazysite/Data/) ],
    [ front  => qw(lazysite-dav.pl lazysite-mcp.pl lazysite-front.pl) ],
    [ daemon => qw(lib/Lazysite/Daemon/) ],
    [ odoo => qw(lib/Lazysite/Odoo/ lib/Lazysite/Odoo.pm lazysite-odoo.pl lib/Lazysite/Plugins/ plugins/) ],
    [ lib   => qw(lib/Lazysite/) ],
    [ tools => qw(tools/ tools/lazysite-bundle-apply.pl) ],
);

# The files coverage.sh gates (its list, and the parts P19 added), as patterns.
my @GATED = (
    qr{^lazysite-(?:dav|processor|manager-api|auth|mcp|oauth)\.pl$},
    qr{^tools/lazysite-(?:users|bundle-apply)\.pl$},
    qr{^lazysite-processor/[^/]+\.pm$},
    qr{^lib/Lazysite/Manager/[^/]+\.pm$},
);

my $FLOOR_GROUPS = "$ROOT/dist/config/coverage-floor-groups";
my $FLOOR        = "$ROOT/dist/config/coverage-floor";

sub group_row {
    my ($name) = @_;
    my ($g)    = grep { $_->[0] eq $name } @GROUPS;
    die "coverage-groups: no group '$name' (see --list)\n" unless $g;
    return $g;
}

# Every prefix of every OTHER group that is longer than $prefix and starts with
# it: files under those belong elsewhere.
sub claimed_elsewhere {
    my ( $name, $prefix ) = @_;
    return grep { length $_ > length $prefix && index( $_, $prefix ) == 0 }
        map { @{$_}[ 1 .. $#$_ ] } grep { $_->[0] ne $name } @GROUPS;
}

sub code_files {
    my ($name) = @_;
    my $g = group_row($name);
    my %f;
    for my $p ( @{$g}[ 1 .. $#$g ] ) {
        my @other = claimed_elsewhere( $name, $p );
        if ( $p =~ m{/$} ) {
            next unless -d "$ROOT/$p";
            find(
                {
                    no_chdir => 1,
                    wanted   => sub {
                        return unless -f $_ && /\.(?:pl|pm)$/;
                        my $rel = $_ =~ s{^\Q$ROOT\E/}{}r;
                        return if grep { index( $rel, $_ ) == 0 } @other;
                        $f{$rel} = 1;
                    },
                },
                "$ROOT/$p"
            );
        }
        elsif ( -f "$ROOT/$p" ) { $f{$p} = 1 }
    }
    my @files = sort keys %f;
    return @files;
}

sub gated_files {
    my ($name) = @_;
    return grep { my $f = $_; grep { $f =~ $_ } @GATED } code_files($name);
}

sub tests_for {
    my ($name) = @_;
    my $g = group_row($name);
    require "$ROOT/tools/precheck-areas.pl";    ## no critic (RequireBarewordIncludes)
    my %t;
    for my $row ( main::rows() ) {
        next unless grep { $_ eq $row->[0] } @{$g}[ 1 .. $#$g ];
        $t{$_} = 1 for map { main::select_tests($_) } @{$row}[ 1 .. $#$row ];
    }
    my @tests = sort keys %t;
    return @tests;
}

sub slurp { open my $fh, '<:raw', $_[0] or return ''; local $/; my $t = <$fh>; close $fh; return $t }

# The group's floor lines, flat. General `floor=`/`branch_floor=` come from
# coverage-floor unless the group's section sets its own; `status=` and the
# per-file lines come from the section.
sub floor_lines {
    my ($name) = @_;
    my ( %gen, @sect, $in );
    for ( split /\n/, slurp($FLOOR) ) {
        $gen{$1} = $_ if /^(floor|branch_floor)=\d+/;
    }
    for ( split /\n/, slurp($FLOOR_GROUPS) ) {
        if (/^\[(\S+)\]\s*$/) { $in = $1 eq $name; next }
        next unless $in && /^\S/ && !/^#/;
        if (/^(floor|branch_floor)=\d+/) { $gen{$1} = $_; next }
        push @sect, $_;
    }
    return ( ( map { $gen{$_} } grep { $gen{$_} } qw(floor branch_floor) ), @sect );
}

sub digest {
    my ($name) = @_;
    if ( $name eq 'all' ) {
        return sha256_hex( join "\n", map { digest( $_->[0] ) . " $_->[0]" } @GROUPS );
    }
    my @parts;
    for my $f ( code_files($name), tests_for($name) ) {
        push @parts, "$f\0" . slurp("$ROOT/$f") . "\0";
    }
    push @parts, "floor\0" . join( "\n", floor_lines($name) ) . "\0";
    for my $s (qw(tools/coverage.sh tools/coverage-groups.pl tools/coverage-parts.sh)) {
        push @parts, "$s\0" . slurp("$ROOT/$s") . "\0" if -f "$ROOT/$s";
    }
    return sha256_hex( join '', @parts );
}

sub recorded_pass {
    my ( $store, $name, $d ) = @_;
    my $t = slurp("$store/$name/$d.json") or return;
    return unless $t =~ /"result"\s*:\s*"pass"/;
    return $t =~ /"captured"\s*:\s*"([^"]*)"/ ? $1 : 'recorded';
}

sub group_state {
    my ($store) = @_;
    my @out;
    for my $g (@GROUPS) {
        my $name = $g->[0];
        my $d    = digest($name);
        my @gf   = gated_files($name);
        if ( !@gf ) { push @out, [ $name, $d, 'nothing-gated', 'no file of this group is floor-checked' ]; next }
        my $when = recorded_pass( $store, $name, $d );
        push @out, [ $name, $d, $when ? 'pass' : 'stale', $when ? "captured $when" : scalar(@gf) . ' gated file(s) to measure' ];
    }
    return @out;
}

sub run {
    my ( $cmd, $arg ) = @_;
    $cmd //= '';
    if ( $cmd eq '--list' ) { print join( "\t", @$_ ), "\n" for @GROUPS; return 0 }
    if ( $cmd eq '--files' ) { print "$_\n" for gated_files( $arg // die "--files GROUP\n" ); return 0 }
    if ( $cmd eq '--tests' ) { print "$_\n" for tests_for( $arg // die "--tests GROUP\n" ); return 0 }
    if ( $cmd eq '--floor' ) { print "$_\n" for floor_lines( $arg // die "--floor GROUP\n" ); return 0 }
    if ( $cmd eq '--digest' ) { $arg // die "--digest GROUP|all\n"; print digest($arg), " $arg\n"; return 0 }
    if ( $cmd eq '--state' ) {
        my $store = $arg // $ENV{LAZYSITE_COVER_STORE} // "$ROOT/tmp/release-gate/coverage-passes";
        print join( "\t", @$_ ), "\n" for group_state($store);
        return 0;
    }
    print STDERR "usage: coverage-groups.pl --list | --files G | --tests G | --floor G | --digest G|all | --state [STORE]\n";
    return 2;
}

exit run(@ARGV) unless caller;
1;
