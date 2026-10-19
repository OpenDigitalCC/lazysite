#!/usr/bin/perl
# SM1181 S3 (SM1082 C2), RULING R4: WHILE AN IDENTITY VALUE IS HELD,
# apply_trust_gate STRIPS EVERY IDENTITY AND PAYMENT HEADER A CLIENT SENT,
# WHATEVER THE SENTINEL SAYS.
#
# On plain CGI the sentinel LAZYSITE_AUTH_TRUSTED=1 is the auth wrapper's word
# that it verified a cookie and wrote the fixed X-Remote-* headers itself, and
# the gate keeps them. Once the request's identity is a value ($REQUEST_IDENT,
# held by the pool's front door), no header is the identity: every reader takes
# the value, and the gate strips the fixed names, the custom auth_header_* and
# payment_header_* names, and the payment headers, and logs the attempt - so
# nothing downstream can read a client's header even by mistake. A listed proxy
# peer is the proxy's (SM1129) and is left as it was.
#
# In the pool the sentinel is never believed at all (R3, t/integration/291), so
# this is shown where the sentinel IS believed: in one process on the CGI path
# (t/integration/288's harness), a value held the way the front door holds it,
# with the sentinel and forged headers in the environment. Without R4 the gate
# returns at the sentinel and a forged payment header opens a paid page.
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
spit( "$docroot/members.md", "---\ntitle: Members\nauth: required\n---\nMEMBERS WHO=[% auth_user %]\n" );
spit( "$docroot/paid.md",    "---\ntitle: Paid\npayment: required\npayment_amount: 1\n---\nPAID BODY\n" );

delete @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED LAZYSITE_AUTH_NO_PASSWORD)};
local $ENV{DOCUMENT_ROOT}  = $docroot;
local $ENV{REQUEST_METHOD} = 'GET';
local $ENV{QUERY_STRING}   = '';
local $ENV{REDIRECT_URL}   = '/__load__';

my $ERR = "$docroot/err.$$";

sub capture {
    my ($code) = @_;
    my $out = "$docroot/out.$$";
    open my $so, '>&', \*STDOUT or die;
    open my $se, '>&', \*STDERR or die;
    open STDOUT, '>', $out  or die;
    open STDERR, '>', $ERR  or die;
    $code->();
    open STDOUT, '>&', $so  or die;
    open STDERR, '>&', $se  or die;
    open my $fh, '<', $out or die;
    local $/;
    return scalar(<$fh>) // '';
}
sub err { open my $fh, '<', $ERR or return ''; local $/; return scalar <$fh> // '' }

capture( sub { do "$root/lazysite-processor.pl"; die $@ if $@ } );

no warnings qw(once redefine);
my $real_main = \&main::main;

sub request {
    my ( $uri, %o ) = @_;
    local $ENV{REDIRECT_URL} = $uri;
    local @ENV{ keys %{ $o{env} || {} } } = values %{ $o{env} || {} };
    local *main::main = sub {
        $main::REQUEST_IDENT = $o{hold} if $o{hold};
        $real_main->();
    };
    return capture( sub { main::handle_one_request() } );
}

my $BOB = { user => 'bob', groups => [], name => '', email => '', sid => 'S-BOB', no_password => 0, source => 'cookie' };
my %FORGED = (
    LAZYSITE_AUTH_TRUSTED   => '1',
    HTTP_X_REMOTE_USER      => 'operator',
    HTTP_X_REMOTE_GROUPS    => 'operators',
    HTTP_X_PAYMENT_VERIFIED => '1',
    HTTP_X_PAYMENT_PAYER    => '0xforged',
);

subtest 'the fixture tells the two apart: with no value held the sentinel is believed' => sub {
    my $out = request( '/members', env => \%FORGED );
    like( $out, qr/MEMBERS WHO=operator/, 'the wrapper\'s contract on CGI: the sentinel and the header' );
};

subtest 'R4: a held value, the sentinel and forged headers' => sub {
    my $out = request( '/members', hold => $BOB, env => \%FORGED );
    like( $out, qr/MEMBERS WHO=bob\b/, 'the identity is the value' );
    like( err(), qr/untrusted auth header ignored/, 'the forged X-Remote-User is stripped and logged, the sentinel notwithstanding' );

    my $paid = request( '/paid', hold => $BOB, env => \%FORGED );
    unlike( $paid, qr/PAID BODY/, 'a forged X-Payment-Verified does not open a paid page' );
    like( err(), qr/untrusted payment header ignored/, 'it is stripped and logged' );
};

subtest 'the fixture tells the two apart on the paid page too' => sub {
    like( request( '/paid', env => \%FORGED ), qr/PAID BODY/,
        'with no value held, the sentinel keeps the forged payment header on CGI (the wrapper\'s contract)' );
};

done_testing();
