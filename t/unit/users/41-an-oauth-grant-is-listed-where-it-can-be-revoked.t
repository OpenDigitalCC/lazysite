#!/usr/bin/perl
# SM668: an MCP agent connected over OAuth appeared on neither Sessions nor
# Keys, so the only lever an operator could find was disabling the account.
#
# Three stores, two pages: the session registry feeds Sessions, the users
# credential store feeds Keys, and lazysite/auth/oauth.json fed nothing. An
# OAuth client authenticates per request with a bearer token from the third,
# creating no cookie - so Sessions cannot show it by construction - and
# keys-list skipped any account with no stored credential, which is exactly an
# OAuth-only partner.
#
# The mechanism was already right: cmd_key_revoke drops OAuth grants
# (revoke_partner) and guards on the account EXISTING, not on it holding a
# credential. Revocation already worked on precisely the accounts the listing
# hid. So this lists what can already be revoked - "listing is not offering",
# as SM439 put it.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);
use JSON::PP;

my $root  = repo_root();
my $users = "$root/tools/lazysite-users.pl";
plan skip_all => 'users tool missing' unless -f $users;

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");

sub run {
    my (@a) = @_;
    my $cmd = join ' ', map { quotemeta } ( $^X, $users, '--docroot', $d, @a );
    return qx($cmd 2>&1);
}
# key-revoke is an API action, not a CLI command - calling it as one prints the
# usage and changes nothing, which is what the first version of this file did.
# Returns the DECODED reply. The first version piped it to /dev/null, so a
# subtest could assert on a row and pass while the action itself had refused -
# which is exactly what sabotage found.
sub api {
    my ($req) = @_;
    my $json  = encode_json($req);
    my $out   = qx(printf '%s' \Q$json\E | $^X \Q$users\E --api --docroot \Q$d\E 2>/dev/null);
    my $r     = eval { decode_json( $out // '' ) };
    return ref $r eq 'HASH' ? $r : { ok => 0, _raw => $out };
}

sub keys_list {
    my $json = qx(echo '{"action":"keys-list"}' | $^X \Q$users\E --api --docroot \Q$d\E 2>/dev/null);
    my $r = eval { decode_json($json) };
    return ref $r eq 'HASH' ? ( $r->{keys} || [] ) : [];
}
sub row_for {
    my ($u) = @_;
    for my $k ( @{ keys_list() } ) { return $k if ( $k->{user} // '' ) eq $u }
    return undef;
}

# AN ACCOUNT THAT GENUINELY HOLDS NO STORED CREDENTIAL. This is the case the
# listing hid, and getting the fixture wrong hides it again: an account created
# with `add` holds a password, so it would be listed whether or not the OAuth
# half works. The first version of this file did exactly that and sabotage
# caught it - removing the OAuth clause from the filter failed nothing.
#
# So: ui OFF (a machine partner), then key-revoke, which for a NON-interactive
# account does blank the credential. Only then is the account OAuth-only.
# A HUMAN FIRST. `set ui off` honours a last-manager guard, so with only one
# manager-capable account the account-level flag stays on however the groups are
# set - and the account remains "interactive", which is what key-revoke keys on.
run( 'add', 'human', 'pw123456789' );
run( 'group-set', 'humans', 'ui', 'on' );
run( 'group-set', 'humans', 'manage_users', 'on' );
run( 'group-add', 'human', 'humans' );

run( 'add', 'oauthonly', 'pw123456789' );
run( 'group-set', 'agents', 'mcp', 'on' );
run( 'group-set', 'agents', 'ui',  'off' );
run( 'group-add', 'oauthonly', 'agents' );
run( 'set', 'oauthonly', 'ui', 'off' );
api( { action => 'key-revoke', username => 'oauthonly' } );

{
    open my $fh, '<', "$d/lazysite/auth/users" or die $!;
    my $store = do { local $/; <$fh> };
    close $fh;
    my ($cred) = $store =~ /^oauthonly:(.*)$/m;
    ok( !length( $cred // '' ),
        'the fixture account holds NO stored credential' )
        or BAIL_OUT( 'it holds one, so nothing below tests the OAuth-only case '
            . '- which is the entire subject of SM668' );
}

subtest 'without a grant it is not listed as holding a key' => sub {
    my $r = row_for('oauthonly');
    ok( !defined $r || !$r->{oauth_grants},
        'an account with neither a credential nor a grant reports no OAuth grant' );
};

subtest 'a live OAuth grant puts the account on the page' => sub {
    # Written through the module that owns the store, not by hand: the record
    # shape is its business, and a hand-built one would drift from it.
    require Lazysite::Auth::OAuth;
    no warnings 'once';
    local $Lazysite::Auth::OAuth::LAZYSITE_DIR = "$d/lazysite";
    my ( $access, $refresh, $ttl ) = Lazysite::Auth::OAuth::issue_token('oauthonly');
    ok( $access && $refresh, 'a grant was issued' ) or return;

    my $r = row_for('oauthonly');
    ok( $r, 'the account is listed on Keys' )
        or diag( 'This is the whole defect: active access, shown nowhere.' );
    cmp_ok( $r->{oauth_grants} // 0, '>=', 1, 'and its grant is counted' );
    cmp_ok( $r->{oauth_expires_at} // 0, '>', time(), 'with the access expiry' );
    cmp_ok( $r->{oauth_refresh_at} // 0, '>', $r->{oauth_expires_at} // 0,
        'and the REFRESH expiry, which outlives it' )
        or diag( 'An access token expiring in an hour is not "disconnected" '
            . 'when a refresh good for weeks sits behind it - a page showing '
            . 'only the first answers the wrong question reassuringly.' );
};

subtest 'revoking the key drops the grant, and the row with it' => sub {
    api( { action => 'key-revoke', username => 'oauthonly' } );
    my $r = row_for('oauthonly');
    ok( !defined $r || !$r->{oauth_grants},
        'the grant is gone after key-revoke' )
        or diag( 'cmd_key_revoke already called revoke_partner; this proves '
            . 'the listing and the lever agree about the same account.' );
};

subtest 'an INTERACTIVE account keeps its password when its grant is revoked' => sub {
    # THE GUARD THAT WAS THERE FIRST, and must still hold: key-revoke never
    # blanks an interactive account's credential, because that is its login
    # PASSWORD and clearing the sole manager's is a lockout, not a revocation.
    #
    # It used to refuse outright, which was right about the password and wrong
    # about everything else the account holds. An interactive account can also
    # be an OAuth partner, and once the grant is listed on Keys the operator
    # must be able to act on it from the page it appears on - a row showing
    # access nobody can revoke there is worse than no row.
    #
    # So: the grants go, the password stays. A change that dropped both to make
    # the listing actionable would have turned a visibility fix into a lockout,
    # which is what the second assertion here exists to catch.
    require Lazysite::Auth::OAuth;
    no warnings 'once';
    local $Lazysite::Auth::OAuth::LAZYSITE_DIR = "$d/lazysite";
    Lazysite::Auth::OAuth::issue_token('human');

    my $r = row_for('human');
    cmp_ok( $r->{oauth_grants} // 0, '>=', 1,
        'an interactive account with a grant is listed too' );

    my $rev = api( { action => 'key-revoke', username => 'human' } );
    ok( $rev->{ok}, 'key-revoke SUCCEEDS on an interactive account' )
        or diag( 'It used to refuse outright, leaving the operator with only '
            . 'account-disable - which is where SM668 started. Got: '
            . ( $rev->{error} // '(no error)' ) );
    cmp_ok( $rev->{oauth_dropped} // 0, '>=', 1,
        'and reports how many grants it dropped' );
    my $after = row_for('human');
    ok( !( $after->{oauth_grants} // 0 ), 'the grant is gone from the listing' );

    open my $fh, '<', "$d/lazysite/auth/users" or die $!;
    my $store = do { local $/; <$fh> };
    close $fh;
    my ($cred) = $store =~ /^human:(.*)$/m;
    ok( length( $cred // '' ), 'and the login password is untouched' )
        or diag( 'If this is empty, revoking an OAuth grant just locked a '
            . 'human out of the manager.' );
};

done_testing();
