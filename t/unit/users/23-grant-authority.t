#!/usr/bin/perl
# SM195: grant authority is distinct from held capability - and the ceiling it
# presupposed did not exist.
#
# SM195 opens: "the delegation model enforces privilege de-escalation: a grantor
# can only confer capabilities they themselves hold", calls that the right
# default, and asks to relax it so a sub-admin need not hold `mcp` merely to
# grant it to their agent.
#
# There was no such ceiling. %ACTOR_FORBIDDEN required manage_users and nothing
# further, so a non-operator delegate could confer ANY capability - including on
# a group it was itself in. A manage_users delegate could grant itself mcp, api
# or manage_config and become an operator in all but name. Reproduced before
# building anything.
#
# So the mechanism SM195 asked for is built AND the rule it is an exception to,
# because `grantable` is meaningless without a ceiling to except it from.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP   qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $TOOL = repo_root() . '/tools/lazysite-users.pl';

sub fixture {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/auth");
    open my $fh, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$fh} "site_name: T\n";
    close $fh;
    return $d;
}

sub cli {
    my ( $d, @args ) = @_;
    my $cmd = join ' ', map { quotemeta } $^X, $TOOL, '--docroot', $d, @args;
    return scalar qx($cmd 2>&1);
}

# Drive the API the way the manager does, with an actor.
sub api {
    my ( $d, %req ) = @_;
    my $json = encode_json( \%req );
    open my $ph, '|-', "$^X \Q$TOOL\E --api --docroot \Q$d\E > $d/.out 2>/dev/null"
        or die $!;
    print {$ph} $json;
    close $ph;
    open my $rh, '<', "$d/.out" or return {};
    my $out = do { local $/; <$rh> };
    close $rh;
    return eval { decode_json($out) } || {};
}

sub setup_subadmin {
    my ($d) = @_;
    cli( $d, 'add',       'subadmin',   'pw' );
    cli( $d, 'group-add', 'subadmin',   'useradmins' );
    cli( $d, 'group-set', 'useradmins', 'manage_users', 'on' );
    # A second manager group, so the lockout guard never interferes.
    cli( $d, 'add',       'boss', 'pw' );
    cli( $d, 'group-add', 'boss', 'lazysite-admins' );
    cli( $d, 'group-set', 'lazysite-admins', 'manage_users', 'on' );
    return;
}

# --- the ceiling ------------------------------------------------------------
subtest 'a delegate cannot confer a capability it does not hold' => sub {
    my $d = fixture();
    setup_subadmin($d);

    my $r = api( $d, action => 'group-settings-set', group => 'agents',
        key => 'mcp', value => 'on', actor => 'subadmin' );
    ok( !$r->{ok}, 'refused' );
    is( $r->{kind}, 'forbidden', 'as a permission refusal' );
    like( $r->{error}, qr/grant authority/,
        'and the message names the mechanism that would allow it' );
};

subtest 'and cannot confer it on its OWN group either' => sub {
    my $d = fixture();
    setup_subadmin($d);

    my $r = api( $d, action => 'group-settings-set', group => 'useradmins',
        key => 'mcp', value => 'on', actor => 'subadmin' );
    ok( !$r->{ok},
        'self-escalation refused - this was the hole: manage_users was the only '
            . 'check, so a delegate could grant itself anything' );
};

# --- holding it is still sufficient -----------------------------------------
subtest 'a delegate that HOLDS the capability may confer it' => sub {
    my $d = fixture();
    setup_subadmin($d);
    cli( $d, 'group-set', 'useradmins', 'analytics', 'on' );

    my $r = api( $d, action => 'group-settings-set', group => 'agents',
        key => 'analytics', value => 'on', actor => 'subadmin' );
    ok( $r->{ok}, 'allowed - the de-escalation default is unchanged' );
};

# --- grantable is the exception SM195 asked for -----------------------------
subtest 'an operator-set grantable lets a delegate confer without holding' => sub {
    my $d = fixture();
    setup_subadmin($d);

    # Operator (no actor) sets the grant authority.
    my $g = api( $d, action => 'group-settings-set', group => 'useradmins',
        key => 'grantable', value => 'mcp' );
    ok( $g->{ok}, 'operator set the grant authority' ) or diag encode_json($g);

    my $r = api( $d, action => 'group-settings-set', group => 'agents',
        key => 'mcp', value => 'on', actor => 'subadmin' );
    ok( $r->{ok},
        'the delegate may now confer mcp on the agent group WITHOUT holding mcp '
            . '- which is exactly what SM195 asked for' );

    # And it did not acquire the capability itself.
    my $caps = cli( $d, 'caps', 'subadmin' );
    unlike( $caps, qr/^\s*mcp\s*:\s*(?:1|on|yes)/mi,
        'and the delegate still does NOT hold mcp - the point was to avoid '
            . 'enlarging its own surface' );
};

# --- grant authority is conferred from above, never self-assumed ------------
# The invariant SM195 names as non-negotiable. If a delegate could widen its own
# grantable set, the ceiling would be decorative.
subtest 'a delegate cannot set its own grant authority' => sub {
    my $d = fixture();
    setup_subadmin($d);

    my $r = api( $d, action => 'group-settings-set', group => 'useradmins',
        key => 'grantable', value => 'mcp,api,manage_config', actor => 'subadmin' );
    ok( !$r->{ok}, 'refused' );
    is( $r->{kind}, 'forbidden', 'as a permission refusal' );

    # Nor on any other group - it is not about which group, it is about who asks.
    my $r2 = api( $d, action => 'group-settings-set', group => 'agents',
        key => 'grantable', value => 'mcp', actor => 'subadmin' );
    ok( !$r2->{ok}, 'and not on another group either' );
};

# --- an unknown capability is not quietly accepted --------------------------
subtest 'grantable rejects a capability that does not exist' => sub {
    my $d = fixture();
    setup_subadmin($d);
    my $r = api( $d, action => 'group-settings-set', group => 'useradmins',
        key => 'grantable', value => 'mcp,not_a_capability' );
    ok( !$r->{ok}, 'refused' );
    like( $r->{error}, qr/not_a_capability/,
        'naming the bad one - a typo that silently became grant authority for '
            . 'nothing would read as working' );
};

# --- taking a capability away needs no grant authority ----------------------
# De-escalation is always allowed; the ceiling is about conferring.
subtest 'a delegate may REMOVE a capability it cannot confer' => sub {
    my $d = fixture();
    setup_subadmin($d);
    cli( $d, 'group-set', 'agents', 'mcp', 'on' );    # operator put it there

    my $r = api( $d, action => 'group-settings-set', group => 'agents',
        key => 'mcp', value => 'off', actor => 'subadmin' );
    ok( $r->{ok}, 'allowed - removing is de-escalation and needs no authority' );
};

# --- the manager flag stays operator-only -----------------------------------
subtest 'a delegate cannot make a group a manager group' => sub {
    my $d = fixture();
    setup_subadmin($d);
    my $r = api( $d, action => 'group-settings-set', group => 'agents',
        key => 'manager', value => 'on', actor => 'subadmin' );
    ok( !$r->{ok},
        'refused - otherwise a delegate mints a manager group and walks in' );
};

# --- an operator is unrestricted, as everywhere else ------------------------
subtest 'an operator is not subject to the ceiling' => sub {
    my $d = fixture();
    setup_subadmin($d);
    my $r = api( $d, action => 'group-settings-set', group => 'agents',
        key => 'mcp', value => 'on' );    # no actor = operator context
    ok( $r->{ok}, 'operator confers freely' );
};

done_testing();
