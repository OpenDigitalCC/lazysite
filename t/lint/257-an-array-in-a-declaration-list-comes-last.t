#!/usr/bin/perl
# SM1063: `my ( @keep, $expired, $unanswered ) = ( (), 0, 0 );` in the connector
# sweep. A list assignment gives an array (or hash) every value left on the
# right, so the scalars after it are never assigned: both counters started
# undef and a sweep that expired nothing reported `expired: null`, and the two
# zeros went into @keep, so a sweep that did expire something wrote "00" in
# front of the first record it kept.
#
# This refuses the shape: in a `my`, `our` or `state` list with an assignment,
# no scalar may follow an array or a hash. Declare the scalars first, or the
# aggregate on its own. `local ( @ARGV, $/ ) = $file` is the slurp idiom (the
# undef $/ is the point), so `local` is not checked. Comments are skipped.
use strict;
use warnings;
use Test::More;
use File::Find;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

# The offending lists in one source text, as "line: text".
sub swallowed_scalars {
    my ($src) = @_;
    my @hits;
    while ( $src =~ /\b(?:my|our|state)\s*\(([^()]*)\)\s*=(?![=~])/g ) {
        my ( $list, $end ) = ( $1, pos $src );
        my $start    = $end - length $&;
        my ($before) = substr( $src, 0, $start ) =~ /([^\n]*)\z/;
        next if $before =~ /#/;    # a comment, or a line that quotes the shape
        my $seen_aggregate = 0;
        my $bad            = 0;
        for my $v ( split /,/, $list ) {
            $v =~ s/\A\s+|\s+\z//g;
            if    ( $v =~ /\A[\@%]/ ) { $seen_aggregate = 1 }
            elsif ( $v =~ /\A\$/ )    { $bad            = 1 if $seen_aggregate }
        }
        next unless $bad;
        my $line = 1 + ( () = substr( $src, 0, $start ) =~ /\n/g );
        ( my $text = "my ($list) =" ) =~ s/\s+/ /g;
        push @hits, "$line: $text";
    }
    return @hits;
}

# The check sees the shape it is for, and passes the shapes that are fine.
is( scalar swallowed_scalars('my ( @keep, $expired, $unanswered ) = ( (), 0, 0 );'),
    1, 'refuses an array before scalars' );
is( scalar swallowed_scalars("my ( %seen,\n    \$n ) = ();"), 1, 'refuses a hash before a scalar, across lines' );
is( scalar swallowed_scalars('our ( @a, $b ) = (1, 2);'), 1, 'refuses it under our' );
is( scalar swallowed_scalars('my ( $expired, $unanswered, @keep ) = ( 0, 0 );'), 0, 'passes scalars first' );
is( scalar swallowed_scalars('my ( $n, @a, @b ) = (0);'), 0, 'passes aggregates after the scalars' );
is( scalar swallowed_scalars('local ( @ARGV, $/ ) = $file;'), 0, 'passes the local slurp idiom' );
is( scalar swallowed_scalars('my ( @a, $b );'), 0, 'passes a declaration with no assignment' );
is( scalar swallowed_scalars('# was my ( @a, $b ) = ( (), 1 );'), 0, 'passes a comment that quotes the shape' );

my $root = repo_root();
my @files;
find(
    { no_chdir => 1,
        wanted => sub {
            return unless -f $_;
            if (m{\.(?:pm|pl|t|cgi)\z}) { push @files, $_; return }
            return if m{\.[A-Za-z0-9]+\z};
            open my $h, '<', $_ or return;
            my $first = <$h> // '';
            close $h;
            push @files, $_ if $first =~ /\A#!.*\bperl\b/;
        },
    },
    grep { -d } map { "$root/$_" } qw(lib tools plugins lazysite-processor scripts installers githooks t)
);
push @files, glob("$root/*.pl");
cmp_ok( scalar @files, '>', 100, 'the Perl sources are present' );

my @found;
for my $f ( sort @files ) {
    open my $h, '<', $f or do { fail("$f: unreadable"); next };
    my $src = do { local $/; <$h> };
    close $h;
    ( my $rel = $f ) =~ s{^\Q$root\E/}{};
    next if $rel eq 't/lint/257-an-array-in-a-declaration-list-comes-last.t'; # its own fixtures
    push @found, map { "$rel:$_" } swallowed_scalars($src);
}
is_deeply( \@found, [], 'no scalar follows an array or hash in a declaration list with an assignment' )
    or diag( "The aggregate takes every value, so these scalars are never assigned:\n  "
        . join( "\n  ", @found ) );

done_testing();
