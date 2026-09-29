#!/usr/bin/perl
# The set of columns the data extension OWNS is spelt in exactly one place.
#
# It used to be spelt in fourteen, across seven modules - as two %RESERVED
# hashes, a qw() list of columns to create, a list of column definitions, a CSV
# header list, and nine copies of the alternation
# /\A(?:created_at|updated_at|created_by|updated_by)\z/. Nothing had gone wrong,
# and that is the reason for a lint rather than a note: the set is about to grow
# (SM857's policy column), and a set spelt in fourteen places grows by being
# spelt in fourteen more. A column added to thirteen of them would be created by
# the migration and refused from writers, and then reported by the fourteenth -
# the drift check - as an undeclared extra to remove.
#
# WHAT THIS LOOKS FOR, and why it is a pair of names rather than one: a single
# `created_at` is a legitimate thing to write (Tables::_stamp assigns it), so the
# rule is that no file may name TWO of the owned columns near each other. That
# is what a spelling of the SET looks like, and it is what a copy would be.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $HOME = 'lib/Lazysite/Data/Owned.pm';

# Every Perl file the engine ships, which is where a copy would appear.
my @files;
for my $dir ( 'lib', 'plugins', 'tools' ) {
    next unless -d "$root/$dir";
    open my $fh, '-|', 'find', "$root/$dir", '-type', 'f', '-name', '*.p[lm]' or die $!;
    while ( my $l = <$fh> ) { chomp $l; push @files, $l }
    close $fh;
}
open my $top, '-|', 'find', $root, '-maxdepth', '1', '-type', 'f', '-name', '*.pl' or die $!;
while ( my $l = <$top> ) { chomp $l; push @files, $l }
close $top;
cmp_ok( scalar @files, '>=', 40, 'the engine\'s Perl files were found' );

my @owned = qw(created_at updated_at created_by updated_by);

my @copies;
for my $f ( sort @files ) {
    ( my $rel = $f ) =~ s{\A\Q$root\E/}{};
    next if $rel eq $HOME;
    open my $fh, '<', $f or die "$f: $!";
    my $n = 0;
    while ( my $line = <$fh> ) {
        $n++;
        next if $line =~ /\A\s*#/;    # a comment may explain the set
        my @hit = grep { index( $line, $_ ) >= 0 } @owned;
        push @copies, "$rel:$n (@hit)" if @hit >= 2;
    }
    close $fh;
}

is_deeply( \@copies, [],
    "the owned-column set is named only in $HOME" )
    or diag( "a second spelling of the set:\n  " . join( "\n  ", @copies )
        . "\nAsk Data::Owned instead: stamp_columns() for the list, "
        . 'owned_columns($d) for the ones this table has, is_owned($d,$col) for '
        . 'one column, reserved_column($col) for the unconditional question.' );

# AND THE HOME ACTUALLY ANSWERS, so this cannot pass by the module being empty.
{
    require_ok('Lazysite::Data::Owned');
    my @stamps = Lazysite::Data::Owned::stamp_columns();
    is_deeply( [@stamps], [@owned], 'the module names the four stamp columns, in creation order' );
    ok( Lazysite::Data::Owned::reserved_column('created_by'),
        'reserved is unconditional - no descriptor may declare one' );
    ok( !Lazysite::Data::Owned::reserved_column('title'), 'and an ordinary name is not reserved' );
    ok( Lazysite::Data::Owned::is_owned( { timestamps => 1 }, 'created_by' ),
        'owned is per-table: a stamped table has it' );
    ok( !Lazysite::Data::Owned::is_owned( { timestamps => 0 }, 'created_by' ),
        'and a table without the flag does NOT - which is why the two questions '
            . 'are separate subs' );
}

done_testing();
