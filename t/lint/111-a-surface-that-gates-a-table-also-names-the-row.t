#!/usr/bin/perl
# SM857: a surface that asks WHICH TABLE also asks WHOSE ROW.
#
# Two questions, both answered from the same capability set, and they are asked
# at the same two call sites:
#
#   row_write_refusal  - may this caller write this TABLE at all? (SM682: the
#                        writable_by allow-list, which binds a write_data grant)
#   row_authority      - and may it write THIS ROW? (personal rows belong to the
#                        account in created_by)
#
# SM682 round 2 is the precedent for the lint rather than a note: that rule lived
# in lazysite-data.pl alone, the control API carried the capability gate without
# it, and a write_data-only partner token wrote every table on that surface -
# measured from outside, not found by reading. The row question has exactly the
# same shape and exactly the same two surfaces, so a surface that gains one and
# not the other is the same defect again.
#
# A file that asks NEITHER is not in scope: the manager page reaches the actions
# with a cookie session already gated by manage_data, and the CLI reaches them as
# the sysop. Both are unconfined because they genuinely are, which is the reason
# the default is spelt out in Manager::Data rather than left to a reader.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

my @files;
open my $fh, '-|', 'find', $root, '-maxdepth', '1', '-type', 'f', '-name', '*.pl' or die $!;
while ( my $l = <$fh> ) { chomp $l; push @files, $l }
close $fh;
open my $lib, '-|', 'find', "$root/lib", "$root/tools", '-type', 'f', '-name', '*.p[lm]' or die $!;
while ( my $l = <$lib> ) { chomp $l; push @files, $l }
close $lib;

my ( @gates_the_table, @names_the_row, @asks_half );
for my $f ( sort @files ) {
    ( my $rel = $f ) =~ s{\A\Q$root\E/}{};
    next if $rel eq 'lib/Lazysite/Manager/Data.pm';    # where both rules live
    open my $in, '<', $f or die "$f: $!";
    my $src = do { local $/; <$in> };
    close $in;
    my $table = ( $src =~ /row_write_refusal\s*\(/ ) ? 1 : 0;
    my $row   = ( $src =~ /row_authority\s*\(/ )     ? 1 : 0;
    push @gates_the_table, $rel if $table;
    push @names_the_row,   $rel if $row;
    push @asks_half, "$rel (asks " . ( $table ? 'the table' : 'the row' ) . ' only)'
        if $table != $row;
}

cmp_ok( scalar @gates_the_table, '>=', 2,
    'the surfaces that gate a table write were found' )
    or diag( 'expected at least lazysite-data.pl and lazysite-manager-api.pl; got: '
        . join( ', ', @gates_the_table ) );

is_deeply( \@asks_half, [],
    'every surface that asks which table also asks whose row' )
    or diag( "half-asked:\n  " . join( "\n  ", @asks_half )
        . "\nPass as => Lazysite::Manager::Data::row_authority( \$caps, \$user ) to "
        . 'action_data_row_save and action_data_row_delete, beside the '
        . 'row_write_refusal call that is already there.' );

done_testing();
