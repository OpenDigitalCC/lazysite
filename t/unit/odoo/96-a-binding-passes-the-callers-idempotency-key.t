#!/usr/bin/perl
# SM1223 (ruling 2026-10-20, "OOM Lab questions": "build the pass-through (page-chosen
# key -> OOM idem, scoped to binding and person, format-checked, recorded)"). The OOM
# Lab's expense app queues writes offline and flushes them on reconnect; a flush that
# is interrupted and sent again must not write twice.
#
# A caller sends `Idempotency-Key` (one call per request). The engine checks its
# format, hashes it with the binding and WHO sent it into the key OOM holds, and a
# repeat answers as OOM answers one: the first result, nothing sent to Odoo again.
#
# This file: the in-process path, on OOM's fake Odoo, and the endpoint's header.
# t/unit/odoo/97 holds the same through the real oomd.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root setup_minimal_site);
use OdooTest   qw(oom_or_skip shop_ready bind quiet odoo_site);

BEGIN { oom_or_skip() }
use Lazysite::Odoo          ();
use Lazysite::Odoo::Visitor ();

my $root = repo_root();
my ( $d, $fake ) = shop_ready( shop => { records => { 'x.basket' => [] } } );
setup_minimal_site($d);
odoo_site($d);
{
    no warnings 'once';
    $Lazysite::Odoo::Visitor::DOCROOT = $d;
}

bind( $d, id => 'imm', operation => 'shop.add', modes => 'public,authenticated', callers => 'staff',
    apply => 'immediate', params => 'product=product', fixed => 'basket_key=counter' );
bind( $d, id => 'imm2', operation => 'shop.add', modes => 'public,authenticated', callers => 'staff',
    apply => 'immediate', params => 'product=product', fixed => 'basket_key=counter' );
bind( $d, id => 'later', operation => 'shop.add', modes => 'authenticated', callers => 'staff',
    params => 'product=product', fixed => 'basket_key=counter' );
bind( $d, id => 'reads', operation => 'shop.products', modes => 'public,authenticated', callers => 'staff' );

my %SAM = ( mode => 'authenticated', actor => 'sam', groups => ['staff'], caps => {}, ip => '192.0.2.5' );
my %ALICE = ( mode => 'authenticated', actor => 'alice', groups => ['staff'], caps => {}, ip => '192.0.2.6' );
my ($VA) = Lazysite::Odoo::Visitor::mint();
my ($VB) = Lazysite::Odoo::Visitor::mint();

sub run_b {
    my ( $id, $in, %ctx ) = @_;
    my ( undef, $r ) = quiet( sub {
            my ($b) = Lazysite::Odoo::find_binding($id);
            Lazysite::Odoo::call( $b, $in // {}, strict => 1, %ctx );
    } );
    return $r;
}
sub confirm_as {
    my ( $pid,  %c ) = @_;
    my ( undef, $r ) = quiet( sub { Lazysite::Odoo::confirm( $pid, %c ) } );
    return $r;
}
sub qty_total {
    my $t = 0;
    $t += $fake->record( 'x.basket', $_ )->{qty} for @{ $fake->all_ids('x.basket') };
    return $t;
}
sub lines { return scalar @{ $fake->all_ids('x.basket') } }
sub plan_dirs { opendir my $dh, "$d/lazysite/odoo/plans" or return 0; my @e = grep { /\A[0-9a-f]{32}\z/ } readdir $dh; return scalar @e }

my $K = 'queue-item-0001-aaaa';

subtest 'a repeat with the same key does not write twice (immediate apply)' => sub {
    my $a = run_b( 'imm', { product => 1 }, %SAM, idem_key => $K );
    ok( $a->{applied}, 'the first applies' ) or diag explain $a;
    ok( !$a->{repeat}, 'and is not a repeat' );
    is( lines(), 1, 'one line in Odoo' );
    my $n = qty_total();
    my $b = run_b( 'imm', { product => 1 }, %SAM, idem_key => $K );
    ok( $b->{ok} && $b->{applied}, 'the repeat answers' ) or diag explain $b;
    ok( $b->{repeat},              'and says it is a repeat' );
    is( $b->{plan}, $a->{plan}, 'of the same plan' );
    is_deeply( $b->{result}{counts}, $a->{result}{counts}, 'with the first result' );
    is( lines(),     1,  'nothing was written again' );
    is( qty_total(), $n, 'no quantity moved' );
    my $c = run_b( 'imm', { product => 1 }, %SAM );
    ok( $c->{applied} && !$c->{repeat}, 'without a key a repeat is a new write, as before' );
    cmp_ok( qty_total(), '>', $n, 'and the quantity moved' );
};

subtest 'the same key with other parameters is refused, and writes nothing' => sub {
    my $before = qty_total();
    my $r      = run_b( 'imm', { product => 2 }, %SAM, idem_key => $K );
    is( $r->{kind}, 'refused', 'refused' ) or diag explain $r;
    like( $r->{error}, qr/different request/, 'saying why' );
    is( qty_total(), $before, 'nothing written' );
};

subtest 'two persons with the same key do not collide, and neither replays the other' => sub {
    my $key    = 'shared-by-two-9999';
    my $before = lines();
    my $sam    = run_b( 'imm', { product => 1 }, %SAM, idem_key => $key );
    my $al     = run_b( 'imm', { product => 1 }, %ALICE, idem_key => $key );
    ok( $sam->{applied} && !$sam->{repeat}, 'sam: applied' ) or diag explain $sam;
    ok( $al->{applied} && !$al->{repeat}, 'alice, same key: applied, not sam\'s answer' ) or diag explain $al;
    isnt( $al->{plan}, $sam->{plan}, 'a plan of her own' );
    my $q = qty_total();
    ok( run_b( 'imm', { product => 1 }, %SAM, idem_key => $key )->{repeat}, 'sam\'s repeat is a repeat' );
    ok( run_b( 'imm', { product => 1 }, %ALICE, idem_key => $key )->{repeat}, 'alice\'s repeat is a repeat' );
    is( qty_total(), $q, 'neither wrote again' );

    # visitors, by the hash of their key
    my $va = run_b( 'imm', { product => 1 }, mode => 'public', visitor_key => $VA, ip => '192.0.2.8', idem_key => $key );
    my $vb = run_b( 'imm', { product => 1 }, mode => 'public', visitor_key => $VB, ip => '192.0.2.9', idem_key => $key );
    ok( $va->{applied} && !$va->{repeat}, 'a visitor, same key: applied' ) or diag explain $va;
    ok( $vb->{applied} && !$vb->{repeat}, 'another visitor, same key: applied' ) or diag explain $vb;
    ok( run_b( 'imm', { product => 1 }, mode => 'public', visitor_key => $VA, ip => '192.0.2.8', idem_key => $key )->{repeat},
        'and each one\'s repeat is a repeat' );

    # another binding is another key
    my $o = run_b( 'imm2', { product => 1 }, %SAM, idem_key => $key );
    ok( $o->{applied} && !$o->{repeat}, 'the same person and key on another binding: applied' ) or diag explain $o;
};

subtest 'a bad key is refused whole' => sub {
    my $before = qty_total();
    my %bad    = (
        'too short'      => 'abc',
        'too long'       => 'k' x 129,
        'a space'        => 'has space in it',
        'a slash'        => 'item/0001/aaaa',
        'a newline'      => "item-0001-aaaa\nX: y",
        'leading hyphen' => '-item-0001-aaaa',
        'empty'          => '',
        'a reference'    => ['item-0001-aaaa'],
    );
    for my $name ( sort keys %bad ) {
        my $r = run_b( 'imm', { product => 1 }, %SAM, idem_key => $bad{$name} );
        is( $r->{kind}, 'invalid', "$name: refused as invalid" ) or diag explain $r;
        like( $r->{error} // '', qr/Idempotency-Key/, "$name: names the key" );
    }
    ok( run_b( 'imm', { product => 1 }, %SAM, idem_key => 'k' x 128 )->{applied}, '128 characters is the longest taken' );
    ok( run_b( 'imm', { product => 1 }, %SAM, idem_key => '8chars-8' )->{applied}, '8 is the shortest' );
    my $nobody = run_b( 'imm', { product => 1 }, mode => 'public', ip => '192.0.2.1', idem_key => $K );
    is( $nobody->{kind}, 'invalid', 'a caller who is nobody has no scope to hold a key in' ) or diag explain $nobody;
    like( $nobody->{error}, qr/from nobody/, 'in words' );
    my $rd = run_b( 'reads', {}, %SAM, idem_key => $K );
    is( $rd->{kind}, 'invalid', 'a binding that only reads takes no key' ) or diag explain $rd;
    cmp_ok( qty_total(), '>=', $before, 'nothing else wrote' );
};

subtest 'a plan made with a key answers a repeat with the same plan, and a confirm twice with the first result' => sub {
    my $key    = 'plan-item-0002-bbbb';
    my $before = plan_dirs();
    my $p      = run_b( 'later', { product => 1 }, %SAM, idem_key => $key );
    ok( $p->{planned}, 'a plan' ) or diag explain $p;
    is( plan_dirs(), $before + 1, 'one plan folder' );
    my $p2 = run_b( 'later', { product => 1 }, %SAM, idem_key => $key );
    ok( $p2->{planned} && $p2->{repeat}, 'the repeat is a repeat' ) or diag explain $p2;
    is( $p2->{plan}, $p->{plan},  'the same plan' );
    is( plan_dirs(), $before + 1, 'and no second folder' );
    my $lines = qty_total();
    my $c     = confirm_as( $p->{plan}, %SAM );
    ok( $c->{ok} && $c->{applied} && !$c->{repeat}, 'its maker confirms it' ) or diag explain $c;
    cmp_ok( qty_total(), '>', $lines, 'written once' );
    my $q  = qty_total();
    my $c2 = confirm_as( $p->{plan}, %SAM );
    ok( $c2->{ok} && $c2->{applied} && $c2->{repeat}, 'a second confirm answers the first result, as a repeat' ) or diag explain $c2;
    is( qty_total(), $q, 'and writes nothing' );
    my $p3 = run_b( 'later', { product => 1 }, %SAM, idem_key => $key );
    ok( $p3->{applied} && $p3->{repeat}, 'the key after the apply answers the result, not a new plan' ) or diag explain $p3;
    is( qty_total(), $q, 'still nothing written' );

    my $other = confirm_as( $p->{plan}, %ALICE );
    is( $other->{kind}, 'not-found', 'another person cannot confirm it, key or no key' );

    # a plan made without a key takes one at its confirm
    my $np = run_b( 'later', { product => 1 }, %SAM );
    my $ck = confirm_as( $np->{plan}, %SAM, idem_key => 'confirm-key-0003-cc' );
    ok( $ck->{applied} && !$ck->{repeat}, 'a key on the confirm of a plan with none: applied' ) or diag explain $ck;
    my $q2 = qty_total();
    ok( confirm_as( $np->{plan}, %SAM, idem_key => 'confirm-key-0003-cc' )->{repeat}, 'and its repeat is a repeat' );
    is( qty_total(), $q2, 'nothing written' );
    my $mp = run_b( 'later', { product => 1 }, %SAM, idem_key => 'plan-item-0004-dddd' );
    my $mk = confirm_as( $mp->{plan}, %SAM, idem_key => 'another-key-0005-eeee' );
    is( $mk->{kind}, 'invalid', 'a confirm with another key than the plan\'s is refused' ) or diag explain $mk;
    like( $mk->{error}, qr/another Idempotency-Key/, 'by name' );
};

subtest 'the key is in the call record as the key OOM holds, never as the caller sent it' => sub {
    my $rows  = Lazysite::Odoo::read_calls();
    my @keyed = grep { defined $_->{idem} } @$rows;
    ok( scalar @keyed, 'calls carry an idem' );
    is( scalar( grep { $_->{idem} !~ /\Alz1-[0-9a-f]{64}\z/ } @keyed ), 0, 'each is lz1- and a hash' );
    ok( scalar( grep { $_->{repeat} } @$rows ), 'a repeat is marked' );
    is( scalar( grep { $_->{repeat} && $_->{outcome} ne 'answered' } @$rows ), 0, 'and was answered' );
    my $all = encode_json($rows);
    unlike( $all, qr/queue-item-0001|shared-by-two|plan-item-0002|confirm-key-0003/, 'the caller\'s own key is in no record' );
    my %by  = map { ( $_->{call_id} => $_ ) } @$rows;
    my $sam = ( grep { $_->{actor} eq 'sam'   && ( $_->{idem} // '' ) ne '' } @$rows )[0];
    my $al  = ( grep { $_->{actor} eq 'alice' && ( $_->{idem} // '' ) ne '' } @$rows )[0];
    isnt( $sam->{idem}, $al->{idem}, 'two persons\' same key are two different keys' );
};

# A session binding runs as the person signed in to Odoo. The person is the Odoo
# user, so a person who signs in again is the same person and a repeat is a repeat;
# two people are two.
subtest 'a session binding scopes the key to the Odoo user, not the sign-in' => sub {
    require OdooSessionHTTP;
    require Lazysite::Odoo::Session;
    my $PW   = 'a-long-enough-Password-77';
    my $mine = OdooTest::fake_shop( fake => {}, records => { 'x.basket' => [] } );
    my $http = OdooSessionHTTP->new(
        fake   => $mine,
        people => {
            'jane@example.com' => { password => $PW, uid => 7, name => 'Jane', login => 'jane@example.com' },
            'tom@example.com' => { password => $PW, uid => 9, name => 'Tom', login => 'tom@example.com' },
        } );
    local $Lazysite::Odoo::Session::HTTP = $http;
    bind( $d, id => 'my-add', operation => 'shop.add', credential => 'session', modes => 'authenticated',
        apply => 'immediate', params => 'product=product', fixed => 'basket_key=mine' );
    my $sign_in = sub {
        my ($login) = @_;
        my ( undef, $r ) = quiet( sub { Lazysite::Odoo::sign_in( login => $login, password => $PW, ip => '192.0.2.7' ) } );
        return Lazysite::Odoo::Session::sid_from_cookie( 'lzs_odoo_session=' . $r->{cookie} );
    };
    my ( $jane1, $jane2, $tom ) = ( $sign_in->('jane@example.com'), $sign_in->('jane@example.com'), $sign_in->('tom@example.com') );
    ok( $jane1 && $jane2 && $tom && $jane1 ne $jane2, 'two sign-ins of one person, and another person' );
    my $go = sub {
        my ($sid) = @_;
        return run_b( 'my-add', { product => 1 }, mode => 'authenticated', ip => '192.0.2.7', odoo_session => $sid,
            idem_key => 'session-item-0008-hhhh' );
    };
    my $sum = sub { my $t = 0; $t += $mine->record( 'x.basket', $_ )->{qty} for @{ $mine->all_ids('x.basket') }; $t };
    my $a = $go->($jane1);
    ok( $a->{applied} && !$a->{repeat}, 'jane applies' ) or diag explain $a;
    my $n = $sum->();
    cmp_ok( $n, '>', 0, 'written' );
    my $b = $go->($jane2);
    ok( $b->{applied} && $b->{repeat}, 'jane signed in again: a repeat' ) or diag explain $b;
    is( $sum->(), $n, 'nothing written again' );
    my $c = $go->($tom);
    ok( $c->{applied} && !$c->{repeat}, 'tom, same key: his own' ) or diag explain $c;
    cmp_ok( $sum->(), '>', $n, 'written for him' );
};

# --- the endpoint ----------------------------------------------------------------
require "$root/lazysite-odoo.pl";
$Lazysite::Odoo::TRANSPORT = $fake;
my $SCRIPT = '/cgi-bin/lazysite-odoo.pl';

sub request {
    my ( $method, $query, $body, %env ) = @_;
    my $out = '';
    my $in  = defined $body ? ( ref $body ? encode_json($body) : $body ) : '';
    {
        local %ENV = ( PATH => $ENV{PATH}, DOCUMENT_ROOT => $d, REQUEST_METHOD => $method, QUERY_STRING => $query // '',
            REMOTE_ADDR => '198.51.100.3', SCRIPT_NAME => $SCRIPT, CONTENT_LENGTH => length $in,
            HTTP_HOST => 'localhost', %env );
        local *STDOUT;
        open STDOUT, '>', \$out or die $!;
        local *STDIN;
        open STDIN, '<', \$in or die $!;
        binmode STDIN;
        quiet( sub { main::main() } );
    }
    my ( $head, $payload ) = split /\r\n\r\n/, $out, 2;
    my ($status) = $head =~ /Status:\s*(\d+)/;
    my @cookies = $head =~ /^Set-Cookie:\s*(.*?)\r?$/mg;
    return ( $status // 0, \@cookies, ( eval { decode_json( $payload // '' ) } || {} ), $out );
}
sub cv { my ( $c, $n ) = @_; for (@$c) { return $1 if /\A\Q$n\E=([^;]*)/ } return undef }

my ( undef, $vc, $tok ) = request( 'GET', 'csrf=1' );
my $VC = 'lzs_odoo_visitor=' . cv( $vc, 'lzs_odoo_visitor' );
my $VT = $tok->{visitor_token};
sub post {
    my ( $body, %env ) = @_;
    return request( 'POST', '', { visitor_token => $VT, %$body }, CONTENT_TYPE => 'application/json', HTTP_COOKIE => $VC, %env );
}

subtest 'the Idempotency-Key header reaches the engine' => sub {
    my $call = { binding => 'imm', params => { product => 1 } };
    my $q0   = qty_total();
    my ( $st, undef, $j, $raw ) = post( $call, HTTP_IDEMPOTENCY_KEY => 'header-item-0006-ffff' );
    is( $st, 200, 'answered' )                      or diag $raw;
    ok( $j->{applied} && !$j->{repeat}, 'applied' ) or diag explain $j;
    my $q1 = qty_total();
    cmp_ok( $q1, '>', $q0, 'written' );
    ( $st, undef, $j ) = post( $call, HTTP_IDEMPOTENCY_KEY => 'header-item-0006-ffff' );
    is( $st, 200, 'the repeat is answered' );
    ok( $j->{applied} && $j->{repeat}, 'as a repeat' ) or diag explain $j;
    is( qty_total(), $q1, 'and nothing was written' );

    ( $st, undef, $j ) = post( $call, HTTP_IDEMPOTENCY_KEY => 'short' );
    is( $st,        400,       'a bad key: 400' );
    is( $j->{kind}, 'invalid', 'invalid' );
    like( $j->{error}, qr/Idempotency-Key must be 8 to 128/, 'saying the rule' );
    ( $st, undef, $j ) = post( $call, HTTP_IDEMPOTENCY_KEY => 'header-item-0006-ffff', );
    ok( $j->{repeat}, 'a good key still repeats after a bad one' );

    ( $st, undef, $j ) = post( { calls => [$call] }, HTTP_IDEMPOTENCY_KEY => 'header-item-0007-gggg' );
    is( $st, 400, 'a batch with a key: refused' );
    like( $j->{error}, qr/one call/, 'saying a key is for one call' );
    is( qty_total(), $q1, 'nothing written' );

    ( $st, undef, $j ) = post($call);
    ok( $j->{applied} && !$j->{repeat}, 'no header, no key: a new write' ) or diag explain $j;
};

done_testing;
