#!/usr/bin/perl
# SM1181 S2 (SM1082 C2, T1 and T7): THE REQUEST'S IDENTITY VALUE IS HELD FOR ONE
# REQUEST AND NO LONGER.
#
# From S3 the pool's front door decides who a request is and holds the answer in
# the processor's `our $REQUEST_IDENT`, which _request_identity and the
# no_password readers then take in place of the environment. A pooled worker
# serves up to 500 requests in one process, so a value left there is the last
# visitor's identity handed to the next (T1) - the SM973 class with a person in it.
# It is cleared at BOTH ends of handle_one_request: at the start, so a request
# that died before its end leaves nothing the next one reads (T7), and at the end,
# so nothing is held between requests at all.
#
# Nothing sets it in S2; these requests set it themselves, inside main(), as the
# front door will. Each goes through handle_one_request(), as the accept loop runs
# it, in one process (t/integration/288's harness).
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(setup_test_site site_tempdir repo_root);

my $root    = repo_root();
my $docroot = site_tempdir();
setup_test_site($docroot);

sub spit { open my $fh, '>', $_[0] or die "$_[0]: $!"; print {$fh} $_[1]; close $fh; return }
spit( "$docroot/members.md", "---\ntitle: Members\nauth: required\n---\nMEMBERS WHO=[% auth_user %] NOPW=[% IF no_password %]yes[% ELSE %]no[% END %]\n" );

delete @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED LAZYSITE_AUTH_NO_PASSWORD)};
local $ENV{DOCUMENT_ROOT}  = $docroot;
local $ENV{REQUEST_METHOD} = 'GET';
local $ENV{QUERY_STRING}   = '';
local $ENV{REDIRECT_URL}   = '/__load__';

sub capture {
    my ($code) = @_;
    my $out = "$docroot/out.$$";
    open my $so, '>&', \*STDOUT    or die;
    open my $se, '>&', \*STDERR    or die;
    open STDOUT, '>',  $out        or die;
    open STDERR, '>',  '/dev/null' or die;
    $code->();
    open STDOUT, '>&', $so  or die;
    open STDERR, '>&', $se  or die;
    open my $fh, '<',  $out or die;
    local $/;
    return scalar(<$fh>) // '';
}

capture( sub { do "$root/lazysite-processor.pl"; die $@ if $@ } );

no warnings qw(once redefine);
my $real_main = \&main::main;

# One request through handle_one_request. With $hold, main() first stores that
# value as the front door will (S3), then renders; with $die it then dies.
sub request {
    my ( $uri, %o ) = @_;
    local $ENV{REDIRECT_URL} = $uri;
    local *main::main = sub {
        $o{seen}->($main::REQUEST_IDENT) if $o{seen};
        $main::REQUEST_IDENT = $o{hold} if $o{hold};
        die "a fault after the identity was set\n" if $o{die};
        $real_main->();
    };
    return capture( sub { main::handle_one_request() } );
}

my $ALICE = { user => 'alice', groups => ['staff'], name => '', email => '', sid => 'S-ALICE', no_password => 1, source => 'cookie' };
my $BOB   = { user => 'bob',   groups => [],        name => '', email => '', sid => 'S-BOB',   no_password => 0, source => 'cookie' };

subtest 'a held value is the identity the render reads' => sub {
    my $out = request( '/members', hold => $ALICE );
    like( $out, qr/MEMBERS WHO=alice/, '_request_identity took the held value' );
    like( $out, qr/NOPW=yes/, 'and no_password came from the value, not LAZYSITE_AUTH_NO_PASSWORD' );

    local $ENV{LAZYSITE_AUTH_NO_PASSWORD} = '1';
    my $bob = request( '/members', hold => $BOB );
    like( $bob, qr/MEMBERS WHO=bob NOPW=no/, 'a held value without no_password wins over the environment\'s flag' );
};

subtest 'the value ends with its request' => sub {
    request( '/members', hold => $ALICE );
    ok( !defined $main::REQUEST_IDENT, 'nothing is held between requests (cleared at the end)' );

    my $next = request('/members');
    unlike( $next, qr/MEMBERS WHO=/, 'the next request in the worker, carrying no identity, is not alice' );
    like( $next, qr/^Location:\s*\S*\/login/mi, 'it is anonymous: sent to sign in' );

    my $who = request( '/members', hold => $BOB );
    like( $who, qr/MEMBERS WHO=bob/, 'another account\'s request sees only itself' );
};

subtest 'a request that died leaves nothing for the next (cleared at the start)' => sub {
    request( '/members', hold => $ALICE, die => 1 );
    ok( !defined $main::REQUEST_IDENT, 'the value is gone after a request that died' );

    # As if the end of the previous request never ran (a fault past the eval).
    $main::REQUEST_IDENT = $ALICE;
    my $seen = 'not called';
    my $out  = request( '/members', seen => sub { $seen = $_[0] } );
    ok( !defined $seen, 'the next request starts with nothing held' );
    unlike( $out, qr/MEMBERS WHO=alice/, 'and does not render as alice' );
};

done_testing();
