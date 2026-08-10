#!/usr/bin/perl
# SM268 02-5, 02-6, 02-7: three places that answered a question about
# capabilities from a different source than the enforcement points do.
#
# 02-5  _may_confer resolved HELD capabilities with caps_for, which walks the
#       compound-group closure, and `grantable` with direct membership only. An
#       operator who put grantable on a PARENT group had delegated nothing to
#       the members of its children, and got no diagnostic. It failed closed, so
#       not an escalation - but the natural workaround is to move the delegate
#       into the parent group, which hands them everything the parent holds.
#
# 02-6  the permissions grid had the same blind spot in the other direction: a
#       capability conferred by NESTING was enforced everywhere and displayed
#       nowhere, so an operator auditing "who holds manage_users" was told
#       nobody did. Paired with the then-unguarded group-nest that was a
#       persistence mechanism - escalate by nesting, review screen shows clean.
#
# 02-7  _is_operator decided from X-Remote-Groups while its neighbours decided
#       from the store. The store is now asked FIRST; the header is kept, and
#       the last subtest is why.
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

# sub1 is a member of `child`, and `child` is nested inside `parent`, so the
# closure (which walks UPWARD: a user's groups, plus every group listing one of
# them as a member) gives sub1 everything `parent` carries. Both groups must
# exist before the nest, which is why the capabilities are set first.
sub nested_fixture {
    my $d = fixture();
    cli( $d, 'add',        'sub1',   'pw' );
    cli( $d, 'add',        'target', 'pw' );
    cli( $d, 'group-add',  'sub1',   'child' );
    cli( $d, 'group-set',  'parent', 'manage_users', 'on' );
    cli( $d, 'group-set',  'parent', 'ui',           'on' );
    cli( $d, 'group-nest', 'child',  'parent' );
    return $d;
}

subtest 'a nested grant is HELD' => sub {
    my $d = nested_fixture();
    my $s = api( $d, action => 'settings-get', username => 'sub1' );
    ok( $s->{settings}{manage_users},
        'the closure is what enforcement uses, so this was never in doubt - it '
            . 'is the baseline the other two subtests are measured against' );
};

subtest 'grantable follows nesting too' => sub {
    my $d = nested_fixture();
    # The set lives on the PARENT, which is the spelling an operator reaches for.
    cli( $d, 'group-set', 'parent',    'grantable', 'mcp' );
    cli( $d, 'group-set', 'receivers', 'label',     'R' );

    my $r = api( $d, action => 'group-settings-set', group => 'receivers',
        key => 'mcp', value => 'on', actor => 'sub1' );
    ok( $r->{ok},
        'sub1 may confer mcp - the delegation an operator wrote on the parent '
            . 'now reaches the members of its children' )
        or diag encode_json($r);
};

subtest 'and the ceiling still refuses what nothing grants' => sub {
    my $d = nested_fixture();
    cli( $d, 'group-set', 'parent',    'grantable', 'mcp' );
    cli( $d, 'group-set', 'receivers', 'label',     'R' );

    my $r = api( $d, action => 'group-settings-set', group => 'receivers',
        key => 'manage_layouts', value => 'on', actor => 'sub1' );
    ok( !$r->{ok},
        'manage_layouts is neither held nor grantable, so widening the lookup '
            . 'to the closure did not widen the authority' );
};

subtest 'the permissions grid shows a nested grant' => sub {
    my $d = nested_fixture();
    my $g = api( $d, action => 'permissions-grid', username => 'sub1' );

    my $groups = join ',', @{ $g->{groups} || [] };
    like( $groups, qr/parent/,
        'the group that actually carries the capability is named' );

    my $by = $g->{granted_by} || {};
    ok( ( ref $by->{manage_users} eq 'ARRAY' && @{ $by->{manage_users} } ),
        'and manage_users is shown as granted - an audit that says nobody holds '
            . 'it, while the store says somebody does, is the defect' );
};

subtest 'operator status is read from the store, and the header still works' => sub {
    my $d = nested_fixture();

    # Store-side: sub1 holds manage_users only through the nesting closure, and
    # supplies NO groups header at all.
    require Lazysite::Auth::Acl;
    local $Lazysite::Auth::Acl::DOCROOT    = $d;
    local $Lazysite::Auth::Acl::auth_user  = 'sub1';
    local $Lazysite::Auth::Acl::token_auth = 0;
    local $ENV{HTTP_X_REMOTE_GROUPS}       = '';
    ok( Lazysite::Auth::Acl::_is_operator(),
        'the store answers, with no header in play' );

    # Header-side: an identity the local store does not know at all, carrying a
    # group that grants manage_users - a trusted proxy or SSO. Dropping this,
    # as the review suggested, would break that deployment.
    local $Lazysite::Auth::Acl::auth_user = 'from-idp';
    local $ENV{HTTP_X_REMOTE_GROUPS} = 'parent';
    ok( Lazysite::Auth::Acl::_is_operator(),
        'the trusted header still confers operator status for an identity the '
            . 'local store has never seen' );

    # And neither source grants it to someone with neither.
    local $Lazysite::Auth::Acl::auth_user = 'target';
    local $ENV{HTTP_X_REMOTE_GROUPS} = '';
    ok( !Lazysite::Auth::Acl::_is_operator(),
        'an ordinary account is not an operator by either route' );
};

done_testing();
