#!/usr/bin/perl
# SM1395 (ruling 168): A SPENT ANONYMOUS PLAN ANSWERS ITS OWN KEY. Once an
# anonymous binding's plan is spent its owner is `visitor` with no hash (ruling
# 160), so a confirm or a withdraw sent again - a queue that flushed twice, the
# offline kit's resend - could not be told it had worked. A repeat carrying the
# same Idempotency-Key now gets the first stored outcome back, as SM1223 answers
# every caller: ok, the outcome, no parameter value, and no visitor hash written
# to the call line, the audit row or any record. The match is by the plan's
# idempotency record (the scoped key), never by the visitor. Without the key, with
# another key, or from another visitor with the key, it stays not found.
#
# In-process, on OOM's fake Odoo; through the real oomd, t/unit/odoo/137.
#
# Reverted, every repeat is not found.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use OdooTest qw(oom_or_skip shop_ready bind quiet);

BEGIN { oom_or_skip() }
use Lazysite::Odoo          ();
use Lazysite::Odoo::Visitor ();

my ( $d, $fake ) = shop_ready();
$Lazysite::Odoo::Visitor::DOCROOT = $d;
bind( $d, id => 'anonc', operation => 'shop.add', modes => 'public', apply => 'confirm', anonymous => 1,
    params => 'product=product', visitor_param => 'basket_key' );

my $IP = '192.0.2.88';

sub slurp { open my $fh, '<:raw', $_[0] or return ''; local $/; return scalar <$fh> }
sub pdir  { return Lazysite::Odoo::plans_dir() . "/$_[0]" }
sub lines {
    open my $fh, '<', Lazysite::Odoo::calls_file() or return ();
    my @l = grep { ( $_->{binding} // '' ) eq 'anonc' } map { decode_json($_) } <$fh>;
    close $fh;
    return @l;
}
sub plan_it {
    my ( $vkey, %more ) = @_;
    my ( undef, $r ) = quiet( sub {
            my ($b) = Lazysite::Odoo::find_binding('anonc');
            Lazysite::Odoo::call( $b, { product => 3 }, mode => 'public', visitor_key => $vkey, strict => 1, ip => $IP,
                %more );
    } );
    return $r;
}
sub act {
    my ( $what, $pid, $vkey, %more ) = @_;
    my ( undef, $r ) = quiet( sub {
            no strict 'refs';
            &{"Lazysite::Odoo::$what"}( $pid, mode => 'public', visitor_key => $vkey, ip => $IP, %more );
    } );
    return $r;
}
sub baskets { return scalar @{ $fake->all_ids('x.basket') } }

# every file under the plan folder, the call record and the audit log that names
# the hash or any visitor:<hex> label
sub hashed {
    my ( $pid, $hash ) = @_;
    my @hit;
    require File::Find;
    File::Find::find( { no_chdir => 1, wanted => sub {
                push @hit, $_ if -f $_ && slurp($_) =~ /visitor:[0-9a-f]{16,}|\Q$hash\E/;
    } }, pdir($pid) );
    push @hit, 'calls' if slurp( Lazysite::Odoo::calls_file() ) =~ /\Q$hash\E/;
    push @hit, 'audit' if slurp("$d/lazysite/logs/audit.log") =~ /\Q$hash\E/;
    return \@hit;
}

subtest 'a repeated confirm with the plan\'s key gets the first outcome' => sub {
    my ($vk) = Lazysite::Odoo::Visitor::mint();
    my $hash = Lazysite::Odoo::Visitor::visitor_id($vk);
    my $K    = 'queue-item-138-confirm';
    my $p    = plan_it( $vk, idem_key => $K );
    ok( $p->{planned}, 'planned with a key' ) or diag explain $p;
    ok( scalar @{ hashed( $p->{plan}, $hash ) }, 'until it is spent the plan names the hash (the measure finds it)' );
    my $c = act( 'confirm', $p->{plan}, $vk, idem_key => $K );
    ok( $c->{ok} && $c->{applied}, 'the confirm applied' ) or diag explain $c;
    is( decode_json( slurp( pdir( $p->{plan} ) . '/meta.json' ) )->{owner}, 'visitor', 'the plan is spent' );
    my $n     = baskets();
    my $rate  = () = slurp("$d/lazysite/odoo/recent.jsonl") =~ /\Q$hash\E/g;
    my $again = act( 'confirm', $p->{plan}, $vk, idem_key => $K );
    is( scalar( () = slurp("$d/lazysite/odoo/recent.jsonl") =~ /\Q$hash\E/g ), $rate,
        'the repeat writes no rate count by the hash' );
    ok( $again->{ok} && $again->{applied}, 'the repeat answers ok and applied' ) or diag explain $again;
    ok( $again->{repeat},                  'and says it is a repeat' );
    is( $again->{plan}, $p->{plan}, 'of the same plan' );
    is_deeply( $again->{result}{counts}, $c->{result}{counts}, 'with the first outcome\'s counts' )
        or diag explain [ $again, $c ];
    is( baskets(), $n, 'nothing sent to Odoo again' );
    unlike( JSON::PP->new->canonical->encode($again), qr/"product"\s*:\s*3|"qty"\s*:\s*[0-9]/,
        'the answer carries no parameter value' );
    my ($last) = ( lines() )[-1];
    ok( $last->{repeat} && $last->{phase} eq 'apply' && $last->{outcome} eq 'answered', 'its line says a repeat' )
        or diag explain $last;
    ok( !exists $last->{ip} && !exists $last->{visitor}, 'and carries no address and no visitor' );
    like( $last->{idem} // '', qr/\Alz1-/, 'it carries the scoped key OOM holds' );
    is_deeply( hashed( $p->{plan}, $hash ), [], 'no record, call line or audit row names the hash' );
};

subtest 'without the key, with another, or from another visitor: not found' => sub {
    my ($vk) = Lazysite::Odoo::Visitor::mint();
    my ($vo) = Lazysite::Odoo::Visitor::mint();
    my $K    = 'queue-item-138-other';
    my $p    = plan_it( $vk, idem_key => $K );
    my $c    = act( 'confirm', $p->{plan}, $vk, idem_key => $K );
    ok( $c->{applied}, 'confirmed' ) or diag explain $c;
    is( act( 'confirm', $p->{plan}, $vk )->{kind}, 'not-found', 'a repeat without the key is not found' );
    is( act( 'confirm', $p->{plan}, $vk, idem_key => 'queue-item-138-wrong' )->{kind}, 'not-found',
        'with another key, not found' );
    is( act( 'confirm', $p->{plan}, $vo, idem_key => $K )->{kind}, 'not-found',
        'the key from another visitor, not found' );
    is( act( 'withdraw', $p->{plan}, $vk, idem_key => $K )->{kind}, 'not-found',
        'and a withdraw of a plan that was confirmed, not found' );
    is_deeply( hashed( $p->{plan}, Lazysite::Odoo::Visitor::visitor_id($vk) ), [], 'and no line names the hash' );
};

subtest 'a confirm\'s own key on a plan made without one is kept and matched' => sub {
    my ($vk) = Lazysite::Odoo::Visitor::mint();
    my $K    = 'queue-item-138-onconfirm';
    my $p    = plan_it($vk);
    ok( !exists decode_json( slurp( pdir( $p->{plan} ) . '/meta.json' ) )->{idem}, 'planned with no key' );
    my $c = act( 'confirm', $p->{plan}, $vk, idem_key => $K );
    ok( $c->{applied}, 'confirmed with a key' ) or diag explain $c;
    like( decode_json( slurp( pdir( $p->{plan} ) . '/meta.json' ) )->{idem} // '', qr/\Alz1-/,
        'the plan keeps the scoped key, not the caller\'s' );
    unlike( slurp( pdir( $p->{plan} ) . '/meta.json' ), qr/\Q$K\E/, 'the caller\'s key is not in it' );
    my $again = act( 'confirm', $p->{plan}, $vk, idem_key => $K );
    ok( $again->{ok} && $again->{repeat}, 'the repeat gets the first outcome' ) or diag explain $again;
};

subtest 'a repeated withdraw with the key gets the first outcome' => sub {
    my ($vk) = Lazysite::Odoo::Visitor::mint();
    my $hash = Lazysite::Odoo::Visitor::visitor_id($vk);
    my $K    = 'queue-item-138-withdraw';
    my $p    = plan_it( $vk, idem_key => $K );
    is( act( 'withdraw', $p->{plan}, $vk, idem_key => 'bad key' )->{kind}, 'invalid', 'a malformed key is refused' );
    is( act( 'withdraw', $p->{plan}, $vk, idem_key => 'queue-item-138-another' )->{kind}, 'invalid',
        'and a key other than the plan\'s' );
    my $w = act( 'withdraw', $p->{plan}, $vk, idem_key => $K );
    ok( $w->{ok} && $w->{withdrawn}, 'withdrawn' ) or diag explain $w;
    my $again = act( 'withdraw', $p->{plan}, $vk, idem_key => $K );
    ok( $again->{ok} && $again->{withdrawn} && $again->{repeat}, 'the repeat answers ok, withdrawn, a repeat' )
        or diag explain $again;
    my ($last) = ( lines() )[-1];
    ok( $last->{repeat} && $last->{phase} eq 'withdraw' && !exists $last->{ip} && !exists $last->{visitor},
        'its line says a repeat, with no address and no visitor' ) or diag explain $last;
    is( act( 'withdraw', $p->{plan}, $vk )->{kind}, 'not-found', 'without the key, not found' );
    is( act( 'withdraw', $p->{plan}, $vk, idem_key => 'queue-item-138-wrong' )->{kind}, 'not-found',
        'with another key, not found' );
    is( act( 'confirm', $p->{plan}, $vk, idem_key => $K )->{kind}, 'not-found',
        'and a confirm of the withdrawn plan, not found' );
    is_deeply( hashed( $p->{plan}, $hash ), [], 'no record, call line or audit row names the hash' );
};

subtest 'a withdraw\'s own key on a plan made without one is kept and matched' => sub {
    my ($vk) = Lazysite::Odoo::Visitor::mint();
    my $K    = 'queue-item-138-onwithdraw';
    my $p    = plan_it($vk);
    my $w    = act( 'withdraw', $p->{plan}, $vk, idem_key => $K );
    ok( $w->{withdrawn}, 'withdrawn with a key' ) or diag explain $w;
    ok( act( 'withdraw', $p->{plan}, $vk, idem_key => $K )->{repeat}, 'the repeat gets the first outcome' );
};

done_testing;
