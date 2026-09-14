#!/usr/bin/perl
# SM879: the group view says what a member ACTUALLY gets, and where from.
#
# Since SM631 split groups into three layers (cap-* bundles, ch-* channels,
# role-* compositions), a role holds NOTHING directly - it draws everything from
# the bundles it is nested inside. The Groups page drew only the direct grants,
# so nine of the ten shipped roles rendered an entirely unticked capability grid
# while granting between three and eleven capabilities. site-admins showed an
# empty grid and granted eleven. An operator opening a role to answer "what does
# this grant" was shown nothing and given no way to find out.
#
# The release manager hit this on agent-ai and reported it as not being able to
# understand what the group grants. It is not a documentation gap: the answer
# was absent from the only surface that administers it.
#
# WHY THE SERVER DERIVES IT. The page could scan for groups listing this one as
# a member, and that answer would be WRONG whenever a bundle is nested inside
# another bundle - it would stop at one level and under-report SILENTLY. The
# engine already closes the graph transitively, in one place, to decide
# authorisation; this asks that same walk, so what the page shows and what the
# engine enforces cannot drift.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2 qw(open2);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir);

my $root  = do { my $d = $FindBin::Bin; $d =~ s{/t/unit/users$}{}; $d };
my $utool = "$root/tools/lazysite-users.pl";

sub w { open my $fh, '>', $_[0] or die $!; print {$fh} $_[1]; close $fh }

sub uapi {
    my ( $d, $p ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $utool, '--api', '--docroot', $d );
    print $i encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    close $o;
    waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}

my $d    = site_tempdir();
my $auth = "$d/lazysite/auth";
make_path($auth);

# The shipped shape, plus one bundle nested inside another so the TRANSITIVE
# case is covered: role-editor reaches cap-deep only through cap-content.
w( "$auth/groups-settings.json",
    encode_json( {
            'cap-content' => { manage_content => 1, manage_nav => 1,
                label => 'Capability: content', assignable => JSON::PP::false() },
            'cap-deep' => { manage_forms => 1,
                label => 'Capability: deep', assignable => JSON::PP::false() },
            'ch-agent' => { mcp => 1,
                label => 'Channel: AI agent', assignable => JSON::PP::false() },
            # Holds ONE capability of its own, so the direct/inherited split is
            # observable rather than inferred from an all-or-nothing group.
            'role-editor' => { analytics => 1,
                label => 'Website editor', assignable => JSON::PP::true() },
    } ) );
w( "$auth/groups",
    "cap-content: role-editor\n"
        . "ch-agent: role-editor\n"
        . "cap-deep: cap-content\n" );

my $r = uapi( $d, { action => 'group-settings-get' } );
ok( $r->{ok}, 'group-settings-get answered' ) or do { done_testing(); exit };

my $role = $r->{groups}{'role-editor'};
ok( $role, 'the role is in the view' ) or do { done_testing(); exit };

# --- the direct grants are unchanged -----------------------------------------
ok( $role->{caps}{analytics}, 'a capability granted directly is still reported as direct' );
ok( !$role->{caps}{manage_content},
    'and one that only arrives through a bundle is NOT reported as direct' )
    or diag( 'Folding inherited grants into caps{} would make the page offer an '
        . 'editable checkbox for something this group cannot revoke.' );

# --- what a member actually gets, with attribution ---------------------------
my $inh = $role->{inherited} || {};
is_deeply( $inh->{manage_content}, ['cap-content'],
    'an inherited capability names the bundle it comes from' );
is_deeply( $inh->{mcp}, ['ch-agent'], 'a channel is attributed the same way' );

# THE TRANSITIVE CASE - the one a one-level scan gets wrong.
is_deeply( $inh->{manage_forms}, ['cap-deep'],
    'a capability two levels up is reported, and attributed to its real source' )
    or diag( 'role-editor is in cap-content, which is in cap-deep. A parent scan '
        . 'that stops at one level misses manage_forms entirely and says nothing '
        . 'about having stopped - the operator reads a complete-looking list that '
        . 'is short by however deep the nesting goes.' );

ok( !exists $inh->{analytics},
    'a capability held directly is not also listed as inherited' );

# --- a bundle at the top inherits nothing ------------------------------------
my $deep = $r->{groups}{'cap-deep'};
is_deeply( $deep->{inherited}, {},
    'a group nothing is nested above inherits nothing (an empty map, not absent)' )
    or diag( 'An empty object is a truthful "inherits nothing". Omitting the key '
        . 'would make "no inheritance" and "an engine too old to answer" the '
        . 'same value on the page.' );

# --- the page tolerates an engine that does not send the field ---------------
#
# How the grid RENDERS an inherited grant is proven in
# t/unit/manager/121, which extracts the row builder and runs it - a source
# check here would be the weaker duplicate of an assertion that already
# executes. What is NOT covered there is the missing-field case, because the
# stub always defines the map.
my $page = do {
    open my $fh, '<', "$root/starter/manager/groups.md" or die $!;
    local $/;
    <$fh>;
};
like( $page, qr/var\s+inherited\s*=\s*info\.inherited\s*\|\|\s*\{\}/,
    'the page tolerates an engine that does not send the inherited field' )
    or diag( 'A manager page can be served against an engine older than the '
        . 'view that feeds it. Without the fallback the grid throws while '
        . 'rendering and the operator sees no groups at all - a worse failure '
        . 'than the one being fixed.' );

done_testing();
