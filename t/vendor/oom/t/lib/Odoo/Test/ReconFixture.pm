package Odoo::Test::ReconFixture;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Error;
use Odoo::Test::FakeOdoo;

# A fake Odoo 16 or 18 with the journal items, partial and full reconciles, bank statement lines and payments the
# reconciliation operations (account.reconcile, account.unreconcile, account.statement_undo) call, each method with the
# rules of the source (account_move_line.py reconcile / remove_move_reconcile, account_bank_statement_line.py
# action_undo_reconciliation) and nothing more:
#
#   account.move.line.reconcile              refuses a reconciled item, an account that does not allow it, an entry that
#                                            is not posted, two companies and two accounts, in Odoo's words; nets the
#                                            residuals in the order of the ids into partial reconciles; makes the full
#                                            reconcile when nothing is left open on any item connected by partials
#   account.move.line.remove_move_reconcile  unlinks the partials of the items
#   account.partial.reconcile.unlink         gives the amounts back to the two items, dissolves the full reconcile
#   account.bank.statement.line.action_undo_reconciliation
#                                            removes the counterpart lines (and their partials) and the payments, makes a
#                                            suspense line again; to_check false (16), checked true (18)
#
# matching_number as met live: 16 the full reconcile's name (A17) or P; 18 the full reconcile's id or P<n>, n the
# smallest partial of the connected group. reconcile answers record sets on 16 (a dict) and nothing on 18.
#
#   my ($fake, $fx) = Odoo::Test::ReconFixture->fake( series => 16 );
#   my $inv = $fx->item( debit => 115, partner => 'P' );     # a posted receivable item, residual 115
#   my $pay = $fx->item( credit => 100 );
#   $fx->{log}    # [ "account.move.line.reconcile(1,2)" ... ]

my $c    = sub { { type => 'char', store => 1 } };
my $bool = sub { { type => 'boolean', store => 1 } };
my $sel  = sub { { type => 'selection', store => 1 } };
my $num  = sub { { type => 'float', store => 1 } };
my $date = sub { { type => 'date', store => 1 } };
my $m2o  = sub ($rel) { { type => 'many2one', relation => $rel, store => 1 } };
my $o2m  = sub ($rel, $back) { { type => 'one2many', relation => $rel, relation_field => $back, store => 1 } };

sub fields ($series) {
    my $f = _fields($series);
    # every model has its id, as fields_get lists it
    $_->{id} //= { type => 'integer', store => 1 } for values %$f;
    return $f;
}

sub _fields ($series) {
    return {
        'account.account' => { code => $c->(), name => $c->(), reconcile => $bool->(), account_type => $sel->() },
        'account.journal' => { name => $c->(), default_account_id => $m2o->('account.account'), suspense_account_id => $m2o->('account.account') },
        'account.move' => { name => $c->(), state => $sel->(), partner_id => $m2o->('res.partner'), move_type => $c->() },
        'res.partner' => { name => $c->(), email => $c->() },
        'res.currency' => { name => $c->() },
        'res.company' => { name => $c->() },
        'account.move.line' => {
            move_id => $m2o->('account.move'), account_id => $m2o->('account.account'), partner_id => $m2o->('res.partner'), parent_state => $sel->(),
            reconciled => $bool->(), amount_residual => $num->(), amount_residual_currency => $num->(), balance => $num->(),
            currency_id => $m2o->('res.currency'), company_id => $m2o->('res.company'), matching_number => $c->(), full_reconcile_id => $m2o->('account.full.reconcile'),
            matched_debit_ids => { type => 'one2many', relation => 'account.partial.reconcile', store => 1 },
            matched_credit_ids => { type => 'one2many', relation => 'account.partial.reconcile', store => 1 },
            name => $c->(), date => $date->(),
        },
        'account.partial.reconcile' => {
            debit_move_id => $m2o->('account.move.line'), credit_move_id => $m2o->('account.move.line'), amount => $num->(), max_date => $date->(),
            debit_amount_currency => $num->(), credit_amount_currency => $num->(),
            full_reconcile_id => $m2o->('account.full.reconcile'),
        },
        'account.full.reconcile' => { reconciled_line_ids => { type => 'one2many', relation => 'account.move.line', store => 1 }, ( $series == 16 ? ( name => $c->() ) : () ) },
        'account.bank.statement.line' => {
            move_id => $m2o->('account.move'), is_reconciled => $bool->(), amount => $num->(), amount_residual => $num->(), payment_ref => $c->(),
            partner_id => $m2o->('res.partner'), payment_ids => { type => 'one2many', relation => 'account.payment', store => 1 }, journal_id => $m2o->('account.journal'),
            ( $series == 16 ? ( to_check => $bool->() ) : ( checked => $bool->() ) ),
        },
        'account.payment' => { name => $c->(), amount => $num->(), state => $sel->() },
        'ir.module.module' => { name => $c->(), state => $c->() },
    };
}

sub _fault ($class, $msg) { Odoo::Test::FakeOdoo::_fault( $class, $msg ) }
sub _zero ($v) { return abs( $v // 0 ) < 5e-7 }

sub fake ($class, %o) {
    my $series = $o{series} // 16;
    my $fx = { log => [], series => $series, %{ $o{fx} // {} } };
    # a test that needs more fields (the recon pack's) gives them: model => { field => definition }
    my $fields = fields($series);
    for my $model ( keys %{ $o{extra_fields} // {} } ) { $fields->{$model}{$_} = $o{extra_fields}{$model}{$_} for keys %{ $o{extra_fields}{$model} } }
    $_->{id} //= { type => 'integer', store => 1 } for values %$fields;
    my $fake = Odoo::Test::FakeOdoo->new( series => $series, fields => $fields );
    $fake->{recon_fx} = $fx;
    $fx->{fake} = $fake;
    bless $fx, 'Odoo::Test::ReconFixture::Fx';
    my $d = $fake->{data};
    $fx->{receivable} = $fake->insert( 'account.account', { code => '121000', name => '121000 Account Receivable', reconcile => 1, account_type => 'asset_receivable' } );
    $fx->{sales}      = $fake->insert( 'account.account', { code => '400000', name => '400000 Product Sales', reconcile => 0, account_type => 'income' } );
    $fx->{bank}       = $fake->insert( 'account.account', { code => '101401', name => '101401 Bank', reconcile => 0, account_type => 'asset_cash' } );
    $fx->{suspense}   = $fake->insert( 'account.account', { code => '101402', name => '101402 Bank Suspense Account', reconcile => 1, account_type => 'asset_current' } );
    $fx->{journal}    = $fake->insert( 'account.journal', { name => 'Bank', default_account_id => $fx->{bank}, suspense_account_id => $fx->{suspense} } );
    $fx->{eur}        = $fake->insert( 'res.currency', { name => 'EUR' } );
    $fx->{usd}        = $fake->insert( 'res.currency', { name => 'USD' } );
    $fx->{company}    = $fake->insert( 'res.company', { name => 'My Company' } );
    $fx->{company2}   = $fake->insert( 'res.company', { name => 'Other Company' } );
    $fx->{partner}    = $fake->insert( 'res.partner', { name => 'OOM Buyer Ltd', email => 'buyer@example.invalid' } );

    my $m    = $fake->{methods};
    my $rows = sub ($fk, $model, $ids) { map { $fk->{data}{$model}{$_} or _fault( 'MissingError', "$model $_ gone" ) } @$ids };
    my $log  = sub ($model, $meth, $ids) { push @{ $fx->{log} }, "$model.$meth(" . join( ',', @$ids ) . ')' };
    my $id_of = sub ($v) { ref $v eq 'ARRAY' ? $v->[0] : $v };

    $m->{'account.move.line.reconcile'} = sub ( $fk, $args, $kw ) {
        my $ids = $args->[0];
        $log->( 'account.move.line', 'reconcile', $ids );
        my @lines = $rows->( $fk, 'account.move.line', $ids );
        my ( $company, $account );
        for my $l (@lines) {
            _fault( 'UserError', 'You are trying to reconcile some entries that are already reconciled.' ) if $l->{reconciled};
            my $a = $d->{'account.account'}{ $l->{account_id} };
            _fault( 'UserError', "Account $a->{name} does not allow reconciliation. First change the configuration of this account to allow it." )
                if !$a->{reconcile} && $a->{account_type} !~ /\A(?:asset_cash|liability_credit_card)\z/;
            _fault( 'UserError', 'You can only reconcile posted entries.' ) if ( $l->{parent_state} // '' ) ne 'posted';
            $company //= $l->{company_id};
            _fault( 'UserError', "Entries doesn't belong to the same company: $d->{'res.company'}{$company}{name} != $d->{'res.company'}{$l->{company_id}}{name}" ) if $l->{company_id} != $company;
            $account //= $l->{account_id};
            _fault( 'UserError', "Entries are not from the same account: $d->{'account.account'}{$account}{name} != $a->{name}" ) if $l->{account_id} != $account;
        }
        my @debit  = sort { $a->{id} <=> $b->{id} } grep { $_->{amount_residual_currency} > 5e-7 } @lines;
        my @credit = sort { $a->{id} <=> $b->{id} } grep { $_->{amount_residual_currency} < -5e-7 } @lines;
        my @made;
        for my $dl (@debit) {
            for my $cl (@credit) {
                last if _zero( $dl->{amount_residual_currency} );
                next if _zero( $cl->{amount_residual_currency} );
                my $amt = $dl->{amount_residual_currency} < -$cl->{amount_residual_currency} ? $dl->{amount_residual_currency} : -$cl->{amount_residual_currency};
                my $when = ( sort { $b cmp $a } grep { defined } $dl->{date}, $cl->{date} )[0] // '2026-10-21';
                my $pid = $fk->insert( 'account.partial.reconcile', { debit_move_id => $dl->{id}, credit_move_id => $cl->{id}, amount => $amt, max_date => $when, full_reconcile_id => 0,
                    debit_amount_currency => $amt, credit_amount_currency => $amt } );
                push @made, $pid;
                $dl->{amount_residual} = $dl->{amount_residual_currency} = $dl->{amount_residual_currency} - $amt;
                $cl->{amount_residual} = $cl->{amount_residual_currency} = $cl->{amount_residual_currency} + $amt;
                push @{ $dl->{matched_credit_ids} }, $pid;
                push @{ $cl->{matched_debit_ids} }, $pid;
            }
        }
        $fx->settle( map { $_->{id} } @lines );
        return $series == 16 ? { exchange_partials => 'account.partial.reconcile()', partials => 'account.partial.reconcile(' . join( ', ', @made ) . ',)' } : undef;
    };

    $m->{'account.move.line.remove_move_reconcile'} = sub ( $fk, $args, $kw ) {
        $log->( 'account.move.line', 'remove_move_reconcile', $args->[0] );
        my %p;
        for my $l ( $rows->( $fk, 'account.move.line', $args->[0] ) ) { $p{$_} = 1 for @{ $l->{matched_debit_ids} // [] }, @{ $l->{matched_credit_ids} // [] } }
        $fx->unlink_partials( sort { $a <=> $b } keys %p );
        return undef;
    };
    $m->{'account.partial.reconcile.unlink'} = sub ( $fk, $args, $kw ) {
        $log->( 'account.partial.reconcile', 'unlink', $args->[0] );
        $fx->unlink_partials( @{ $args->[0] } );
        return JSON::PP::true;
    };

    $m->{'account.bank.statement.line.action_undo_reconciliation'} = sub ( $fk, $args, $kw ) {
        $log->( 'account.bank.statement.line', 'action_undo_reconciliation', $args->[0] );
        for my $st ( $rows->( $fk, 'account.bank.statement.line', $args->[0] ) ) {
            my $j = $d->{'account.journal'}{ $st->{journal_id} };
            my @mine = grep { ( $_->{move_id} // 0 ) == $st->{move_id} } map { $d->{'account.move.line'}{$_} } @{ $fk->all_ids('account.move.line') };
            my @counter = grep { $_->{account_id} != $j->{default_account_id} && $_->{account_id} != $j->{suspense_account_id} } @mine;
            my %p;
            for my $l (@counter) { $p{$_} = 1 for @{ $l->{matched_debit_ids} // [] }, @{ $l->{matched_credit_ids} // [] } }
            $fx->unlink_partials( sort { $a <=> $b } keys %p );
            delete $d->{'account.move.line'}{ $_->{id} } for @counter;
            delete $d->{'account.payment'}{$_} for @{ $st->{payment_ids} // [] };
            $st->{payment_ids} = [];
            if ( !grep { $_->{account_id} == $j->{suspense_account_id} } @mine ) {
                $fk->insert( 'account.move.line', { move_id => $st->{move_id}, account_id => $j->{suspense_account_id}, partner_id => 0, parent_state => 'posted', reconciled => 0,
                    amount_residual => -$st->{amount}, amount_residual_currency => -$st->{amount}, balance => -$st->{amount}, currency_id => $fx->{eur}, company_id => $fx->{company}, name => $st->{payment_ref} } );
            }
            $st->{is_reconciled} = 0;
            $series == 16 ? ( $st->{to_check} = 0 ) : ( $st->{checked} = 1 );
        }
        return JSON::PP::true;
    };
    return ( $fake, $fx );
}

package Odoo::Test::ReconFixture::Fx;

# a posted journal item on the receivable account: item( debit => 115 ) or item( credit => 100 ); options partner (a name; the
# fixture's partner by default), account, company, currency, state, move (an entry name)
sub item ($fx, %o) {
    my $fake = $fx->{fake};
    my $amt = exists $o{debit} ? $o{debit} : -$o{credit};
    my $mv = $fake->insert( 'account.move', { name => $o{move} // ( 'MOVE/' . ( 1 + scalar @{ $fake->all_ids('account.move') } ) ), state => 'posted', partner_id => $fx->{partner}, move_type => 'entry' } );
    return $fake->insert( 'account.move.line', {
        move_id => $mv, account_id => $o{account} // $fx->{receivable}, partner_id => $fx->{partner}, parent_state => $o{state} // 'posted', reconciled => 0,
        amount_residual => $amt, amount_residual_currency => $amt, balance => $amt, currency_id => $o{currency} // $fx->{eur}, company_id => $o{company} // $fx->{company},
        matching_number => 0, full_reconcile_id => 0, matched_debit_ids => [], matched_credit_ids => [], name => 'item', date => '2026-10-01',
    } );
}

# a bank statement line whose entry holds a liquidity line and either a suspense line (unreconciled) or counterpart lines
# (reconciled: counterpart => [ item ids to take over ] ), and optionally payments
sub statement_line ($fx, %o) {
    my $fake = $fx->{fake};
    my $amount = $o{amount} // 100;
    my $mv = $fake->insert( 'account.move', { name => 'BNK1/2026/00001', state => 'posted', partner_id => $fx->{partner}, move_type => 'entry' } );
    my $liq = $fake->insert( 'account.move.line', { move_id => $mv, account_id => $fx->{bank}, partner_id => $fx->{partner}, parent_state => 'posted', reconciled => 0,
        amount_residual => 0, amount_residual_currency => 0, balance => $amount, currency_id => $fx->{eur}, company_id => $fx->{company}, matched_debit_ids => [], matched_credit_ids => [], name => 'liquidity' } );
    my @counter;
    if ( $o{reconciled} ) {
        my $cl = $fake->insert( 'account.move.line', { move_id => $mv, account_id => $fx->{receivable}, partner_id => $fx->{partner}, parent_state => 'posted', reconciled => 0,
            amount_residual => -$amount, amount_residual_currency => -$amount, balance => -$amount, currency_id => $fx->{eur}, company_id => $fx->{company}, matched_debit_ids => [], matched_credit_ids => [], name => 'counterpart' } );
        push @counter, $cl;
        if ( $o{against} ) {
            $fake->{methods}{'account.move.line.reconcile'}->( $fake, [ [ $cl, $o{against} ] ], {} );
        }
    }
    else {
        $fake->insert( 'account.move.line', { move_id => $mv, account_id => $fx->{suspense}, partner_id => 0, parent_state => 'posted', reconciled => 0,
            amount_residual => -$amount, amount_residual_currency => -$amount, balance => -$amount, currency_id => $fx->{eur}, company_id => $fx->{company}, matched_debit_ids => [], matched_credit_ids => [], name => 'suspense' } );
    }
    my @pay = map { $fake->insert( 'account.payment', { name => "PAY/$_", amount => $amount, state => 'posted' } ) } 1 .. ( $o{payments} // 0 );
    return $fake->insert( 'account.bank.statement.line', { move_id => $mv, is_reconciled => $o{reconciled} ? 1 : 0, amount => $amount, amount_residual => 0, payment_ref => $o{label} // 'Bank line',
        partner_id => $fx->{partner}, payment_ids => \@pay, journal_id => $fx->{journal}, ( $fx->{series} == 16 ? ( to_check => 0 ) : ( checked => 0 ) ) } );
}

sub line ($fx, $id) { return $fx->{fake}{data}{'account.move.line'}{$id} }

# after partials are made or removed: residual-driven state of the items, the full reconcile and the matching numbers of every
# item connected by partials to the ones named
sub settle ($fx, @ids) {
    my $fake = $fx->{fake};
    my $dl = $fake->{data}{'account.move.line'};
    my $dp = $fake->{data}{'account.partial.reconcile'};
    # the connected group of each item
    my %seen;
    for my $start (@ids) {
        next if $seen{$start} || !$dl->{$start};
        my ( @group, @todo );
        @todo = ($start);
        while (@todo) {
            my $id = shift @todo;
            next if $seen{$id}++ || !$dl->{$id};
            push @group, $id;
            for my $pid ( @{ $dl->{$id}{matched_debit_ids} // [] }, @{ $dl->{$id}{matched_credit_ids} // [] } ) {
                my $p = $dp->{$pid} or next;
                push @todo, $p->{debit_move_id}, $p->{credit_move_id};
            }
        }
        my @partials = sort { $a <=> $b } keys %{ { map { ( $_ => 1 ) } map { ( @{ $dl->{$_}{matched_debit_ids} // [] }, @{ $dl->{$_}{matched_credit_ids} // [] } ) } @group } };
        for my $id (@group) {
            $dl->{$id}{reconciled} = Odoo::Test::ReconFixture::_zero( $dl->{$id}{amount_residual_currency} ) && @partials ? 1 : 0;
        }
        my $all_clear = @partials && !grep { !Odoo::Test::ReconFixture::_zero( $dl->{$_}{amount_residual_currency} ) } @group;
        if ($all_clear) {
            my $fid = $fake->insert( 'account.full.reconcile', { reconciled_line_ids => [@group], ( $fx->{series} == 16 ? ( name => 'A' . ( 1 + scalar @{ $fake->all_ids('account.full.reconcile') } ) ) : () ) } );
            $dp->{$_}{full_reconcile_id} = $fid for @partials;
            for my $id (@group) {
                $dl->{$id}{full_reconcile_id} = $fid;
                $dl->{$id}{matching_number} = $fx->{series} == 16 ? $fake->{data}{'account.full.reconcile'}{$fid}{name} : "$fid";
            }
        }
        else {
            for my $id (@group) {
                $dl->{$id}{full_reconcile_id} = 0;
                $dl->{$id}{matching_number} = @partials ? ( $fx->{series} == 16 ? 'P' : "P$partials[0]" ) : 0;
            }
        }
    }
}

sub unlink_partials ($fx, @pids) {
    my $fake = $fx->{fake};
    my $dl = $fake->{data}{'account.move.line'};
    my $dp = $fake->{data}{'account.partial.reconcile'};
    my %touched;
    my %fulls;
    for my $pid (@pids) {
        my $p = $dp->{$pid} or next;
        for my $side (qw(debit_move_id credit_move_id)) {
            my $l = $dl->{ $p->{$side} } or next;
            $touched{ $l->{id} } = 1;
            if ( $side eq 'debit_move_id' ) { $l->{amount_residual} += $p->{amount}; $l->{amount_residual_currency} += $p->{amount}; $l->{matched_credit_ids} = [ grep { $_ != $pid } @{ $l->{matched_credit_ids} } ] }
            else                            { $l->{amount_residual} -= $p->{amount}; $l->{amount_residual_currency} -= $p->{amount}; $l->{matched_debit_ids} = [ grep { $_ != $pid } @{ $l->{matched_debit_ids} } ] }
        }
        $fulls{ $p->{full_reconcile_id} } = 1 if $p->{full_reconcile_id};
        delete $dp->{$pid};
    }
    for my $fid ( keys %fulls ) {
        # Odoo unlinks the partials of a full reconcile together with it
        for my $pid ( grep { ( $dp->{$_}{full_reconcile_id} // 0 ) == $fid } keys %$dp ) {
            $dp->{$pid}{full_reconcile_id} = 0;
        }
        for my $l ( grep { ( $_->{full_reconcile_id} // 0 ) == $fid } values %$dl ) { $l->{full_reconcile_id} = 0; $touched{ $l->{id} } = 1 }
        delete $fake->{data}{'account.full.reconcile'}{$fid};
    }
    for my $id ( keys %touched ) { $dl->{$id}{reconciled} = 0 if !@{ $dl->{$id}{matched_debit_ids} // [] } && !@{ $dl->{$id}{matched_credit_ids} // [] } }
    $fx->settle( keys %touched );
    for my $id ( keys %touched ) { $dl->{$id}{matching_number} = 0 if !@{ $dl->{$id}{matched_debit_ids} // [] } && !@{ $dl->{$id}{matched_credit_ids} // [] } }
}

1;
