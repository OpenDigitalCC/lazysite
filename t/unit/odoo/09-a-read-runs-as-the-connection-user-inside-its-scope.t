#!/usr/bin/perl
# SM747 CU: a read operation runs as the connection user, inside the scope its
# operation declares, and hands back its report. OOM's Guard refuses a call
# outside the scope BEFORE it leaves (outcome 13); Odoo's own refusal of the
# connection user comes back as odoo-access-refused, told apart from a
# transport failure (outcome 3). Each is one record naming the actor, and OOM's
# own audit names the same actor.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use OdooTest qw(oom_or_skip shop_ready bind quiet fake_shop);

BEGIN { oom_or_skip() }
use Odoo::Error;
use Lazysite::Odoo ();

my ( $d, $fake ) = shop_ready();
bind( $d, id => 'list', operation => 'shop.products', modes => 'public', params => 'n=limit' );
bind( $d, id => 'peek', operation => 'shop.peek', modes => 'public' );

sub run_binding {
    my ( $id, $input, %ctx ) = @_;
    my ( $log, $r ) = quiet( sub {
            my ( $b, $why ) = Lazysite::Odoo::find_binding($id);
            return { ok => 0, kind => 'lookup', error => $why } unless $b;
            Lazysite::Odoo::call( $b, $input, mode => 'public', ip => '192.0.2.4', strict => 1, %ctx );
    } );
    return $r;
}

sub last_record {
    open my $fh, '<', Lazysite::Odoo::calls_file() or return {};
    my @l = <$fh>;
    close $fh;
    return decode_json( $l[-1] );
}

subtest 'a public listing' => sub {
    my $r = run_binding( 'list', { n => 1 } );
    ok( $r->{ok}, 'answered' ) or diag explain $r;
    is( scalar @{ $r->{report}{rows} }, 1, 'the request\'s limit reached the operation as an int' );
    is( $r->{report}{rows}[0]{name}, 'Tea', 'with Odoo\'s rows' );
    my $rec = last_record();
    is( $rec->{outcome},   'answered',        'recorded as answered' );
    is( $rec->{login},     'site-connection', 'naming the connection user' );
    is( $rec->{mode},      'public',          'and the mode' );
    is( $rec->{operation}, 'shop.products',   'and the operation' );
};

subtest 'outside its declared scope, nothing leaves' => sub {
    my $before = scalar @{ $fake->object_calls };
    my $r      = run_binding('peek');
    is( $r->{kind}, 'scope-refused', 'the Guard\'s refusal is named' );
    my @basket = grep { $_->[5] eq 'x.basket' } @{ $fake->object_calls };
    is( scalar @basket,           0, 'no call on the undeclared model reached Odoo' );
    is( last_record()->{outcome}, 'refused', 'recorded as refused' );
};

subtest 'a request field the binding does not map is refused by name' => sub {
    my $r = run_binding( 'list', { n => 1, order => 'price desc' } );
    is( $r->{kind}, 'invalid', 'invalid' );
    like( $r->{error}, qr/does not take: order/, 'naming the field' );
};

subtest 'Odoo refusing the connection user is not a transport failure' => sub {
    $Lazysite::Odoo::TRANSPORT = fake_shop( fake => { fail => {
                'x.product.search_read' => Odoo::Error->new( kind => 'fault',
                    fault_class => 'odoo.exceptions.AccessError', message => 'secret detail' ) } } );
    my $r = run_binding('list');
    is( $r->{kind}, 'odoo-access-refused', 'odoo-access-refused' );
    unlike( $r->{error}, qr/secret detail/, 'Odoo\'s text is not handed on' );
    is( last_record()->{outcome}, 'odoo-fault', 'recorded as an Odoo fault' );

    $Lazysite::Odoo::TRANSPORT = fake_shop( fake => { fail => {
                'x.product.search_read' => Odoo::Error->new( kind => 'transport', message => 'connect refused' ) } } );
    $r = run_binding('list');
    is( $r->{kind}, 'transport-failure',        'a transport failure is its own kind' );
    is( last_record()->{outcome}, 'unanswered', 'recorded as unanswered' );
    $Lazysite::Odoo::TRANSPORT = $fake;
};

subtest 'without the key, nothing is attempted' => sub {
    unlink "$d/lazysite/odoo/keys/connection.key";
    my $before = scalar @{ $fake->calls };
    my $r      = run_binding('list');
    is( $r->{kind},               'no-key', 'refused for the missing key' );
    is( scalar @{ $fake->calls }, $before,  'and Odoo heard nothing' );
};

subtest 'OOM\'s audit names the same actor' => sub {
    OdooTest::set_key($d);
    my ($b) = Lazysite::Odoo::find_binding('list');
    my ($c) = Lazysite::Odoo::connection();
    my $ctx = Lazysite::Odoo::context( $c, actor => 'visitor:abc' );
    is( $ctx->actor, 'visitor:abc', 'the context carries the lazysite actor to OOM\'s Guard' );
};

done_testing();
