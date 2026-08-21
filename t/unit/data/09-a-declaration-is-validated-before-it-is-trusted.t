#!/usr/bin/perl
# ADR 0009: a plugin's `owns` declaration is validated where it is READ, once,
# before any consumer trusts it.
#
# THE CONTRACT IS THAT THE PLATFORM CONSUMES THE DECLARATION instead of knowing
# the plugin by name - backup and site packages read `storage`, the SBOM gate
# reads `deps`, the capability lints discover `capabilities`. Each of those
# TRUSTS the list. Trust established separately by each consumer is trust
# established four times and correctly zero to three of them.
#
# `storage` IS THE DANGEROUS FIELD and the reason this exists before any
# consumer does. A site package excludes `lazysite/` wholesale because that is
# where the auth store, the sessions and the backups live. Carrying plugin
# storage means carrying NAMED paths beneath it - so a declaration of
# `lazysite/`, or `../..`, or `/etc`, would turn a feature that ships a site
# into one that ships an auth store.
#
# Every refusal below is a path that must never reach a consumer. They are
# asserted now, while there is no consumer, so that the first one is written
# against a checked structure rather than a hopeful one.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Plugins::Owns qw(validate_owns owns_keys);

sub bad { return [ validate_owns( 'test', $_[0] ) ] }
sub ok_decl { return !scalar @{ bad( $_[0] ) } }

subtest 'the shape' => sub {
    ok( scalar @{ bad('not a hash') }, 'owns must be a mapping' );
    ok( ok_decl( {} ), 'an empty declaration is legal - a plugin may own nothing' );
    my $u = bad( { capability => ['x'] } );
    ok( scalar @{$u}, 'an unknown key is REFUSED' )
        or diag( 'Ignoring it means an author writing `capability` for '
            . '`capabilities` gets silence and a capability that never '
            . 'appears, which reads as the platform being broken.' );
    like( $u->[0]{error}, qr/expected: /, 'and the message lists the real keys' );
    ok( scalar @{ bad( { storage => 'lazysite/db/' } ) },
        'a bare string where a list belongs is refused' );
};

subtest 'storage: the paths a site package would carry' => sub {
    ok( ok_decl( { storage => ['lazysite/db/'] } ), 'a named subtree is fine' );

    for my $p ( 'lazysite/', 'lazysite', '/etc/', 'etc/passwd',
        '../../etc/', 'lazysite/../auth/', '' )
    {
        ok( !ok_decl( { storage => [$p] } ), "refused: '" . $p . "'" )
            or diag( 'This path would be handed to backup and site packaging '
                . 'as something the plugin owns.' );
    }

    my $e = bad( { storage => ['lazysite/db'] } );
    ok( scalar @{$e}, "a path with no trailing slash is refused" );
    like( $e->[0]{error}, qr/sibling/,
        'and the reason is the boundary, not tidiness' )
        or diag( 'Without the slash, `lazysite/db` claims `lazysite/db2` to '
            . 'any consumer doing a prefix match - the same fault this '
            . 'codebase has met six times, in a new place.' );
};

subtest 'the other fields are shaped too' => sub {
    ok( !ok_decl( { capabilities => ['Manage Data'] } ), 'a capability name is strict' );
    ok( !ok_decl( { capabilities => ['manage-data'] } ), 'hyphens are not names here' );
    ok( ok_decl(  { capabilities => ['manage_data'] } ), 'and the real one passes' );

    ok( !ok_decl( { endpoints => ['../lazysite-data.pl'] } ),
        'an endpoint may not carry a path' )
        or diag( 'An endpoint elsewhere is not this plugin\'s to declare.' );
    ok( ok_decl( { endpoints => ['lazysite-data.pl'] } ), 'a bare script name is fine' );

    ok( !ok_decl( { deps => ['dbi'] } ),     'a module name is not lower-case' );
    ok( ok_decl(  { deps => ['DBD::SQLite'] } ), 'a real one passes' );
    ok( !ok_decl( { config_keys => ['dbSource'] } ), 'config keys are snake_case' );
};

subtest 'every problem is reported, not just the first' => sub {
    my $e = bad( { storage => [ 'lazysite/', '/etc/' ], deps => ['nope'] } );
    ok( scalar @{$e} >= 3, 'three problems, three entries' )
        or diag( 'The caller is a lint reporting to a developer or a page '
            . 'reporting to an operator. Stopping at the first turns one fix '
            . 'into four round trips.' );
    ok( ( grep { $_->{key} eq 'deps' } @{$e} ), 'including the one in another field' );
};

subtest 'the shipped plugins that declare owns, declare it soundly' => sub {
    my $dir = "$FindBin::Bin/../../../plugins";
    my @declaring;
    for my $f ( sort glob "$dir/*.pl" ) {
        my $d = eval { decode_json( `$^X \Q$f\E --describe 2>/dev/null` ) };
        next unless ref $d eq 'HASH' && $d->{owns};
        push @declaring, $d->{id};
        my @bad = validate_owns( $d->{id}, $d->{owns} );
        is_deeply( \@bad, [], "$d->{id}: declaration is sound" )
            or diag( join "\n  ", map { "$_->{key}: $_->{error}" } @bad );
    }
    # ADR 0009 migrates the existing plugins one per SM, post-stable, so most
    # declare nothing yet. Recording WHICH conform makes that migration
    # visible instead of implicit - and this test starts asserting a plugin's
    # declaration the moment it grows one.
    ok( scalar @declaring, 'at least one plugin conforms' )
        or diag( 'The data plugin is ADR 0009\'s exemplar; if it stops '
            . 'declaring, the contract has no implementation.' );
    diag( "conforming today: @declaring" );
};

done_testing();
