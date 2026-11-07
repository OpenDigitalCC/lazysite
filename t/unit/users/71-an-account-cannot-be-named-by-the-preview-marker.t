#!/usr/bin/perl
# SM1390 (ruling 147): no account can be named by the preview cookie's marker.
#
# The session verifier refuses a payload beginning with that marker (t/unit/
# auth/76), so an account so named would sign in and be refused on every
# request. Every door that creates or renames an account refuses the name with
# a reason that says why: the users tool's add, rename and account-create (the
# manager's Users add and an import's approval go through add), and an import's
# stage. Each asks the verifier's own constant, so this test asks it too rather
# than spelling the marker.
use strict;
use warnings;
use Test::More;
use JSON::PP       qw(encode_json decode_json);
use MIME::Base64   qw(encode_base64);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper     qw(repo_root run_child);
use ManagerSession qw(new_site);
use Lazysite::Auth::Session ();

my $root   = repo_root();
my $marker = Lazysite::Auth::Session::PREVIEW_MARKER();
my $s      = new_site( root => $root, conf => "control_api_enabled: true\n" );
my $d      = $s->docroot;
$s->add_user( 'tks', 'pw-tks-0123456789' );
$s->grant( 'tks', 'g-tks', [qw(api manage_users)], [qw(api manage_users)] );

sub uapi {
    my ($p) = @_;
    my $out = run_child( [ $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // {};
}
sub cli {
    my @a = @_;
    return run_child( [ $^X, "$root/tools/lazysite-users.pl", '--docroot', $d, @a ], stderr => 'merge' )->{out} // '';
}
sub users { open my $fh, '<', "$d/lazysite/auth/users" or return ''; local $/; return scalar <$fh> }
my $why = qr/'\Q$marker\E' is reserved - it is the preview cookie's marker/;

subtest 'add refuses it, over the API and the CLI' => sub {
    my $r = uapi( { action => 'add', username => $marker, password => 'pw-long-enough' } );
    ok( !$r->{ok}, 'the API add is refused' ) or diag explain $r;
    like( $r->{error}, $why, 'naming the marker and why' );
    like( $r->{error}, qr/refused as a preview/, 'what would happen to its sessions' );
    like( cli( 'add', $marker, 'pw-long-enough' ), $why, 'the CLI add is refused the same way' );
    unlike( users(), qr/^\Q$marker\E:/m, 'and no such account exists' );
    ok( uapi( { action => 'add', username => "${marker}a", password => 'pw-long-enough' } )->{ok},
        'a name that merely begins with it is an ordinary name' );
};

subtest 'rename and account-create refuse it' => sub {
    ok( uapi( { action => 'add', username => 'alice', password => 'pw-long-enough' } )->{ok}, 'set up: alice' );
    my $r = uapi( { action => 'rename', username => 'alice', to => $marker } );
    ok( !$r->{ok}, 'a rename to it is refused' );
    like( $r->{error}, $why, 'with the reason' );
    like( users(), qr/^alice:/m, 'alice is still alice' );
    like( cli( 'account-create', $marker, 'pw-long-enough', '--by', 'alice' ), $why,
        'a sub-user creation is refused too' );
    unlike( users(), qr/^\Q$marker\E:/m, 'and nothing was created' );
};

subtest 'an import stages no such row' => sub {
    my $token = uapi( { action => 'token', username => 'tks' } )->{token} // '';
    ok( length $token, 'set up: a partner token' );
    my $json = encode_json( { accounts => [ { username => $marker, email => 'p@example.org' }, { username => 'fine' } ] } );
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED HTTP_COOKIE HTTP_X_CSRF_TOKEN LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{HTTP_AUTHORIZATION} = 'Basic ' . encode_base64( "tks:$token", '' );
    $ENV{QUERY_STRING}       = 'action=accounts-import-stage';
    $ENV{REQUEST_METHOD}     = 'POST';
    $ENV{CONTENT_LENGTH}     = length $json;
    my $out = run_child( [ $^X, "$root/lazysite-manager-api.pl" ], stdin => $json )->{out} // '';
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    my $r = eval { decode_json( $jb // '' ) } // { _raw => $out };
    my ($bad) = grep { ( $_->{username} // '' ) eq $marker } @{ $r->{invalid} || [] };
    ok( $bad, 'the row naming the marker is listed as invalid' ) or diag explain $r;
    like( $bad->{error} // '', $why, 'with the reason' );
    is( $r->{staged}, 1, 'and the other row is staged without it' );
};

done_testing();
