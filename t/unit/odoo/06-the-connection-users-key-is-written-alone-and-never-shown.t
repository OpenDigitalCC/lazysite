#!/usr/bin/perl
# SM747 CU / OB1 as amended (R1) / outcome 4 as amended: the connection user's
# API key is the ONE Odoo credential lazysite stores. It is written alone into
# its own 0600 file, never returned, never logged, and has_secret answers 1, 0
# or null for "cannot tell". The inspection half of outcome 4: after a full call
# the key is in that file and in no other file under the site.
use strict;
use warnings;
use Test::More;
use File::Find ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);
use OdooTest   qw(oom_or_skip shop_ready bind quiet shop_namespace);

BEGIN { oom_or_skip() }
use Lazysite::Odoo         ();
use Lazysite::Odoo::Secret ();

subtest 'set, read the state of, clear' => sub {
    my $d = site_tempdir();
    local $Lazysite::Odoo::Secret::DOCROOT = $d;
    is( Lazysite::Odoo::Secret::has_key('connection'), 0, 'no key: 0' );
    my ( $ok, $why ) = quiet( sub { Lazysite::Odoo::Secret::set_key( 'connection', 'abc123XYZ' ) } );
    ok( ( Lazysite::Odoo::Secret::set_key( 'connection', 'abc123XYZ' ) )[0], 'set' );
    is( Lazysite::Odoo::Secret::has_key('connection'), 1, 'has_secret: 1' );
    my $p    = Lazysite::Odoo::Secret::key_path('connection');
    my $mode = ( stat $p )[2] & 07777;
    is( sprintf( '%04o', $mode ), '0600', 'the key file is 0600' );
    ok( ( Lazysite::Odoo::Secret::clear_key('connection') )[0], 'cleared' );
    ok( !-e $p,                                                 'and gone' );
    ok( ( Lazysite::Odoo::Secret::clear_key('connection') )[0], 'clearing nothing is not an error' );

    for my $bad ( "two\nlines", '', 'has space', 'x' x 513 ) {
        my ( $k, $w ) = Lazysite::Odoo::Secret::set_key( 'connection', $bad );
        ok( !$k, 'refused: ' . substr( $bad =~ s/\n/\\n/r, 0, 12 ) );
        unlike( $w, qr/\Q$bad\E/, 'and the refusal does not echo it' ) if length $bad > 3;
    }
    ok( !( Lazysite::Odoo::Secret::set_key( '../x', 'k' ) )[0], 'an account name cannot step out' );
};

subtest 'a key that exists and cannot be read is null, not 0' => sub {
    plan skip_all => 'root reads anything' if $> == 0;
    my $d = site_tempdir();
    local $Lazysite::Odoo::Secret::DOCROOT = $d;
    Lazysite::Odoo::Secret::set_key( 'connection', 'abc' );
    my $p = Lazysite::Odoo::Secret::key_path('connection');
    chmod 0000, $p;
    my ( undef, $has ) = quiet( sub { Lazysite::Odoo::Secret::has_key('connection') } );
    chmod 0600, $p;
    is( $has, undef, 'cannot tell' );
};

subtest 'after a full call the key is in its file and nowhere else' => sub {
    my ( $d, $fake ) = shop_ready();
    my $KEY = 'Zq9-unique-key-material-77';
    {
        local $Lazysite::Odoo::Secret::DOCROOT = $d;
        Lazysite::Odoo::Secret::set_key( 'connection', $KEY );
    }
    bind( $d, id => 'list', operation => 'shop.products', modes => 'public' );
    my ( $log, $r ) = quiet( sub {
            my ($b) = Lazysite::Odoo::find_binding('list');
            Lazysite::Odoo::call( $b, {}, mode => 'public', ip => '192.0.2.9' );
    } );
    ok( $r->{ok}, 'the call ran' ) or diag explain $r;
    my $sent = grep { grep { defined && !ref && $_ eq $KEY } @$_ } @{ $fake->calls };
    ok( $sent, 'the key reached Odoo - it is the credential' );
    unlike( $log,                      qr/\Q$KEY\E/, 'it is in no log line' );
    unlike( JSON::PP::encode_json($r), qr/\Q$KEY\E/, 'nor in the answer' );

    my @holding;
    File::Find::find( sub {
            return unless -f $_;
            open my $fh, '<', $_ or return;
            my $c = do { local $/; <$fh> };
            push @holding, $File::Find::name if index( $c, $KEY ) >= 0;
    }, $d );
    is_deeply( [ map { s{\A\Q$d\E/}{}r } @holding ], ['lazysite/odoo/keys/connection.key'],
        'the only file under the site holding it is its own' );
};

done_testing();
