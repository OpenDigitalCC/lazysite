#!/usr/bin/perl
# SM268 H8 + H9: the ceiling is a property, and a site never falls open.
#
# H8. SM195 bounded DECLARING a capability and left four ways to ACQUIRE one. An
# adversarial review walked all four with a delegate holding only manage_users:
#
#   group-add     join a group that already holds mcp - instant acquisition
#   group-nest    nest a capable group under your own; every member inherits it
#   token         issue a credential for the operator. Worse than it sounds:
#                 cmd_token REPLACES the account's stored hash, so it takes the
#                 account over AND destroys its password in one call
#   claim-create  the same takeover, via a setup link
#
# H9. "Unsecured" mode did not mean "any authenticated user is a manager", which
# is what security.md said. It meant the manager API required NO credential and
# treated the caller as the operator - and a delegate could push a live site into
# that state, because the lockout guard only ever covered the `manager` flag
# while site_grants_manager() also counts `ui` and `manage_users`.
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

# A delegate holding manage_users and nothing else, plus a capable group and an
# operator account for it to attack.
sub setup {
    my ($d) = @_;
    cli( $d, 'add',       'boss',            'pw' );
    cli( $d, 'add',       'subadmin',        'pw' );
    cli( $d, 'group-add', 'boss',            'lazysite-admins' );
    cli( $d, 'group-add', 'subadmin',        'useradmins' );
    cli( $d, 'group-set', 'lazysite-admins', 'manage_users', 'on' );
    cli( $d, 'group-set', 'lazysite-admins', 'ui',           'on' );
    cli( $d, 'group-set', 'lazysite-admins', 'manager',      'on' );
    cli( $d, 'group-set', 'useradmins',      'manage_users', 'on' );
    cli( $d, 'group-set', 'useradmins',      'ui',           'on' );
    # The prize: a group carrying a capability the delegate cannot confer, and
    # an account that HOLDS it - `boss` must actually out-rank `subadmin`, or
    # the ceiling has nothing to refuse and the test passes vacuously.
    cli( $d, 'group-set', 'agents', 'mcp', 'on' );
    cli( $d, 'group-add', 'boss', 'agents' );
    return;
}

sub caps_of {
    my ( $d, $user ) = @_;
    return cli( $d, 'caps', $user );
}

# --- H8: group-add -----------------------------------------------------------
subtest 'a delegate cannot join a group whose capabilities exceed its own' => sub {
    my $d = fixture();
    setup($d);

    my $r = api( $d, action => 'group-add', username => 'subadmin',
        group => 'agents', actor => 'subadmin' );
    ok( !$r->{ok}, 'refused' ) or diag encode_json($r);
    unlike( caps_of( $d, 'subadmin' ), qr/^\s*mcp\s*:\s*1/mi,
        'and it did not acquire mcp - joining a capable group IS conferral' );
};

subtest 'but may still add someone to a group it could confer' => sub {
    my $d = fixture();
    setup($d);
    cli( $d, 'group-set', 'useradmins', 'analytics', 'on' );
    cli( $d, 'group-set', 'readers',    'analytics', 'on' );

    my $r = api( $d, action => 'group-add', username => 'boss',
        group => 'readers', actor => 'subadmin' );
    ok( $r->{ok} || !defined $r->{error}, 'allowed - it holds analytics itself' )
        or diag encode_json($r);
};

# --- H8: group-nest ----------------------------------------------------------
subtest 'a delegate cannot nest a group whose capabilities exceed its own' => sub {
    my $d = fixture();
    setup($d);

    my $r = api( $d, action => 'group-nest', sub => 'agents',
        parent => 'useradmins', actor => 'subadmin' );
    ok( !$r->{ok}, 'refused' );
    unlike( caps_of( $d, 'subadmin' ), qr/^\s*mcp\s*:\s*1/mi,
        'no inheritance through the closure either' );
};

# --- H8: token ---------------------------------------------------------------
# The worst of the four: cmd_token REPLACES the target's stored hash, so this is
# takeover plus destruction of the password, in one call.
subtest 'a delegate cannot issue a credential for a more capable account' => sub {
    my $d = fixture();
    setup($d);

    my $before = do {
        open my $fh, '<', "$d/lazysite/auth/users" or die $!;
        local $/;
        <$fh>;
    };

    my $r = api( $d, action => 'token', username => 'boss', actor => 'subadmin' );
    ok( !$r->{ok}, 'refused' ) or diag encode_json($r);

    my $after = do {
        open my $fh, '<', "$d/lazysite/auth/users" or die $!;
        local $/;
        <$fh>;
    };
    is( $after, $before,
        "and boss's stored hash is untouched - a refusal that still rewrote the "
            . 'users file would be the denial-of-service half landing anyway' );
};

# --- H8: claim-create --------------------------------------------------------
subtest 'a delegate cannot mint a setup link for a more capable account' => sub {
    my $d = fixture();
    setup($d);
    my $r = api( $d, action => 'claim-create', username => 'boss',
        actor => 'subadmin' );
    ok( !$r->{ok}, 'refused - a setup link mints a credential, so it is the '
            . 'same takeover by another route' );
};

# --- H9: the site cannot be pushed into unsecured mode ----------------------
# --- H9: the lockout guard covers ui and manage_users, not just `manager` ----
# WHAT THIS DOES AND DOES NOT SHOW, because a first attempt at it passed on the
# unfixed code and so proved nothing.
#
# The pre-existing guard protects the `manager` FLAG, and site_grants_manager()
# counts `manager` OR `ui` OR `manage_users`. So while any group carries the
# flag, the site cannot be opened however much `ui` is stripped - and the
# reviewer's "21 calls, 0 refusals" strip does not reproduce through this verb.
# I could not construct a state where it does.
#
# The gap that IS real: a site granting `ui` with no manager-flagged group at all
# is a legitimate configuration, and there the old guard has nothing to protect.
# This asserts the new guard covers that - the last granting group keeps its
# grant whether or not it carries the flag.
subtest 'the last group granting manager access cannot be stripped' => sub {
    my $d = fixture();
    cli( $d, 'add',       'solo',       'pw' );
    cli( $d, 'group-add', 'solo',       'onlyadmins' );
    cli( $d, 'group-set', 'onlyadmins', 'ui', 'on' );

    # Clear every other grant, including the seeded groups, so `onlyadmins` is
    # demonstrably the last one standing.
    my $gs = do {
        open my $fh, '<', "$d/lazysite/auth/groups-settings.json" or die $!;
        local $/;
        decode_json(<$fh>);
    };
    for my $g ( sort keys %$gs ) {
        next if $g eq 'onlyadmins';
        for my $key (qw(ui manage_users manager)) {
            next unless $gs->{$g}{$key};
            api( $d, action => 'group-settings-set', group => $g,
                key => $key, value => 'off' );
        }
    }

    my $r = api( $d, action => 'group-settings-set', group => 'onlyadmins',
        key => 'ui', value => 'off' );
    ok( !$r->{ok},
        'refused - and NOT by the manager-flag guard, which has nothing to '
            . 'protect here: no group carries the flag' );
    like( $r->{error} || '', qr/no group granting manager access/,
        'the message says which invariant it is defending' );
};

subtest 'the guard does not block an ordinary removal' => sub {
    my $d = fixture();
    setup($d);
    # useradmins is not the last: lazysite-admins still grants.
    my $r = api( $d, action => 'group-settings-set', group => 'useradmins',
        key => 'ui', value => 'off' );
    ok( $r->{ok},
        'allowed - a guard that refuses every removal gets switched off' );
};

done_testing();
