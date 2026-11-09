#!/usr/bin/perl
# SM297: A SURFACE CONVERTED TO IDENTITY-AS-A-VALUE IS ANSWERED THE VALUE IT HOLDS,
# AND NOTHING IN %ENV CHANGES THAT.
#
# Lazysite::Auth::Identity::request_identity is the one accessor every reader asks.
# A converted surface decides who is calling once (request_session) and holds the
# answer in $Lazysite::Auth::Identity::HELD for its request. This pins the accessor:
#
#   - while a value is held, the fixed X-Remote-* names, the wrapper's sentinel and
#     a trusted proxy's configured names in %ENV have no effect - whether they came
#     with the request or were written in the process after the value was decided;
#   - an anonymous value is anonymous whatever %ENV says;
#   - a caller naming its own `identity` (the processor's $REQUEST_IDENT, or undef
#     to read the request) is answered that, not the held value;
#   - request_session, which DECIDES the value, reads the request, never a held one;
#   - the hold ends with its scope: the CGI header path is unchanged outside it.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);
use Lazysite::Auth::Identity ();
use Lazysite::Auth::Session  ();

$ENV{LAZYSITE_LOG_LEVEL} = 'ERROR';

my $d  = site_tempdir();
my $lz = "$d/lazysite";
make_path("$lz/auth");
sub spit { open my $fh, '>', $_[0] or die "$_[0]: $!"; print {$fh} $_[1]; close $fh; return }
spit( "$lz/lazysite.conf",
    "site_name: T\nauth_proxy_trusted: true\nauth_proxy_trusted_from: 10.0.0.0/8\n"
        . "auth_header_user: X-Directory-User\nauth_header_groups: X-Directory-Groups\n" );
spit( "$lz/auth/.secret", ( 'a' x 64 ) . "\n" );
spit( "$lz/auth/users",   "alice:x\n" );

my %FORGED = (
    HTTP_X_REMOTE_USER       => 'mallory',
    HTTP_X_REMOTE_GROUPS     => 'admins',
    HTTP_X_REMOTE_NAME       => 'Mallory',
    HTTP_X_REMOTE_EMAIL      => 'm@example.com',
    LAZYSITE_AUTH_TRUSTED    => '1',
    HTTP_X_DIRECTORY_USER    => 'mallory',
    HTTP_X_DIRECTORY_GROUPS  => 'admins',
);
my $ALICE = { user => 'alice', groups => ['staff'], name => '', email => '', sid => 's1',
    no_password => 0, provider => '', stale => 0, source => 'cookie' };
my $ANON = { user => '', groups => [], name => '', email => '', sid => '', no_password => 0,
    provider => '', stale => 0, source => 'anonymous' };
my $UNTRUSTED = { trusted => 0 };
my $TRUSTED   = { trusted => 1, flag => 1, state => 'listed', peer => '10.1.2.3' };

sub ask { return Lazysite::Auth::Identity::request_identity( lazysite_dir => $lz, @_ ) }

subtest 'a held cookie value is the answer, whatever the request sent' => sub {
    local %ENV = ( %ENV, %FORGED, REMOTE_ADDR => '203.0.113.9' );
    local $Lazysite::Auth::Identity::HELD = $ALICE;
    for my $proxy ( $UNTRUSTED, $TRUSTED ) {
        my $id = ask( proxy => $proxy );
        is( $id->{user}, 'alice', 'the held user, not the forged one (proxy ' . ( $proxy->{trusted} ? 'trusted' : 'untrusted' ) . ')' );
        is_deeply( $id->{groups}, ['staff'], 'and the held groups' );
        is( $id->{source}, 'cookie', 'with the held source' );
        is( $id->{name}, '', 'and no forged name' );
    }
};

subtest 'and whatever the process writes after it was decided' => sub {
    local $Lazysite::Auth::Identity::HELD = $ALICE;
    local %ENV = %ENV;
    $ENV{$_} = $FORGED{$_} for keys %FORGED;    # an in-process write, mid-request
    is( ask( proxy => $UNTRUSTED )->{user}, 'alice', 'an identity written into %ENV is not read' );
};

subtest 'a held anonymous value is anonymous' => sub {
    local %ENV = ( %ENV, %FORGED );
    local $Lazysite::Auth::Identity::HELD = $ANON;
    my $id = ask( proxy => $TRUSTED );
    is( $id->{user}, '', 'no user, though the sentinel and both header sets name one' );
    is_deeply( $id->{groups}, [], 'and no groups' );
    is( $id->{source}, 'direct', 'an anonymous value reads as direct' );
};

subtest 'a held value is a copy: a reader cannot change it for the next' => sub {
    local $Lazysite::Auth::Identity::HELD = { %$ALICE, groups => ['staff'] };
    push @{ ask( proxy => $UNTRUSTED )->{groups} }, 'admins';
    is_deeply( ask( proxy => $UNTRUSTED )->{groups}, ['staff'], 'the next reader is answered the held groups' );
};

subtest 'a caller that names its own identity is answered that' => sub {
    local %ENV = ( %ENV, %FORGED );
    local $Lazysite::Auth::Identity::HELD = $ALICE;
    is( ask( proxy => $UNTRUSTED, identity => { %$ALICE, user => 'bob' } )->{user}, 'bob',
        'an explicit value wins over the held one' );
    is( ask( proxy => $UNTRUSTED, identity => undef )->{user}, 'mallory',
        'identity => undef reads the request, as the CGI header path does (here: the forged sentinel)' );
};

subtest 'request_session decides from the request, never from a held value' => sub {
    local %ENV = ( %ENV, HTTP_X_DIRECTORY_USER => 'carol', HTTP_X_DIRECTORY_GROUPS => 'staff' );
    delete local $ENV{LAZYSITE_AUTH_TRUSTED};
    local $Lazysite::Auth::Identity::HELD = $ALICE;
    my ($v) = Lazysite::Auth::Session::request_session( lazysite_dir => $lz, proxy => $TRUSTED, cookie => '' );
    is( ref $v ? $v->{user} : '', 'carol', 'a trusted proxy\'s user is read from its headers' );
    is( ref $v ? $v->{source} : '', 'proxy', 'as a proxy identity' );
};

subtest 'the hold ends with its scope: outside it the CGI path reads as before' => sub {
    {
        local $Lazysite::Auth::Identity::HELD = $ALICE;
        is( ask( proxy => $UNTRUSTED )->{user}, 'alice', 'inside, the held value' );
    }
    ok( !defined $Lazysite::Auth::Identity::HELD, 'nothing is held after the scope' );
    local %ENV = ( %ENV, HTTP_X_REMOTE_USER => 'wrapped', HTTP_X_REMOTE_GROUPS => 'staff', LAZYSITE_AUTH_TRUSTED => '1' );
    my $id = ask( proxy => $UNTRUSTED );
    is( $id->{user},   'wrapped', 'the wrapper\'s contract is read on the CGI path, unchanged' );
    is( $id->{source}, 'cookie',  'as a wrapper-vouched identity' );
};

done_testing();
