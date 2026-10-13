#!/usr/bin/perl
# SM1069: _acl_entry_for finds a folder rule by looking up the path's ancestors
# instead of walking every key in the store - and answers exactly as the walk
# did.
#
# The walk is kept here as the reference, verbatim from before the change, and
# both are asked the same questions over generated stores: every mode ('read',
# 'draft', 'see', none), key spellings with and without leading and trailing
# slashes, nested folders, exact and stem keys, the site-wide rule, and paths
# with a doubled slash. Where two spellings of one folder both govern, the walk
# took whichever the hash gave first; both answers are then entries of that one
# folder, which is what is compared. Seeded, and the seed is printed on failure.
use strict;
use warnings;
use Test::More;
use Cwd qw(realpath);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor setup_test_site site_tempdir);

my $docroot = realpath( site_tempdir() );
setup_test_site($docroot);
load_processor($docroot);

# The pre-SM1069 resolver, for comparison only.
sub walk {
    my ( $map, $rel, $mode ) = @_;
    $mode //= '';
    $rel =~ s{\A/+}{};
    my $governs = sub {
        my ($e) = @_;
        return 0 unless ref $e eq 'HASH';
        return 1 unless length $mode;
        return ( $e->{draft} ? 1 : 0 ) if $mode eq 'draft';
        return ( $e->{draft} || ( ref $e->{read} eq 'ARRAY' && @{ $e->{read} } ) ) ? 1 : 0
            if $mode eq 'see';
        return ( ref $e->{$mode} eq 'ARRAY' && @{ $e->{$mode} } ) ? 1 : 0;
    };
    return $map->{$rel} if $governs->( $map->{$rel} );
    if ( $rel =~ m{\A(.+)\.(?:md|url|html)\z} ) {
        return $map->{$1} if $governs->( $map->{$1} );
    }
    my ( $best, $best_len ) = ( undef, -1 );
    for my $k ( keys %$map ) {
        next unless $governs->( $map->{$k} );
        ( my $p = $k ) =~ s{\A/+}{};
        $p =~ s{/+\z}{};
        next unless length $p;
        next unless index( $rel, "$p/" ) == 0;
        next unless length($p) > $best_len;
        ( $best, $best_len ) = ( $map->{$k}, length $p );
    }
    return $best if $best;
    for my $rk ( '/', '', '.' ) { return $map->{$rk} if $governs->( $map->{$rk} ) }
    return;
}

# Which folder an entry stands for, so two spellings of one folder compare equal.
sub tag { my ($e) = @_; return ref $e eq 'HASH' ? $e->{_tag} : 'none' }

my $seed = $ENV{SM1069_SEED} // 1069;
srand $seed;
my @dirs  = qw(a a/b a/b/c d d/e x);
my @kinds = ( { read => ['alice'] }, { draft => 1 }, { write => ['bob'] }, { owner => 'bob' },
    { read => [] }, { read => ['alice'], draft => 1 } );
my @paths = ( 'a/b/c/p.md', 'a/b/p.md', 'a/p.md', 'a/b.md', 'd/e/f/g.md', 'x.md', 'q.md',
    'a//b/p.md', 'a/b/c/', 'd/e.url', '/a/b/c/p.md' );

my ( $asked, @bad ) = (0);
for my $round ( 1 .. 300 ) {
    my %map;
    for my $d ( grep { rand() < 0.5 } @dirs ) {
        my $spell = ( '', '/' )[ rand 2 ] . $d . ( '', '/', '//' )[ rand 3 ];
        $map{$spell} = { %{ $kinds[ rand @kinds ] }, _tag => $d };
        if ( rand() < 0.2 ) {    # a second spelling of the same folder
            $map{"/$d/"} = { %{ $kinds[ rand @kinds ] }, _tag => $d };
        }
    }
    $map{'a/b/c/p.md'} = { %{ $kinds[ rand @kinds ] }, _tag => 'exact' } if rand() < 0.3;
    $map{'d/e'}        = { %{ $kinds[ rand @kinds ] }, _tag => 'd/e' }  if rand() < 0.3;
    $map{ ( '/', '', '.' )[ rand 3 ] } = { %{ $kinds[ rand @kinds ] }, _tag => 'root' } if rand() < 0.4;

    for my $p (@paths) {
        for my $mode ( 'read', 'draft', 'see', undef ) {
            $asked++;
            my $want = tag( walk( \%map, $p, $mode ) );
            my $got  = tag( main::_acl_entry_for( \%map, $p, $mode ) );
            push @bad, "round $round, $p, " . ( $mode // 'no mode' ) . ": walk $want, lookup $got"
                if $want ne $got;
        }
    }
}
cmp_ok( $asked, '>', 10_000, "questions asked ($asked)" );
is_deeply( \@bad, [], 'the ancestor lookup answers as the walk did' )
    or diag( "seed $seed\n" . join( "\n", @bad[ 0 .. ( $#bad < 9 ? $#bad : 9 ) ] ) );

subtest "a caller's own map, changed between calls, is never answered from a stale index" => sub {
    my %map = ( 'a' => { read => ['alice'], _tag => 'a' } );
    is( tag( main::_acl_entry_for( \%map, 'a/b/p.md', 'read' ) ), 'a', 'the folder rule' );
    $map{'a/b'} = { read => ['bob'], _tag => 'a/b' };
    is( tag( main::_acl_entry_for( \%map, 'a/b/p.md', 'read' ) ), 'a/b',
        'a nearer rule added to the same map is found' );
};

done_testing();
