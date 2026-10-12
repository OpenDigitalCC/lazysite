#!/usr/bin/perl
# SM747 slice A: the connection is the extension's config, and its URL follows
# X4-a - https:// to any host, http:// to loopback only, never plain http:// to
# a private address.
#
# The private-address refusal is its own sentence because it is the case an
# operator with Odoo on an internal network meets, and the remedy (https:// to a
# private hostname, which IS allowed) is what they need to read.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper     qw(site_tempdir);
use OdooTest       qw(write_conf);
use Lazysite::Odoo ();

sub url_ok { is( Lazysite::Odoo::check_url( $_[0] ), '', "$_[0] is allowed" ) }

sub url_no {
    my ( $u, $re, $name ) = @_;
    like( Lazysite::Odoo::check_url($u), $re, $name // "$u is refused" );
}

subtest 'https to any host, http to loopback' => sub {
    url_ok('https://odoo.example');
    url_ok('https://odoo.internal:8069/');
    url_ok('https://10.0.0.5');    # https to a private address is the allowed form
    url_ok('http://127.0.0.1:8069');
    url_ok('http://localhost:8069/');
    url_ok('http://[::1]:8069');
};

subtest 'X4-a: no plain http to an RFC1918 address, said as such' => sub {
    for my $u (qw(http://10.1.2.3 http://172.16.0.9:8069 http://172.31.255.1 http://192.168.1.20/)) {
        url_no( $u, qr/private address .* refused \(X4-a\).*https:\/\/ to its private hostname/s );
    }
};

subtest 'every other http is refused, and so is anything not a plain URL' => sub {
    url_no( 'http://172.32.0.1', qr/only to this host/, 'just outside 172.16/12 is not private, still http' );
    url_no( 'http://odoo.internal', qr/only to this host/, 'a hostname over http is refused' );
    url_no( 'http://8.8.8.8',       qr/only to this host/ );
    url_no( 'https://user:pw@odoo.example', qr/no user or password/, 'credentials in the URL are refused' );
    url_no( "https://odoo.example\nx", qr/one line/ );
    url_no( 'ftp://odoo.example',      qr/must look like/ );
    url_no( '',                        qr/required/ );
};

subtest 'the connection is read and checked once' => sub {
    my $d = site_tempdir();
    local $Lazysite::Odoo::DOCROOT = $d;

    my ( $c, $why ) = Lazysite::Odoo::connection();
    like( $why, qr/odoo_url is required/, 'no config names the first missing key' );

    write_conf( $d, odoo_url => 'https://odoo.example/', odoo_db => 'db1', odoo_login => 'conn' );
    ( $c, $why ) = Lazysite::Odoo::connection();
    ok( $c, 'a minimal connection is accepted' ) or diag($why);
    is( $c->{url},          'https://odoo.example', 'the trailing slash is dropped' );
    is( $c->{timeout},      30,                     'timeout defaults' );
    is( $c->{max_kb},       2048,                   'the answer cap defaults' );
    is( $c->{allow_writes}, 0,                      'writes are OFF unless said' );

    my %bad = (
        'odoo_db is required'           => { odoo_db      => '' },
        'odoo_db must be letters'       => { odoo_db      => 'a b' },
        'odoo_login is required'        => { odoo_login   => '' },
        'odoo_timeout must be 1 to 120' => { odoo_timeout => 0 },
        'odoo_timeout must be a whole'  => { odoo_timeout => 'soon' },
        'odoo_max_kb must be 16'        => { odoo_max_kb  => 70000 },
        "odoo_packs: 'x;y'"             => { odoo_packs   => 'x;y' },
        'private address'               => { odoo_url     => 'http://192.168.0.2' },
    );
    for my $want ( sort keys %bad ) {
        write_conf( $d, odoo_url => 'https://odoo.example', odoo_db => 'db1',
            odoo_login => 'conn', %{ $bad{$want} } );
        my ( $cc, $w ) = Lazysite::Odoo::connection();
        ok( !$cc, "refused: $want" );
        like( $w, qr/\Q$want\E/, 'and says which' );
    }

    write_conf( $d, odoo_url => 'https://odoo.example', odoo_db => 'db1', odoo_login => 'conn',
        odoo_allow_writes => 'yes', odoo_packs => 'My::Pack, Other::Ops' );
    ($c) = Lazysite::Odoo::connection();
    is( $c->{allow_writes}, 1, 'writes on when said' );
    is_deeply( $c->{packs}, [ 'My::Pack', 'Other::Ops' ], 'packs are a list of namespaces' );
};

subtest 'an unreadable config is not an empty one' => sub {
    plan skip_all => 'root reads anything' if $> == 0;
    my $d = site_tempdir();
    local $Lazysite::Odoo::DOCROOT = $d;
    write_conf( $d, odoo_url => 'https://odoo.example', odoo_db => 'db1', odoo_login => 'conn' );
    chmod 0000, "$d/lazysite/odoo.conf";
    my ( $c, $why ) = Lazysite::Odoo::connection();
    chmod 0644, "$d/lazysite/odoo.conf";
    ok( !$c, 'refused' );
    like( $why, qr/cannot be read/, 'as unreadable, not as unconfigured' );
};

done_testing();
