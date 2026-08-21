#!/usr/bin/perl
# SM447 / D11: SQLite first, and built so a second engine is an ADDITION.
#
# "Ready for other engines later" is an intention, and an intention decays
# silently. This makes it a property: every engine-specific construct lives in
# the adapter pair, so adding Postgres (DP-7) means writing one new module and
# a connector - not auditing six.
#
# THE ADAPTER PAIR IS NAMED, DELIBERATELY. SQLite.pm generates the SQL and
# reads the schema; Connect.pm owns the DSN, the driver flags and the
# journalling. Both are SQLite's and both would gain a sibling. Everything else
# - descriptors, value coercion, migration planning, export, and the service
# layer the surfaces call - must be engine-neutral, and this is what keeps
# them so.
#
# THE ONE THIS ALREADY CAUGHT: Tables.pm called $dbh->last_insert_id directly.
# It is a DBI method whose arguments differ by driver - Postgres wants a
# sequence - so it is exactly the sort of difference that surfaces only once a
# second engine exists, which is the worst time to find it. Moved behind
# last_insert_key() in the adapter.
use strict;
use warnings;
use Test::More;
use FindBin;

my $dir = "$FindBin::Bin/../../../lib/Lazysite/Data";
plan skip_all => 'data modules not present' unless -d $dir;

# The adapter pair. Adding a name here is a deliberate act and should be
# argued for in review, which is the point of the list being short.
my %ADAPTER = map { $_ => 1 } qw(SQLite.pm Connect.pm);

# Constructs that belong to ONE engine. Not a style list - each is something
# that would have to change, or would silently mean something else, on another
# engine.
my @ENGINE = (
    [ qr/\bPRAGMA\b/i,          'a PRAGMA statement' ],
    [ qr/dbi:[A-Za-z]+:/,       'a DSN naming a driver' ],
    [ qr/\blast_insert_id\b/,   'last_insert_id (driver-dependent arguments)' ],
    [ qr/\bDBD::\w+/,           'a DBD driver class' ],
    [ qr/\bjournal_mode\b/,     'journal_mode (SQLite journalling)' ],
    [ qr/\bAUTOINCREMENT\b/i,   'AUTOINCREMENT' ],
    [ qr/\bsqlite_\w+/,         'a sqlite_* driver attribute' ],
);

my @found;
for my $file ( sort glob "$dir/*.pm" ) {
    my $base = $file =~ s{.*/}{}r;
    next if $ADAPTER{$base};
    open my $fh, '<', $file or die "$file: $!";
    my $n = 0;
    while ( my $line = <$fh> ) {
        $n++;
        # COMMENTS ARE EXEMPT, and that is not laziness: the reasoning about
        # why decimal is TEXT and not REAL, or why WAL costs what it costs,
        # belongs beside the code it explains. What must not appear is a
        # construct that RUNS.
        next if $line =~ /^\s*#/;
        ( my $code = $line ) =~ s/\s#.*\z//;
        for my $rule (@ENGINE) {
            my ( $re, $what ) = @{$rule};
            push @found, "$base:$n uses $what"
                if $code =~ $re;
        }
    }
    close $fh;
}

is_deeply( \@found, [],
    'only the adapter pair contains engine-specific code' )
    or diag( join "\n  ",
    '',
    @found,
    '',
    'Each of these would have to change for a second engine, and would do so '
        . 'from a module whose job is not to know which engine it is. Move it '
        . 'behind the adapter - that is what DP-7 costs if it is not done now.'
    );

# And the guard must be able to fire, or it is decorative.
subtest 'the guard can see a violation' => sub {
    my $sample = "my \$id = \$dbh->last_insert_id();\n";
    my $hit    = 0;
    for my $rule (@ENGINE) {
        $hit++ if $sample =~ $rule->[0];
    }
    ok( $hit, 'a real engine-specific line matches a rule' );

    my $comment = "# PRAGMA table_info is how SQLite reports a schema\n";
    ok( $comment =~ /^\s*#/, 'and a comment is recognised as a comment' );
};

done_testing();
