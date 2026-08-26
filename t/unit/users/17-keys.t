#!/usr/bin/perl
# SM145: active access keys (the Sessions-page "Active keys" view). A key is a
# MACHINE credential - a non-interactive account (api / mcp / webdav) that holds
# a live credential. keys-list surfaces exactly those; key-revoke blanks the
# credential (the token stops authenticating) but never touches an interactive
# account's login password.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $script = repo_root() . '/tools/lazysite-users.pl';

sub docroot {
    my $d = tempdir( CLEANUP => 1 );
    mkdir "$d/lazysite"; mkdir "$d/lazysite/auth";
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "manager_groups: lazysite-admins\n";
    close $cf;
    return $d;
}

# One --api round-trip.
sub api {
    my ( $d, $req ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $script, '--api', '--docroot', $d );
    print $i encode_json($req);
    close $i;
    my $out = do { local $/; <$o> };
    close $o;
    waitpid $pid, 0;
    return ( eval { decode_json($out) } ) || {};
}
# One CLI (shell) call.
sub cli {
    my ( $d, @a ) = @_;
    system( $^X, $script, '--docroot', $d, @a ) == 0;
}
sub keymap {
    my ($d) = @_;
    my $r = api( $d, { action => 'keys-list' } );
    return { map { $_->{user} => $_ } @{ $r->{keys} || [] } };
}

# An AI agent account (non-interactive, api/mcp) with a credential IS a key; a
# human manager (interactive) with a password is NOT.
{
    my $d = docroot();
    cli( $d, 'add',       'boss',  'pw' );                # human, has a password
    cli( $d, 'group-add', 'boss',  'lazysite-admins' );
    cli( $d, 'add',       'agent', 'x' );
    cli( $d, 'group-add', 'agent', 'agent-ai' );          # grants api/mcp + content
    cli( $d, 'set',       'agent', 'ui', 'off' );         # non-interactive
    cli( $d, 'token',     'agent' );                      # mint its key (credential)

    my $k = keymap($d);
    ok( $k->{agent}, 'the non-interactive agent account is listed as a key' );

    # SM439: the interactive manager IS listed now, and that is the change.
    #
    # This asserted the opposite, and the reason was sound as far as it went -
    # a human's credential is a login PASSWORD, and offering it as a revocable
    # key is how an operator locks out the only manager. But it answered that
    # by HIDING the account rather than by declining to revoke it, and the
    # account holds webdav: HTTP Basic, replaying that password on every
    # request, creating no session. So the access was live whenever they chose
    # to use it, absent from this page always and from Sessions unless a
    # browser cookie happened to be open.
    #
    # The stated intent of these pages is that no active - or potentially
    # active - access is hidden. Listing is not offering: revocation is still
    # refused, asserted below, and that is where the lockout decision belongs.
    ok( $k->{boss}, 'the interactive manager holding webdav IS listed' );
    is( $k->{boss}{interactive}, JSON::PP::true,
        'flagged interactive, so the UI can offer it differently' );
    is_deeply( $k->{boss}{channels}, ['webdav'],
        'and named by the channel that makes it reachable' );
    ok( ( grep { $_ eq 'api' } @{ $k->{agent}{channels} } ), 'the key names its channels (api)' );
    is( $k->{agent}{interactive}, JSON::PP::false, 'the key is flagged non-interactive' );
}

# Revoke: the machine credential is cleared; the account survives; the key
# disappears from the list. An interactive account is refused.
{
    my $d = docroot();
    cli( $d, 'add',       'deploy', 'x' );
    cli( $d, 'group-add', 'deploy', 'agent-ai' );
    cli( $d, 'set',       'deploy', 'ui', 'off' );
    cli( $d, 'token',     'deploy' );
    ok( keymap($d)->{deploy}, 'deploy has a key before revoke' );

    my $r = api( $d, { action => 'key-revoke', username => 'deploy' } );
    ok( $r->{ok},              'key-revoke succeeds for a machine account' );
    ok( !keymap($d)->{deploy}, 'the key is gone after revoke' );
    # The account itself is intact (still present, just credential-less).
    my $list = api( $d, { action => 'list' } );
    ok( ( grep { $_ eq 'deploy' } @{ $list->{users} || [] } )
            || api( $d, { action => 'settings-get', username => 'deploy' } )->{ok},
        'the account still exists after its key is revoked' );

    cli( $d, 'add',       'human', 'pw' );
    cli( $d, 'group-add', 'human', 'lazysite-admins' );
    my $bad = api( $d, { action => 'key-revoke', username => 'human' } );
    ok( !$bad->{ok} && $bad->{error} =~ /interactive/i,
        'key-revoke refuses an interactive account (would be a lockout, not a key revoke)' );
}

# --- SM163: a plain verify-credential (the control-API token path, no touch
# flag) now RECORDS use - so an api/dav key shows as used, not "not used yet".
# Checked directly against the stored setting (keys-list's in_use derives from
# cred_used_at >= cred_issued_at). Throttled so a hot key does not rewrite.
{
    my $d = docroot();
    cli( $d, 'add',       'kbot', 'x' );
    cli( $d, 'group-add', 'kbot', 'agent-ai' );    # api/mcp machine account
    my $tok = api( $d, { action => 'token', username => 'kbot' } )->{token};
    ok( $tok, 'minted a key for kbot' );

    my $before = read_kbot_settings($d);
    ok( ( $before->{cred_used_at} // 0 ) < ( $before->{cred_issued_at} // 0 ),
        'not-yet-used before any verify (used < issued)' );

    # A verify WITHOUT a touch flag must now stamp cred_used_at.
    my $v = api( $d, { action => 'verify-credential', username => 'kbot', secret => $tok } );
    ok( $v->{ok}, 'verify-credential succeeds' );
    is( $v->{first_use}, 1, 'first_use reported on the first verify since issuance' );

    my $after = read_kbot_settings($d);
    ok( $after->{cred_used_at}, 'cred_used_at is recorded after a token verify (SM163)' );
    ok( $after->{cred_used_at} >= $after->{cred_issued_at},
        'in-use: used >= issued (what keys-list derives in_use from)' );

    # A second verify inside the throttle window: still succeeds, not first_use,
    # and does not move the stamp.
    my $v2 = api( $d, { action => 'verify-credential', username => 'kbot', secret => $tok } );
    is( $v2->{first_use}, 0, 'a subsequent verify is not first_use' );
    is( read_kbot_settings($d)->{cred_used_at}, $after->{cred_used_at},
        'throttled: the stamp does not move within the window' );
}

sub read_kbot_settings {
    my ($d) = @_;
    open my $fh, '<', "$d/lazysite/auth/user-settings.json" or return {};
    my $all = eval { decode_json( do { local $/; <$fh> } ) } || {};
    return $all->{kbot}                                      || {};
}

# SM615: an interactive account holding NO machine channel is listed too, and
# it was the last hidden case.
#
# SM439 widened this to an interactive account that ALSO held webdav, and
# stopped there. A plain manager account - a password, the manager, nothing
# else - remained absent from BOTH cards: from Active sessions whenever no
# browser cookie happened to be live, and from here by the machine-channel
# filter. "No hidden case where access is active or potentially active" was
# not yet true of the commonest account on any site.
{
    my $d = docroot();
    cli( $d, 'add', 'plain', 'pw' );    # a password, and no group at all

    my $k = keymap($d);
    ok( $k->{plain}, 'an account with only a password and the manager is listed' )
        or diag( 'listed: ' . join( ', ', sort keys %$k ) );
    is_deeply( $k->{plain}{channels}, [],
        'with NO key channels - the manager is not something a key opens' );
    is( $k->{plain}{signs_in}, JSON::PP::true,
        'and it is marked as an account that signs in' );

    # Listing is still not offering.
    my $r = api( $d, { action => 'key-revoke', username => 'plain' } );
    ok( !$r->{ok}, 'and revoking it is still refused' );
}

done_testing();
