#!/usr/bin/perl
# SM373: the catalogue listing dropped `kind`, and would drop the next field too.
#
# The layouts catalogue marks a demonstration layout `"kind": "demonstration"`
# so a caller choosing a base layout for a real site can filter gallery chrome
# out. `list_layout_catalogue` returned name / version / description / tags /
# default_theme / themes / installed on all 23 layouts and no `kind` - a
# hand-written allowlist that predated the key.
#
# IT IS THE FIELD SM337 ASKED FOR. Activation warns when a layout renders no
# navigation, and SM349 measured 1 of 23 doing so; what was missing is telling
# the two apart BEFORE installing, binding and rendering. The catalogue now says
# which is which and the engine was throwing the answer away.
#
# THE SHAPE, which is why this test is about more than one field: an allowlist
# that predates a key is SM330's mechanism exactly. There the statistics index
# enumerated class keys by hand and dropped `scanner`, the largest class, while
# the durable store held it correctly. The fix both times is to stop enumerating
# - so this asserts that every scalar field the manifest declares survives the
# passthrough, not merely that `kind` does.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(encode_json);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper                 qw(repo_root);
use Lazysite::Manager::Layouts ();

my $docroot = tempdir( CLEANUP => 1 );
$Lazysite::Manager::Layouts::DOCROOT      = $docroot;
$Lazysite::Manager::Layouts::LAZYSITE_DIR = "$docroot/lazysite";
make_path("$docroot/lazysite/layouts");

# A catalogue with one ordinary layout and one demonstration layout.
my %MANIFEST = (
    layouts => [
        { name => 'kestrel',
            version       => '1.0.0',
            description   => 'a site layout',
            tags          => ['clean'],
            default_theme => 'kestrel',
            themes        => [ { name => 'kestrel', version => '1.0.0' } ],
        },
        { name => 'explorer',
            version       => '1.1.0',
            description   => 'the gallery',
            tags          => [ 'internal', 'showcase' ],
            kind          => 'demonstration',
            default_theme => 'explorer',
            themes        => [ { name => 'explorer', version => '1.1.0' } ],
        },
    ],
);

# MOCKED AT THE FETCH, because action_layouts_manifest pulls manifest.json over
# HTTP from the layouts repo. A test that reaches the network is a test that
# fails when the network does and passes when somebody else edits a file - and
# the first version of this one did exactly that: it wrote a fixture to disk,
# the code ignored it, and the assertions ran against the LIVE 23-layout
# catalogue without saying so.
sub catalogue {
    no warnings 'redefine';
    local *Lazysite::Manager::Layouts::_http_get
        = sub { return ( 1, encode_json( \%MANIFEST ) ) };
    return Lazysite::Manager::Layouts::action_layouts_manifest();
}

subtest 'a demonstration layout says so' => sub {
    my $r = catalogue();
    ok( $r->{ok}, 'the catalogue lists' ) or diag explain $r;
    my %by = map { $_->{name} => $_ } @{ $r->{layouts} || [] };

    ok( exists $by{explorer}, 'the demonstration layout is listed' ) or return;
    is( $by{explorer}{kind}, 'demonstration',
        'and carries kind, so a caller can filter it out WITHOUT installing it' )
        or diag( 'This is the half SM337 could not supply: activation warns '
            . 'after you have bound the layout, and 1 of 23 renders the '
            . 'navigation.' );

    is( $by{kestrel}{kind}, '',
        'an ordinary layout has an empty kind rather than a missing key' )
        or diag( 'Absent-versus-empty is a distinction a caller has to handle; '
            . 'the other optional fields degrade to empty and this matches.' );
};

subtest 'and a tag is not a substitute for it' => sub {
    # The signal was never lost, only misplaced - explorer is tagged `internal`
    # and `showcase`. Worth asserting both survive, because the argument for
    # `kind` is not that the tags are missing: it is that a tag is a convention
    # and `kind` is a contract. Anyone can tag a layout `showcase` and mean
    # something else, or omit the tag and still set `kind`.
    my $r  = catalogue();
    my %by = map { $_->{name} => $_ } @{ $r->{layouts} || [] };
    is_deeply( $by{explorer}{tags}, [ 'internal', 'showcase' ],
        'the tags pass through as they always did' );
};

subtest 'every scalar the manifest declares survives the passthrough' => sub {
    # SM330's mechanism, guarded generally rather than one field at a time. An
    # allowlist that predates a key drops it silently, and the next key added to
    # the catalogue would go the same way.
    my $r  = catalogue();
    my %by = map { $_->{name} => $_ } @{ $r->{layouts} || [] };

    my @dropped;
    for my $decl ( @{ $MANIFEST{layouts} } ) {
        my $got = $by{ $decl->{name} } or next;
        for my $k ( sort keys %$decl ) {
            next if ref $decl->{$k};    # themes: shaped separately
            push @dropped, "$decl->{name}.$k" unless exists $got->{$k};
        }
    }
    is_deeply( \@dropped, [],
        'nothing the manifest declares is silently discarded' )
        or diag( "Dropped: @dropped\n"
            . 'A hand-written allowlist drops the next field too. This is the '
            . 'same mechanism as SM330, where an enumerated key list lost the '
            . 'largest traffic class while the store held it correctly.' );
};

done_testing();
