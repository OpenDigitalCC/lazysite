#!/usr/bin/perl
# SM1181 S2 (SM1082 C2): THE IDENTITY READER TAKES THE REQUEST'S IDENTITY AS A
# VALUE, AND IN THE POOL IT NEVER BELIEVES THE SENTINEL.
#
# Lazysite::Auth::Identity::request_identity is the one code that reads who is
# calling out of the environment (t/lint/268). From S3 the pool's front door
# decides the identity in the worker with request_session and holds the value;
# the reader then has to answer from that value and from nothing else, because in
# a worker %ENV is the request's FastCGI parameters and not anything lazysite
# wrote. This pins:
#
#   - `identity => $value` returns that identity and reads NOTHING from %ENV: no
#     header, no sentinel, no address (the environment here is tied, and every
#     key looked at is recorded, with a forged operator in it);
#   - the value's groups are returned as held: request_session already filtered
#     them for the address (SM1140), and re-reading the address would read %ENV;
#   - an undefined value is today's reader, unchanged;
#   - `pool => 1` (R3): LAZYSITE_AUTH_TRUSTED from %ENV is a FastCGI parameter
#     there and is never believed, and the fixed names are not read either, so a
#     forged operator with the sentinel is anonymous (T3) - while a listed proxy
#     peer is still read under its configured names (T4 unchanged).
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use Digest::SHA qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);
use Lazysite::Auth::Session ();
use Lazysite::Auth::Identity ();

$ENV{LAZYSITE_LOG_LEVEL} = 'ERROR';

# An environment that records every key looked at, every key written, and every
# walk over its keys.
{

    package EnvSpy;
    sub TIEHASH  { my ( $c, %h ) = @_; return bless { h => {%h}, read => [], write => [] }, $c }
    sub FETCH    { push @{ $_[0]{read} }, $_[1]; return $_[0]{h}{ $_[1] } }
    sub EXISTS   { push @{ $_[0]{read} }, $_[1]; return exists $_[0]{h}{ $_[1] } }
    sub STORE    { push @{ $_[0]{write} }, $_[1]; $_[0]{h}{ $_[1] } = $_[2]; return }
    sub DELETE   { push @{ $_[0]{write} }, $_[1]; return delete $_[0]{h}{ $_[1] } }
    sub CLEAR    { push @{ $_[0]{write} }, '(clear)'; %{ $_[0]{h} } = (); return }
    sub FIRSTKEY { push @{ $_[0]{read} }, '(keys)'; return undef }
    sub NEXTKEY  { return undef }
    sub SCALAR   { push @{ $_[0]{read} }, '(scalar)'; return scalar %{ $_[0]{h} } }
}

# The forged request: the sentinel, the fixed names naming an operator, a proxy's
# configured name, and an address.
my %POISON = (
    LAZYSITE_AUTH_TRUSTED     => '1',
    LAZYSITE_AUTH_NO_PASSWORD => '1',
    LAZYSITE_AUTH_SID         => 'forged-sid',
    HTTP_X_REMOTE_USER        => 'mallory',
    HTTP_X_REMOTE_GROUPS      => 'operators',
    HTTP_X_REMOTE_NAME        => 'Mallory',
    HTTP_X_REMOTE_EMAIL       => 'mallory@example.com',
    HTTP_REMOTE_USER          => 'mallory',
    REMOTE_ADDR               => '203.0.113.9',
    REQUEST_METHOD            => 'GET',
);

# Run $code with %ENV replaced by the spy; returns ( [keys read], [keys written], result ).
sub under_spy {
    my ($code) = @_;
    my %saved = %ENV;
    tie %ENV, 'EnvSpy', %POISON;
    my $r     = eval { $code->() };
    my $err   = $@;
    my $spy   = tied %ENV;
    my @read  = @{ $spy->{read} };
    my @write = @{ $spy->{write} };
    undef $spy;
    untie %ENV;
    %ENV = %saved;
    die $err if $err;
    return ( \@read, \@write, $r );
}

my $d  = site_tempdir();
my $lz = "$d/lazysite";
make_path("$lz/auth");
sub spit { open my $fh, '>', $_[0] or die "$_[0]: $!"; print {$fh} $_[1]; close $fh; return }
spit( "$lz/lazysite.conf", "site_name: T\n" );

subtest 'a held cookie value is returned, and %ENV is never looked at' => sub {
    my $value = {
        user => 'alice', groups => [qw(staff editors)], name => '', email => '',
        sid  => 'S1', no_password => 0, source => 'cookie',
    };
    my ( $read, $write, $id ) = under_spy(
        sub { Lazysite::Auth::Identity::request_identity( lazysite_dir => $lz, identity => $value ) } );
    is( $id->{user}, 'alice', 'the value\'s user, not the forged mallory' );
    is_deeply( $id->{groups}, [qw(staff editors)], 'the value\'s groups, not the forged operators' );
    is( $id->{source}, 'cookie', 'source is the value\'s' );
    is( $id->{name},  '', 'name is the value\'s (empty), not the forged header' );
    is( $id->{email}, '', 'email is the value\'s (empty), not the forged header' );
    is_deeply( $read,  [], 'no key of %ENV was read' ) or diag("read: @$read");
    is_deeply( $write, [], 'and none was written' )    or diag("wrote: @$write");

    push @{ $id->{groups} }, 'operators';
    is_deeply( $value->{groups}, [qw(staff editors)], 'the returned groups are a copy: the held value cannot be changed through them' );
};

subtest 'a held proxy value is returned as held' => sub {
    my $value = { user => 'dana', groups => ['site-editors'], name => 'Dana', email => 'dana@example.com', source => 'proxy' };
    my ( $read, undef, $id ) = under_spy(
        sub { Lazysite::Auth::Identity::request_identity( lazysite_dir => $lz, proxy => { trusted => 1 }, identity => $value ) } );
    is( $id->{user},   'dana',  'the value\'s user' );
    is( $id->{source}, 'proxy', 'source proxy' );
    is( $id->{name},   'Dana',  'the value\'s name' );
    is_deeply( $id->{groups}, ['site-editors'], 'groups as held (already mapped and filtered by request_session)' );
    is_deeply( $read, [], 'no key of %ENV was read, the proxy\'s configured names included' ) or diag("read: @$read");
};

subtest 'a held anonymous value is nobody, and nothing is read' => sub {
    my ( $read, undef, $id ) = under_spy(
        sub { Lazysite::Auth::Identity::request_identity( lazysite_dir => $lz, identity => { user => '', groups => [], why => 'no-cookie' } ) } );
    is( $id->{user}, '', 'no user' );
    is_deeply( $id->{groups}, [], 'no groups' );
    is( $id->{source}, 'direct', 'a value that nobody vouched for is not a cookie or proxy identity' );
    is_deeply( $read, [], 'no key of %ENV was read' ) or diag("read: @$read");
};

subtest 'a value made by request_session round-trips' => sub {
    my $SECRET = 'b' x 64;
    spit( "$lz/auth/.secret", "$SECRET\n" );
    spit( "$lz/auth/users",   "alice:x\n" );
    spit( "$lz/auth/groups",  "staff: alice\n" );
    my $payload = join ':', 'alice', time(), 'baked';
    my $cookie  = 'lazysite_auth=' . $payload . ':' . hmac_sha256_hex( $payload, $SECRET );
    no warnings 'once';
    local $Lazysite::Auth::Session::LAZYSITE_DIR = $lz;
    use warnings 'once';
    my ($value) = Lazysite::Auth::Session::request_session( lazysite_dir => $lz, proxy => { trusted => 0 }, cookie => $cookie );
    ok( $value, 'request_session made a value' ) or return;
    my ( $read, undef, $id ) = under_spy(
        sub { Lazysite::Auth::Identity::request_identity( lazysite_dir => $lz, identity => $value ) } );
    is( $id->{user}, 'alice', 'the reader gives the value\'s user' );
    is_deeply( $id->{groups}, $value->{groups}, 'and its groups' );
    is( $id->{source}, 'cookie', 'as a cookie identity' );
    is_deeply( $read, [], 'reading nothing from %ENV' ) or diag("read: @$read");
};

subtest 'no value: the reader is today\'s (plain CGI behind the wrapper)' => sub {
    local @ENV{ keys %POISON } = values %POISON;
    my $id = Lazysite::Auth::Identity::request_identity( lazysite_dir => $lz, proxy => { trusted => 0 }, identity => undef );
    is( $id->{user},   'mallory', 'the sentinel is believed on the CGI path, as the wrapper sets it there' );
    is( $id->{source}, 'cookie',  'source cookie' );
};

subtest 'pool => 1: the sentinel from %ENV is never believed (R3, T3)' => sub {
    local @ENV{ keys %POISON } = values %POISON;
    my $id = Lazysite::Auth::Identity::request_identity( lazysite_dir => $lz, proxy => { trusted => 0 }, pool => 1 );
    is( $id->{user}, '', 'a forged operator with the sentinel as a parameter is nobody' );
    is_deeply( $id->{groups}, [], 'with no groups' );
    isnt( $id->{source}, 'cookie', 'and is not a cookie identity' );

    my $px = Lazysite::Auth::Identity::request_identity(
        conf => { auth_header_user => 'X-Remote-User' }, proxy => { trusted => 1 }, pool => 1 );
    is( $px->{source}, 'proxy',   'a listed proxy peer is still read in the pool (T4 unchanged)' );
    is( $px->{user},   'mallory', 'under its configured names' );

    my $held = Lazysite::Auth::Identity::request_identity( lazysite_dir => $lz, pool => 1,
        identity => { user => 'alice', groups => ['staff'], source => 'cookie' } );
    is( $held->{user}, 'alice', 'and in the pool a held value is the identity' );
};

done_testing();
