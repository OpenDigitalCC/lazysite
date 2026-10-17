#!/usr/bin/perl
# SM747 B, THE SECURITY CASE: the password a person types goes to Odoo through
# OOM's session transport, once, and goes nowhere else. Tested with OOM's REAL
# transport over a stand-in for HTTP that records everything posted, and with
# the process's log captured:
#
#   * the password is in exactly one post - the authenticate route - and in no
#     URL, no cookie header, no later call;
#   * it is not in the result, in any error text, in the log, in the call record
#     or the audit line; the same for a transport failure that ECHOES the
#     request body into its own message;
#   * a wrong password and an unknown login are told the same way (no
#     enumeration), and neither says what was typed;
#   * a two-factor account (Odoo accepts the password, opens no session) is
#     refused BY NAME;
#   * signing out ends the session at Odoo.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use OdooTest qw(oom_or_skip shop_ready quiet);

BEGIN { oom_or_skip() }
use OdooSessionHTTP;
use Lazysite::Odoo          ();
use Lazysite::Odoo::Session ();
use Lazysite::Odoo::Visitor ();

my ( $d, $fake ) = shop_ready();
my $PW    = 'correct-horse-Battery-staple-91';
my $WRONG = 'hunter2-not-the-password';
my $http  = OdooSessionHTTP->new( fake => $fake, people => {
        'jane@example.com' => { password => $PW, uid => 7, name => 'Jane Doe', login => 'jane@example.com' },
        'otp@example.com' => { password => $PW, uid => 8, name => 'Otto', login => 'otp@example.com', two_factor => 1 },
        'totp@example.com' => { password => $PW, uid => 9, name => 'Tove', login => 'totp@example.com', totp => '123456' },
} );
$Lazysite::Odoo::Session::HTTP = $http;
$Lazysite::Odoo::TRANSPORT     = undef;
{
    no warnings 'once';
    $Lazysite::Odoo::Visitor::DOCROOT = $d;    # the test itself checks a cookie
}

my ($conn) = Lazysite::Odoo::connection();
my $ip = '192.0.2.44';

sub signin {
    my ( $login, $pw, %o ) = @_;
    my ( $log, $r ) = quiet( sub { Lazysite::Odoo::sign_in( login => $login, password => $pw, ip => $ip, %o ) } );
    return ( $r, $log );
}

sub everything_written {
    my @files = ( Lazysite::Odoo::calls_file() );
    my $text  = '';
    for my $f (@files) {
        open my $fh, '<', $f or next;
        local $/;
        $text .= <$fh>;
    }
    # and every file under the store and the site's own log directory
    my @all = glob("$d/lazysite/odoo/*"), glob("$d/lazysite/logs/*"), glob("$d/lazysite/*.log");
    for my $f ( grep { -f } @all ) {
        open my $fh, '<', $f or next;
        local $/;
        $text .= <$fh>;
    }
    return $text;
}

subtest 'a right password signs in; the password went to one route only' => sub {
    my ( $r, $log ) = signin( 'jane@example.com', $PW );
    ok( $r->{ok},            'signed in' ) or diag explain $r;
    ok( length $r->{cookie}, 'a signed cookie value comes back for the endpoint to set' );
    is( $r->{identity}{name}, 'Jane Doe', 'with the name for a greeting' );
    my @with_pw = grep { index( encode_json( $_->{body} ), $PW ) >= 0 } @{ $http->posts };
    is( scalar @with_pw,   1, 'the password is in exactly one post' );
    is( $with_pw[0]{path}, '/web/session/authenticate', '...the authenticate route' );
    is( scalar( grep { index( $_->{url}, $PW ) >= 0 || index( $_->{cookie}, $PW ) >= 0 } @{ $http->posts } ),
        0, 'and in no URL and no cookie' );
    unlike( encode_json($r), qr/\Q$PW\E/, 'not in the result' );
    unlike( $log,            qr/\Q$PW\E/, 'not in the log' );
    unlike( everything_written(), qr/\Q$PW\E/, 'not in the call record, the audit line or any file the engine wrote' );
    my ($sid) = keys %{ $http->sessions };
    ok( $sid, q{Odoo holds a session} );
    is( Lazysite::Odoo::Session::sid_from_cookie( 'lzs_odoo_session=' . $r->{cookie} ), $sid,
        'the cookie carries the session, signed' );
};

subtest 'a wrong password and an unknown login are told alike, saying nothing typed' => sub {
    my ( $a, $alog ) = signin( 'jane@example.com',   $WRONG );
    my ( $b, $blog ) = signin( 'nobody@example.com', $WRONG );
    is( $a->{kind},  'signin-refused', 'a wrong password' );
    is( $b->{kind},  'signin-refused', 'an unknown login: the same kind' );
    is( $a->{error}, $b->{error},      '...in the same words' );
    ok( !$a->{cookie} && !$a->{session_id}, 'no session, no cookie' );
    for my $t ( encode_json($a), encode_json($b), $alog, $blog, everything_written() ) {
        unlike( $t, qr/\Q$WRONG\E/, 'what was typed is in no text' );
    }
    unlike( encode_json($a) . $alog, qr/nobody\@example\.com|jane\@example\.com/, 'nor the login, in a result or a log line' );
};

subtest 'a two-factor account is refused by name' => sub {
    my ( $r, $log ) = signin( 'otp@example.com', $PW );
    is( $r->{kind}, 'two-factor', 'its own kind' );
    like( $r->{error}, qr/two-factor authentication/, 'in words' );
    ok( !$r->{cookie}, 'and no session' );
    unlike( encode_json($r) . $log, qr/\Q$PW\E/, 'the password is in neither' );
};

# SM1156: OOM 0.27 answers a two-factor account's right password with a true
# `pending` result and a half-open session id (0.24 died). It is not a sign-in:
# no session cookie may be minted for it. SM1157 carries it to the code step
# (t/unit/odoo/48); here, that it is never taken for a session.
subtest 'a pending two-factor answer is not a sign-in (OOM 0.27)' => sub {
    my ( $r, $log ) = signin( 'totp@example.com', $PW );
    ok( $r->{ok}, 'the password step is answered' );
    is( $r->{second_factor}, 'totp', 'as a step to take' );
    ok( !$r->{cookie} && !$r->{session_id}, 'no session cookie, no session id' );
    ok( $r->{pending_cookie}, 'the half-open sign-in is carried in its own cookie value' );
    is( scalar( keys %{ $http->pending } ), 1, 'Odoo holds the half-open session until the code, or sign-out' );
    my ($sid) = keys %{ $http->pending };
    ok( !Lazysite::Odoo::Session::sid_from_cookie( 'lzs_odoo_session=' . $r->{pending_cookie} ),
        'and it does not read as a session' );
    unlike( encode_json( { %$r, pending_cookie => undef } ) . $log, qr/\Q$PW\E|\Q$sid\E/,
        'the password and the session id are in nothing else the engine returns, and not in the log' );
    Lazysite::Odoo::Session::sign_out( $conn, $sid );
    is( scalar( keys %{ $http->pending } ), 0, 'signing out ends it' );
};

# An OOM that cannot finish the step refuses the account by name, and nothing is
# carried (the floor stays at 0.03 because such an OOM never answers pending).
subtest 'a pending answer an OOM cannot finish is refused by name' => sub {
    my $r;
    {
        no warnings qw(once redefine);
        local *Odoo::Transport::Session::complete_totp;
        ( undef, $r ) = quiet( sub { Lazysite::Odoo::Session::sign_in( $conn, 'totp@example.com', $PW ) } );
    }
    is( $r->{kind}, 'two-factor', 'refused by name' );
    ok( !$r->{ok} && !$r->{pending} && !$r->{session_id}, 'with nothing to carry' );
    is( scalar( keys %{ $http->pending } ), 0, 'and the half-open session was ended at Odoo' );
};

subtest 'a transport that echoes the request into its error leaks nothing' => sub {
    $http->down(1);
    my ( $r, $log ) = signin( 'jane@example.com', $PW );
    $http->down(0);
    is( $r->{kind}, 'transport-failure', 'a transport failure' );
    unlike( encode_json($r) . $log . everything_written(), qr/\Q$PW\E/,
        'the password is in no result, log or record even though the fault carried it' );
};

subtest 'signing out ends the session at Odoo, and tolerates one already gone' => sub {
    my ($r) = signin( 'jane@example.com', $PW );
    my $sid = Lazysite::Odoo::Session::sid_from_cookie( 'lzs_odoo_session=' . $r->{cookie} );
    ok( $http->sessions->{$sid},                          'the session is live' );
    ok( Lazysite::Odoo::Session::sign_out( $conn, $sid ), 'signed out' );
    ok( !$http->sessions->{$sid},                         'and Odoo has forgotten it' );
    ok( Lazysite::Odoo::Session::sign_out( $conn, $sid ), 'again: still no error' );
    ok( Lazysite::Odoo::Session::sign_out( $conn, 'not a session id!' ), 'a malformed id: nothing sent, no error' );
};

subtest 'what is typed is bounded and plain before it is sent' => sub {
    my $before = scalar @{ $http->posts };
    my ($r) = signin( '', $PW );
    is( $r->{kind}, 'invalid', 'no login' );
    ($r) = signin( 'jane@example.com', '' );
    is( $r->{kind}, 'invalid', 'no password' );
    ($r) = signin( "jane\@example.com\n", $PW );
    is( $r->{kind}, 'invalid', 'a control character in the login' );
    ($r) = signin( 'jane@example.com', 'x' x 5000 );
    is( $r->{kind},               'invalid', 'a password far past any real one' );
    is( scalar @{ $http->posts }, $before,   'none of them reached Odoo' );
};

done_testing();
