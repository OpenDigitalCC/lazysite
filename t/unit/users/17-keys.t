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
use JSON::PP qw(encode_json decode_json);
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
    cli( $d, 'add', 'boss', 'pw' );                    # human, has a password
    cli( $d, 'group-add', 'boss', 'lazysite-admins' );
    cli( $d, 'add', 'agent', 'x' );
    cli( $d, 'group-add', 'agent', 'agent-ai' );       # grants api/mcp + content
    cli( $d, 'set', 'agent', 'ui', 'off' );            # non-interactive
    cli( $d, 'token', 'agent' );                       # mint its key (credential)

    my $k = keymap($d);
    ok( $k->{agent}, 'the non-interactive agent account is listed as a key' );
    ok( !$k->{boss}, 'the interactive manager is NOT listed (its credential is a login password)' );
    ok( ( grep { $_ eq 'api' } @{ $k->{agent}{channels} } ), 'the key names its channels (api)' );
    is( $k->{agent}{interactive}, JSON::PP::false, 'the key is flagged non-interactive' );
}

# Revoke: the machine credential is cleared; the account survives; the key
# disappears from the list. An interactive account is refused.
{
    my $d = docroot();
    cli( $d, 'add', 'deploy', 'x' );
    cli( $d, 'group-add', 'deploy', 'agent-ai' );
    cli( $d, 'set', 'deploy', 'ui', 'off' );
    cli( $d, 'token', 'deploy' );
    ok( keymap($d)->{deploy}, 'deploy has a key before revoke' );

    my $r = api( $d, { action => 'key-revoke', username => 'deploy' } );
    ok( $r->{ok}, 'key-revoke succeeds for a machine account' );
    ok( !keymap($d)->{deploy}, 'the key is gone after revoke' );
    # The account itself is intact (still present, just credential-less).
    my $list = api( $d, { action => 'list' } );
    ok( ( grep { $_ eq 'deploy' } @{ $list->{users} || [] } )
            || api( $d, { action => 'settings-get', username => 'deploy' } )->{ok},
        'the account still exists after its key is revoked' );

    cli( $d, 'add', 'human', 'pw' );
    cli( $d, 'group-add', 'human', 'lazysite-admins' );
    my $bad = api( $d, { action => 'key-revoke', username => 'human' } );
    ok( !$bad->{ok} && $bad->{error} =~ /interactive/i,
        'key-revoke refuses an interactive account (would be a lockout, not a key revoke)' );
}

done_testing();
