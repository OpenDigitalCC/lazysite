#!/usr/bin/perl
# SM1366 (ruling 124): an Odoo call made under a person's Odoo session was recorded
# as `session:<hash>` and nothing else, so an operator reading the audit log could
# not tell who acted. Where the request is signed in to the site
# ($Lazysite::Odoo::SIGNED_IN, set per request by the Odoo endpoint - t/unit/odoo/63
# holds the endpoint to it), the record's `actor` is that account and the hash moves
# to `session`; the audit line names the account with `session=` beside it. With no
# identity the hash stays the actor. A refused sign-in keeps `signin:<hash>`, and
# no login or session id is ever written in clear. The plan a session binding
# makes is still the session's: the account names the record, not the owner.
# Fakes only (OOM's real session transport over a stand-in for HTTP).
use strict;
use warnings;
use Test::More;
use JSON::PP qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(setup_minimal_site);
use OdooTest   qw(oom_or_skip shop_ready bind quiet fake_shop odoo_site);

BEGIN { oom_or_skip() }
use OdooSessionHTTP;
use Lazysite::Odoo          ();
use Lazysite::Odoo::Session ();
use Lazysite::Odoo::Visitor ();

my ( $d, $conn_fake ) = shop_ready();
setup_minimal_site($d);
odoo_site($d);
{
    no warnings 'once';
    $Lazysite::Odoo::Visitor::DOCROOT = $d;
}
my $PW   = 'a-long-enough-Password-77';
my $http = OdooSessionHTTP->new( fake => fake_shop(), people => {
        'jane@example.com' => { password => $PW, uid => 7, name => 'Jane', login => 'jane@example.com' } } );
$Lazysite::Odoo::Session::HTTP = $http;
$Lazysite::Odoo::TRANSPORT     = $conn_fake;

bind( $d, id => 'mine', operation => 'shop.products', credential => 'session', modes => 'authenticated' );
bind( $d, id => 'my-add', operation => 'shop.add', credential => 'session', modes => 'authenticated',
    params => 'product=product', fixed => 'basket_key=mine' );

my ( undef, $si ) = quiet( sub { Lazysite::Odoo::sign_in( login => 'jane@example.com', password => $PW, ip => '192.0.2.7' ) } );
my $JANE = Lazysite::Odoo::Session::sid_from_cookie( 'lzs_odoo_session=' . $si->{cookie} );
ok( $JANE, 'Jane is signed in to Odoo' );
my $HASH = Lazysite::Odoo::Session::session_label($JANE);

sub last_rec {
    my ($binding) = @_;
    return ( grep { ( $_->{binding} // '' ) eq $binding } @{ Lazysite::Odoo::read_calls() } )[0] // {};
}

sub audit_text {
    open my $fh, '<', "$d/lazysite/logs/audit.log" or return '';
    local $/;
    my $t = <$fh>;
    close $fh;
    return $t;
}

sub run_mine {
    my ($as) = @_;
    no warnings 'once';
    local $Lazysite::Odoo::SIGNED_IN = $as;
    my ( undef, $r ) = quiet( sub {
            my ($b) = Lazysite::Odoo::find_binding('mine');
            Lazysite::Odoo::call( $b, {}, mode => 'authenticated', ip => '192.0.2.7', odoo_session => $JANE );
    } );
    return $r;
}

subtest 'a call under a signed-in account names it, with the session hash beside it' => sub {
    my $r = run_mine('odoo:jane@example.com');
    ok( $r->{ok}, 'the call ran' ) or diag explain $r;
    my $rec = last_rec('mine');
    is( $rec->{actor},   'odoo:jane@example.com', 'the record\'s actor is the account' );
    is( $rec->{session}, $HASH,                   '  and its session hash is kept' );
    like( audit_text(), qr/\| odoo:jane\@example\.com \| odoo-call \| mine -> shop\.products \|[^\n]*session=\Q$HASH\E/,
        'the audit line names the account, with session= on the row' );

    my $local = run_mine('alice');
    is( last_rec('mine')->{actor}, 'alice', 'a local account is named as it is everywhere else' );
};

subtest 'a call with no identity keeps the hash as its actor' => sub {
    for my $none ( undef, '' ) {
        run_mine($none);
        my $rec = last_rec('mine');
        is( $rec->{actor}, $HASH, 'the actor is the session hash, as before' );
        ok( !exists $rec->{session}, '  and there is no separate session field' );
    }
};

subtest 'a plan made under an account is still the session\'s' => sub {
    no warnings 'once';
    local $Lazysite::Odoo::SIGNED_IN = 'odoo:jane@example.com';
    my ( undef, $p ) = quiet( sub {
            my ($b) = Lazysite::Odoo::find_binding('my-add');
            Lazysite::Odoo::call( $b, { product => 1 }, mode => 'authenticated', ip => '192.0.2.7', odoo_session => $JANE );
    } );
    ok( $p->{planned}, 'planned' ) or diag explain $p;
    my $meta = do {
        open my $fh, '<', Lazysite::Odoo::plans_dir() . "/$p->{plan}/meta.json" or die $!;
        local $/;
        JSON::PP::decode_json(<$fh>);
    };
    is( $meta->{owner}, $HASH, 'the plan\'s owner is the session hash, unchanged' );
    my ( undef, $c ) = quiet( sub {
            Lazysite::Odoo::confirm( $p->{plan}, mode => 'authenticated', ip => '192.0.2.7', odoo_session => $JANE ) } );
    ok( $c->{ok} || $c->{applied}, 'and the same session confirms it' ) or diag explain $c;
    my ($conf) = grep { ( $_->{binding} // '' ) eq 'my-add' && ( $_->{phase} // '' ) eq 'apply' }
        @{ Lazysite::Odoo::read_calls() };
    is( $conf->{actor}, 'odoo:jane@example.com', 'the confirm\'s record names the account too' );
    is( $conf->{session}, $HASH,                 '  beside the hash' );
};

subtest 'a refused sign-in keeps its login hash, and nothing is in clear' => sub {
    no warnings 'once';
    local $Lazysite::Odoo::SIGNED_IN = 'odoo:jane@example.com';
    my ( undef, $r ) = quiet( sub {
            Lazysite::Odoo::sign_in( login => 'mallory@example.com', password => 'wrong-wrong-wrong-1', ip => '192.0.2.8' ) } );
    ok( !$r->{ok}, 'the sign-in is refused' );
    my ($rec) = grep { ( $_->{actor} // '' ) =~ /\Asignin:/ } @{ Lazysite::Odoo::read_calls() };
    like( $rec->{actor}, qr/\Asignin:[0-9a-f]{16}\z/, 'its actor is the typed login\'s hash' );
    ok( !exists $rec->{session}, '  with no session field' );
    my $all = encode_json( Lazysite::Odoo::read_calls() ) . audit_text();
    unlike( $all, qr/mallory/,   'the typed login is nowhere in clear' );
    unlike( $all, qr/\Q$JANE\E/, 'and no session id is written' );
};

done_testing();
