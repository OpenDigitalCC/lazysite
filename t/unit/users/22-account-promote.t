#!/usr/bin/perl
# SM194: promote a sub-user to top level. Three deliberate, separate behaviours:
#   1. account-promote clears managed_by (the account is then top-level in the
#      management tree; the sub-tree follows as it does for reassign).
#   2. Management promotion does NOT lift the created_by scope ceiling - a
#      promoted user WITHOUT scope_independent is still capped by their creator
#      (resolve_user_scopes walks created_by, not managed_by). Security-relevant.
#   3. account-scope-independent (operator-audited) makes resolve_user_scopes
#      STOP walking the created_by chain at that user - explicit emancipation,
#      created_by itself never rewritten.
# Plus: a non-operator delegate (a present --actor) is REFUSED promotion.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2;
use IPC::Open3;
use Symbol qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root grant_caps);
use Lazysite::Auth::Settings qw(resolve_user_scopes);
use Lazysite::Auth::DomainAccess qw(DENY_ALL_SCOPE);

my $root   = repo_root();
my $script = "$root/tools/lazysite-users.pl";

sub fresh_docroot {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/auth");
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "site_name: T\n";
    close $cf;
    return $d;
}

sub cli {
    my ( $docroot, @args ) = @_;
    my ( $wtr, $rdr );
    my $err = gensym;
    my $pid = open3( $wtr, $rdr, $err, $^X, $script, '--docroot', $docroot, @args );
    close $wtr;
    my $out  = do { local $/; <$rdr> };
    my $eout = do { local $/; <$err> };
    waitpid $pid, 0;
    return { out => $out // '', err => $eout // '', code => $? >> 8 };
}

sub api {
    my ( $docroot, $payload ) = @_;
    my ( $cout, $cin );
    my $pid = open2( $cout, $cin, $^X, $script, '--api', '--docroot', $docroot );
    print $cin encode_json($payload);
    close $cin;
    my $out = do { local $/; <$cout> };
    close $cout;
    waitpid $pid, 0;
    return eval { decode_json($out) } // { _raw => $out };
}

sub settings { return api( $_[0], { action => 'settings-get', username => $_[1] } )->{settings} }

# Resolve a user's scopes against $docroot (point the module's AUTH_DIR at it).
sub scopes_of {
    my ( $docroot, $user ) = @_;
    local $Lazysite::Auth::Settings::AUTH_DIR = "$docroot/lazysite/auth";
    return [ sort( resolve_user_scopes( $docroot, $user ) ) ];
}

# root -> a -> { b, c }
sub build_tree {
    my $d = fresh_docroot();
    cli( $d, 'add', 'root', 'pw' );
    grant_caps( $d, 'root', 'create_sub_users', 'delegate_sub_user_creation' );
    cli( $d, 'account-create', 'a', 'pw', '--by', 'root', '--create-subs' );
    cli( $d, 'account-create', 'b', 'pw', '--by', 'a' );
    cli( $d, 'account-create', 'c', 'pw', '--by', 'a' );
    return $d;
}

# --- 1. account-promote clears managed_by (top level) -----------------------
{
    my $d = build_tree();
    is( settings( $d, 'b' )->{managed_by}, 'a', 'precondition: b is managed by a' );
    ok( !settings( $d, 'b' )->{top_level}, 'precondition: b is not top-level' );

    my $r = cli( $d, 'account-promote', 'b' );
    is( $r->{code}, 0, 'account-promote exits 0' );
    like( $r->{out}, qr/top level/i, 'promote reports top-level move' );

    my $s = settings( $d, 'b' );
    ok( !defined $s->{managed_by} || !length $s->{managed_by},
        'promote: managed_by cleared (top-level-managed)' );
    ok( $s->{top_level}, 'promote: b is now top_level in the account view' );
    is( $s->{created_by}, 'a', 'promote: created_by (provenance) preserved' );

    # The sub-tree follows: b keeps managing its own children (none here), and
    # the API action mirrors the CLI verb.
    my $api = api( $d, { action => 'account-promote', username => 'c' } );
    ok( $api->{ok}, 'account-promote via --api succeeds' );
    ok( settings( $d, 'c' )->{top_level}, 'api promote: c is top-level' );
}

# --- 2 & 3. scope ceiling survives promotion; scope_independent lifts it ------
# Two DISJOINT domains so the creator's scope and the sub-user's scope do not
# overlap: the ceiling then narrows the sub-user to DENY-ALL. Emancipation
# removes that narrowing and leaves the sub-user's own domain scope standing.
{
    my $d = fresh_docroot();
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    # The base/default domain is docroot-rooted (no content_root) so it does NOT
    # add a universal scope - boss and kid then confine to DISJOINT roots, and
    # the created_by ceiling narrows kid to DENY-ALL (the case that proves it).
    print $cf <<'CONF';
site_name: Agency
alias_hosts: parent.com, child.com
alias.parent.com.content_root: sites/parent
alias.parent.com.allowed_groups: pgroup
alias.child.com.content_root: sites/child
alias.child.com.allowed_groups: cgroup
CONF
    close $cf;

    cli( $d, 'add', 'boss', 'pw' );
    grant_caps( $d, 'boss', 'create_sub_users' );    # role-boss group
    cli( $d, 'group-add', 'boss', 'pgroup' );        # boss reaches sites/parent
    cli( $d, 'account-create', 'kid', 'pw', '--by', 'boss' );
    cli( $d, 'group-add', 'kid', 'cgroup' );         # kid reaches sites/child

    is_deeply( scopes_of( $d, 'boss' ), ['sites/parent'],
        'boss (creator) is confined to sites/parent' );

    # Before promotion: kid is capped by boss. child ∩ parent = disjoint =
    # DENY-ALL. This is the deliberate created_by ceiling.
    is_deeply( scopes_of( $d, 'kid' ), [DENY_ALL_SCOPE],
        'sub-user is scope-capped by created_by (disjoint => deny-all)' );

    # Management promotion must NOT lift the ceiling (walks created_by, not
    # managed_by). Security-relevant assertion.
    cli( $d, 'account-promote', 'kid' );
    ok( settings( $d, 'kid' )->{top_level}, 'kid promoted to top level' );
    is_deeply( scopes_of( $d, 'kid' ), [DENY_ALL_SCOPE],
        'promotion alone does NOT lift the created_by scope ceiling' );
    ok( !settings( $d, 'kid' )->{scope_independent},
        'promotion did not set scope_independent' );

    # Explicit emancipation: resolve_user_scopes stops walking created_by at
    # kid, so kid keeps only its own domain scope (sites/child).
    my $e = cli( $d, 'account-scope-independent', 'kid', 'on' );
    is( $e->{code}, 0, 'account-scope-independent on exits 0' );
    ok( settings( $d, 'kid' )->{scope_independent},
        'scope_independent flag is set on the account' );
    is( settings( $d, 'kid' )->{created_by}, 'boss',
        'created_by (provenance) is NOT rewritten by emancipation' );
    is_deeply( scopes_of( $d, 'kid' ), ['sites/child'],
        'scope_independent stops the created_by walk: kid keeps its own scope' );

    # Reinstating the ceiling restores the deny-all cap.
    cli( $d, 'account-scope-independent', 'kid', 'off' );
    is_deeply( scopes_of( $d, 'kid' ), [DENY_ALL_SCOPE],
        'account-scope-independent off reinstates the created_by ceiling' );
}

# --- 4. operator-only: a non-operator delegate is refused --------------------
{
    my $d = build_tree();

    # A present --actor is a DELEGATE (the manager-api injects it only for a
    # non-operator caller). Promotion and emancipation are operator-only.
    my $refuse = cli( $d, 'account-promote', 'b', '--actor', 'a' );
    isnt( $refuse->{code}, 0, 'delegate (--actor a) is refused promotion' );
    like( $refuse->{err}, qr/operator|manage_users|authoris/i,
        'refusal names the operator requirement' );
    is( settings( $d, 'b' )->{managed_by}, 'a',
        'refused promotion left managed_by unchanged' );

    my $refuse2 = cli( $d, 'account-scope-independent', 'b', 'on', '--actor', 'a' );
    isnt( $refuse2->{code}, 0, 'delegate is refused scope emancipation' );
    ok( !settings( $d, 'b' )->{scope_independent},
        'refused emancipation left scope_independent unset' );

    # The same refusal over --api (actor carried in the request).
    my $api_refuse = api( $d,
        { action => 'account-promote', username => 'b', actor => 'a' } );
    ok( !$api_refuse->{ok}, 'api promotion with a delegate actor is refused' );

    # An operator (no actor) succeeds.
    my $ok = cli( $d, 'account-promote', 'b' );
    is( $ok->{code}, 0, 'operator (no actor) may promote' );
}

done_testing();
