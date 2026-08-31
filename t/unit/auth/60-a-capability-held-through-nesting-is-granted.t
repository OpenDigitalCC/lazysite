#!/usr/bin/perl
# SM702: a capability a group holds THROUGH NESTING is actually granted.
#
# WHAT THE OPERATOR SAW. Signed in to the manager, then: "Manager access not
# permitted ... this account is not permitted to use the manager interface."
# The account was in `site-admins`, the shipped groups put `site-admins` inside
# `ch-ui`, and `ch-ui` is the group holding `ui`. Every link was correct in the
# stores, and the answer was still no.
#
# WHY. _groups_grant_cap slurps groups-settings.json like this:
#
#     open my $fh, '<:raw', $f or return 0;
#     local $/;
#     my $gs = ...decode...;
#     for my $g ( _group_closure(@groups) ) { ... }
#
# `local $/` is scoped to the enclosing BLOCK - here the whole sub - so it was
# still undef when _group_closure ran. Its _group_membership_map reads the
# groups file with `while (<$fh>)`, and in slurp mode that loop takes the
# ENTIRE FILE as one line. Measured on the shipped store: the map collapsed
# from 21 groups to 1, so the parent table was empty and nothing nested ever
# resolved.
#
# IT FAILED CLOSED - a lockout rather than a leak - and it was invisible to
# every existing test, because they all put the user in a group that holds the
# capability DIRECTLY. This one grants it ONLY through nesting.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_minimal_site load_processor);
use JSON::PP;

my $docroot = tempdir( CLEANUP => 1 );
setup_minimal_site($docroot);
my $auth = "$docroot/lazysite/auth";
make_path($auth) unless -d $auth;

# `deep` holds ui. `leaf` reaches it only by nesting: leaf inside mid, mid
# inside deep. The extra lines matter - a slurp-mode read keeps only the FIRST
# line, so a two-line fixture could pass with the bug present.
open my $g, '>', "$auth/groups" or die $!;
print {$g} <<'GROUPS';
# a comment, so the parser has something to skip
noise-one: zeb
leaf: alice
mid: leaf
deep: mid
noise-two: yan
GROUPS
close $g;

open my $s, '>', "$auth/groups-settings.json" or die $!;
print {$s} JSON::PP->new->canonical->encode(
    {   deep        => { ui => 1, label => 'Holds the UI channel' },
        mid         => { label => 'Nesting only' },
        leaf        => { label => 'Nesting only' },
        'noise-one' => { label => 'noise' },
        'noise-two' => { label => 'noise' },
    }
);
close $s;

load_processor($docroot);

subtest 'the fixture would pass trivially if it were not nested' => sub {
    my $j = JSON::PP->new->decode(
        do { open my $fh, '<', "$auth/groups-settings.json" or die $!; local $/; <$fh> } );
    ok( $j->{deep}{ui},  'deep holds ui' );
    ok( !$j->{leaf}{ui}, 'leaf does NOT hold ui directly' )
        or diag( 'A fixture whose user holds the capability directly passes '
            . 'with the bug present - which is exactly how it survived.' );
};

subtest 'the membership map is read line by line' => sub {
    my %m = main::_group_membership_map();
    cmp_ok( scalar keys %m, '>=', 5, 'every group line was parsed' )
        or diag( 'One group means the file was read in slurp mode: some caller '
            . 'left $/ undef and `while (<$fh>)` took the whole file as a '
            . 'single line.' );
};

subtest 'the closure walks the nesting' => sub {
    my @c = main::_group_closure('leaf');
    my %in = map { $_ => 1 } @c;
    ok( $in{mid},  'leaf reaches mid' );
    ok( $in{deep}, 'and reaches deep, which is where the capability lives' );
};

subtest 'the capability is granted through the chain' => sub {
    ok( main::_groups_grant_cap( 'ui', 'leaf' ),
        'ui is granted to a member of leaf' )
        or diag( 'This is the operator-visible failure: "Manager access not '
            . 'permitted" for an account whose group reaches the ui-holding '
            . 'group by nesting.' );
    ok( !main::_groups_grant_cap( 'ui', 'noise-one' ),
        'and NOT to a group outside the chain' )
        or diag( 'A fix that made the closure too permissive would pass the '
            . 'assertion above and fail this one.' );
    ok( !main::_groups_grant_cap( 'manage_users', 'leaf' ),
        'and only the capability that is actually held' );
};

done_testing();
