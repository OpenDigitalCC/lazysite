#!/usr/bin/perl
# SM991, ruled 2026-10-12 ("Yes, protect operator sessions too"): only the
# operator revokes the operator's sessions or access keys.
#
# SM991 made manage_users user and group management, and refused a holder that
# is not the operator any users-tool change to the operator's account. The
# Sessions page's three revokes were not asked: a manage_users holder could
# sign the operator out everywhere (user-revoke), sign out one of its sessions
# (session-revoke), or strip its OAuth grants (key-revoke), and repeat it.
# Manager::Sessions now asks the same rule, Manager::Users::
# _operator_target_refusal, with the account each revoke reaches; manage_users
# still revokes every other account's, and the operator revokes anyone's.
#
# Every refusal is read back from the stores (revoked.json, oauth.json), not
# only from the reply.
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper     qw(repo_root);
use ManagerSession qw(new_site);
use Lazysite::Auth::OAuth ();

my $root = repo_root();
my $s    = new_site( root => $root );
my $d    = $s->docroot;
my $auth = "$d/lazysite/auth";

sub slurp { my ($p) = @_; open my $fh, '<', $p or return undef; local $/; my $t = <$fh>; close $fh; return $t }

my @ALL = qw(ui manage_users manage_config);
$s->add_user('boss');     # the operator
$s->grant( 'boss', 'sysops', [qw(ui manage_users)], \@ALL );
$s->users( 'group-set', 'sysops', 'manager', 'on' );
$s->add_user('boss2');    # a second operator
$s->users( 'group-add', 'boss2', 'sysops' );
$s->add_user('um');       # manage_users and nothing else
$s->grant( 'um', 'people', [qw(ui manage_users)], \@ALL );
$s->add_user('other');    # an account nobody here created
$s->grant( 'other', 'readers', [qw(ui)], \@ALL );

# The session registry, as the auth wrapper writes it: one line per login.
my %SID = (
    boss  => 'b0b0b0b0b0b0b0b0',
    boss2 => 'b2b2b2b2b2b2b2b2',
    um    => 'a1a1a1a1a1a1a1a1',
    other => 'c0c0c0c0c0c0c0c0',
);
{
    open my $fh, '>', "$auth/sessions.jsonl" or die "registry: $!";
    for my $u ( sort keys %SID ) {
        print {$fh} JSON::PP::encode_json( { sid => $SID{$u}, user => $u, t => time, ip => '192.0.2.1', ua => 't' } ), "\n";
    }
    close $fh;
}
my $UNKNOWN = 'deadbeefdeadbeef';    # a sid in the right shape the registry does not hold

# An OAuth grant each: an interactive account's key-revoke drops its grants
# and leaves its password (SM668), which is the operator's revocable key.
my %TOKEN;
{
    no warnings 'once';
    local $Lazysite::Auth::OAuth::LAZYSITE_DIR = "$d/lazysite";
    ( $TOKEN{$_} ) = Lazysite::Auth::OAuth::issue_token($_) for qw(boss boss2 other);
}
sub grant_live {
    my ($u) = @_;
    no warnings 'once';
    local $Lazysite::Auth::OAuth::LAZYSITE_DIR = "$d/lazysite";
    return ( Lazysite::Auth::OAuth::validate_token( $TOKEN{$u} ) // '' ) eq $u ? 1 : 0;
}
sub revoked {
    my $r = eval { JSON::PP::decode_json( slurp("$auth/revoked.json") // '' ) };
    return ref $r eq 'HASH' ? $r : { sids => {}, not_before => {} };
}
sub sid_revoked { return exists revoked()->{sids}{ $_[0] } ? 1 : 0 }
sub signed_out  { return exists revoked()->{not_before}{ $_[0] } ? 1 : 0 }

sub call { my ( $u, $act, $body ) = @_; return $s->call( $u, $act, groups => 1, query => "action=$act", body => $body ) }
sub forbidden { my ($r) = @_; return !$r->{ok} && ( $r->{kind} // '' ) eq 'forbidden' ? 1 : 0 }

subtest 'manage_users alone is refused the operator\'s sessions and keys' => sub {
    my $r = call( 'um', 'session-revoke', { sid => $SID{boss} } );
    ok( forbidden($r), 'session-revoke of an operator session: refused' ) or diag( explain $r );
    like( $r->{error} // '', qr/'boss' is the site operator/, 'and the refusal names the operator rule' );
    ok( !sid_revoked( $SID{boss} ), 'revoked.json does not hold the sid' );

    $r = call( 'um', 'user-revoke', { username => 'boss' } );
    ok( forbidden($r), 'user-revoke of the operator: refused' ) or diag( explain $r );
    ok( !signed_out('boss'), 'the operator is not signed out everywhere' );

    $r = call( 'um', 'user-revoke', { username => 'bo!ss' } );
    ok( forbidden($r), 'a name that cleans to the operator\'s: refused' ) or diag( explain $r );
    ok( !signed_out('boss'), 'still not signed out' );

    $r = call( 'um', 'key-revoke', { username => 'boss' } );
    ok( forbidden($r), 'key-revoke of the operator: refused' ) or diag( explain $r );
    ok( grant_live('boss'), 'the operator\'s OAuth grant still resolves' );

    $r = call( 'um', 'users', { action => 'key-revoke', username => 'boss' } );
    ok( forbidden($r), 'key-revoke through the users action: refused (SM991)' ) or diag( explain $r );
    ok( grant_live('boss'), 'and the grant still resolves' );

    $r = call( 'um', 'session-revoke', { sid => $SID{boss2} } );
    ok( forbidden($r) && !sid_revoked( $SID{boss2} ), 'a second operator\'s session: refused' ) or diag( explain $r );

    $r = call( 'um', 'session-revoke', { sid => $UNKNOWN } );
    ok( forbidden($r), 'a sid the registry cannot place: refused (fail closed)' ) or diag( explain $r );
    ok( !sid_revoked($UNKNOWN), 'and not written' );
};

subtest 'manage_users still revokes every other account' => sub {
    my $r = call( 'um', 'session-revoke', { sid => $SID{other} } );
    ok( $r->{ok}, 'session-revoke of a non-operator session' ) or diag( explain $r );
    ok( sid_revoked( $SID{other} ), 'revoked.json holds the sid' );

    $r = call( 'um', 'user-revoke', { username => 'other' } );
    ok( $r->{ok} && signed_out('other'), 'user-revoke of a non-operator' ) or diag( explain $r );

    $r = call( 'um', 'key-revoke', { username => 'other' } );
    ok( $r->{ok} && ( $r->{oauth_dropped} // 0 ) == 1, 'key-revoke of a non-operator drops its grant' )
        or diag( explain $r );
    ok( !grant_live('other'), 'the grant no longer resolves' );

    $r = call( 'um', 'session-revoke', { sid => $SID{um} } );
    ok( $r->{ok} && sid_revoked( $SID{um} ), 'and its own session' ) or diag( explain $r );

    $r = call( 'um', 'session-revoke', { sid => 'nope' } );
    ok( !$r->{ok} && ( $r->{error} // '' ) =~ /16 hex/, 'a malformed sid meets the action\'s own refusal' )
        or diag( explain $r );
};

subtest 'the operator revokes anyone\'s' => sub {
    my $r = call( 'boss', 'session-revoke', { sid => $SID{boss2} } );
    ok( $r->{ok} && sid_revoked( $SID{boss2} ), 'another operator\'s session' ) or diag( explain $r );

    $r = call( 'boss', 'user-revoke', { username => 'boss2' } );
    ok( $r->{ok} && signed_out('boss2'), 'another operator, everywhere' ) or diag( explain $r );

    $r = call( 'boss', 'key-revoke', { username => 'boss2' } );
    ok( $r->{ok} && !grant_live('boss2'), 'another operator\'s key' ) or diag( explain $r );

    $r = call( 'boss', 'session-revoke', { sid => $UNKNOWN } );
    ok( $r->{ok} && sid_revoked($UNKNOWN), 'a sid the registry cannot place' ) or diag( explain $r );

    $r = call( 'boss', 'user-revoke', { username => 'um' } );
    ok( $r->{ok} && signed_out('um'), 'a non-operator' ) or diag( explain $r );

    $r = call( 'boss', 'key-revoke', { username => 'boss' } );
    ok( $r->{ok} && !grant_live('boss'), 'and its own key' ) or diag( explain $r );
};

done_testing();
