#!/usr/bin/perl
# SM1149 (OOM Lab L-1): an internal Odoo behind a private CA had no setting. The
# lab set SSL_CERT_FILE for the whole server, which also replaces the system
# store for every other connection the process makes. `odoo_ca_file` is the
# connection's own:
#
#   * optional, and checked once with the rest of the connection: an absolute
#     path to a file this process can read;
#   * handed to OOM as `ssl_ca_file` for every client lazysite builds for Odoo -
#     the connection user's call, a person's session call, sign-in, the identity
#     refresh and sign-out - which gives HTTP::Tiny SSL_ca_file for that client;
#   * never SSL_CERT_FILE or any other variable in %ENV.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);
use OdooTest   qw(oom_or_skip write_conf shop_ready odoo_site);

BEGIN { oom_or_skip() }
use Lazysite::Odoo          ();
use Lazysite::Odoo::Session ();

my ( $d, undef ) = shop_ready();
my $ca = "$d/private-ca.pem";
{
    open my $fh, '>', $ca or die $!;
    print {$fh} "-----BEGIN CERTIFICATE-----\nMIIBplaceholder\n-----END CERTIFICATE-----\n";
    close $fh;
}
my %base = ( odoo_url => 'https://odoo.internal', odoo_db => 'shopdb', odoo_login => 'site-connection' );

sub conn_with {
    my (%extra) = @_;
    write_conf( $d, %base, %extra );
    return Lazysite::Odoo::connection();
}

subtest 'optional, and checked like the rest of the connection' => sub {
    my ($c) = conn_with();
    ok( $c, 'no odoo_ca_file: a connection' );
    ok( !exists $c->{ca_file}, 'with no ca_file' );
    ($c) = conn_with( odoo_ca_file => '' );
    ok( $c && !exists $c->{ca_file}, 'a blank one is the same as none' );
    ($c) = conn_with( odoo_ca_file => $ca );
    is( $c->{ca_file}, $ca, 'a readable file is the connection\'s CA' );

    my ( $none, $why ) = conn_with( odoo_ca_file => "$d/nowhere.pem" );
    ok( !$none, 'a file that is not there: refused' );
    like( $why, qr/odoo_ca_file .*nowhere\.pem' is not a file/, 'by name, with the path' );
    ( $none, $why ) = conn_with( odoo_ca_file => $d );
    like( $why, qr/is not a file/, 'a directory: refused' );
    ( $none, $why ) = conn_with( odoo_ca_file => 'private-ca.pem' );
    like( $why, qr/full path/, 'a relative path (a CGI\'s directory is not the site\'s): refused' );
    SKIP: {
        skip 'root reads anything', 2 if $> == 0;
        my $locked = "$d/locked.pem";
        open my $fh, '>', $locked or die $!;
        close $fh;
        chmod 0000, $locked;
        ( $none, $why ) = conn_with( odoo_ca_file => $locked );
        ok( !$none, 'a file this process cannot read: refused' );
        like( $why, qr/cannot be read by this process/, 'by name' );
    }
};

# What each client OOM is asked to build is given: http_client's arguments, seen
# as lazysite builds the client, with no network (the stand-in dies after noting).
my @seen;
my $REAL_CLIENT;
ok( ( Lazysite::Odoo::oom_check() )[0], 'OOM is here' );    # loads Config, Context and the rest
{
    require Odoo::Transport;
    no warnings 'redefine';
    $REAL_CLIENT = \&Odoo::Transport::http_client;
    *Odoo::Transport::http_client = sub {
        push @seen, {@_};
        die "stopped before any network\n";
    };
}

sub ca_seen {
    my ($code) = @_;
    @seen = ();
    local $Lazysite::Odoo::TRANSPORT;
    local $Lazysite::Odoo::Session::HTTP;
    eval { $code->() };
    return [ map { $_->{ssl_ca_file} } @seen ];
}

subtest 'every client lazysite builds for Odoo carries it, and the environment is left alone' => sub {
    my ($conn) = conn_with( odoo_ca_file => $ca );
    my ($plain) = conn_with();
    local %ENV = %ENV;
    delete $ENV{SSL_CERT_FILE};
    delete $ENV{SSL_CERT_DIR};
    my %before = %ENV;

    is_deeply( ca_seen( sub { Lazysite::Odoo::context( $conn, actor => 'x' ) } ), [$ca], 'the connection user\'s call' );
    is_deeply( ca_seen( sub { Lazysite::Odoo::context( $conn, actor => 'x', session => 'abcdefgh12345678' ) } ), [$ca],
        'a person\'s session call' );
    is_deeply( ca_seen( sub { Lazysite::Odoo::Session::sign_in( $conn, 'a', 'b' ) } ), [$ca], 'sign-in' );
    is_deeply( ca_seen( sub { Lazysite::Odoo::Session::identity_of( $conn, 'abcdefgh12345678' ) } ), [$ca], 'the identity refresh' );
    is_deeply( ca_seen( sub { Lazysite::Odoo::Session::sign_out( $conn, 'abcdefgh12345678' ) } ), [$ca], 'sign-out' );

    is_deeply( ca_seen( sub { Lazysite::Odoo::context( $plain, actor => 'x' ) } ), [undef], 'with none set, none is passed' );
    is_deeply( ca_seen( sub { Lazysite::Odoo::Session::sign_in( $plain, 'a', 'b' ) } ), [undef], 'sign-in too' );

    is_deeply( {%ENV}, \%before, 'no variable was set or changed in the process environment' );
    ok( !exists $ENV{SSL_CERT_FILE} && !exists $ENV{SSL_CERT_DIR}, 'least of all SSL_CERT_FILE' );
};

subtest 'HTTP::Tiny is given it as the client\'s own SSL_ca_file' => sub {
    require HTTP::Tiny;
    my $http = $REAL_CLIENT->( ssl_ca_file => $ca );    # OOM's own constructor, as it stood before the stand-in
    is( $http->{SSL_options}{SSL_ca_file}, $ca, 'in that client\'s SSL options' );
    ok( $http->{verify_SSL}, 'and verification stays on' );
    my $other = HTTP::Tiny->new;
    ok( !$other->{SSL_options}{SSL_ca_file}, 'a client built beside it is untouched' );
};

done_testing;
