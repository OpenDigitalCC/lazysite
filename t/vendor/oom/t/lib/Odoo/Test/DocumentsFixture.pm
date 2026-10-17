package Odoo::Test::DocumentsFixture;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Error;
use Odoo::Test::FakeOdoo;

# A fake Odoo 16, 18 or 19 with sale.order, purchase.order and account.move and the
# actions the documents pack calls, each with the state rules of the source
# (sale_order.py, purchase_order.py, account_move.py) and nothing more:
#
#   sale.order      action_confirm   draft|sent -> sale (done when the company locks, 16; 18 and 19 set locked)
#                   action_cancel    a non-draft order opens the cancel wizard (a returned
#                                    action, no change) on 16 and 18 unless the context has
#                                    disable_cancel_warning; 18 and 19 refuse a locked order
#                   action_draft     cancel|sent -> draft
#   purchase.order  button_confirm   draft|sent -> purchase (to approve under double validation)
#                   button_cancel    refused while a bill that is not draft or cancelled points at it
#                   button_draft     -> draft
#   account.move    action_post      draft -> posted, takes the next number
#                   button_draft     posted|cancel -> draft, keeps the number (16 takes any state)
#                   button_cancel    draft -> cancel (16 writes it on a posted move too)
#
#   my ($fake, $fx) = Odoo::Test::DocumentsFixture->fake( series => 16 );
#   $fx->{lock_on_confirm} = 1;      # sale 16/18 and purchase: done after confirming
#   $fx->{double_validation} = 1;    # purchase stops in "to approve"
#   $fx->{bill_state} = 'posted';    # purchase.button_cancel refuses
#   $fx->{log}                       # [ "model.method(ids) ctx" ... ] in the order Odoo ran them

my $c    = sub { { type => 'char', store => 1 } };
my $bool = sub { { type => 'boolean', store => 1 } };
my $sel  = sub { { type => 'selection', store => 1 } };
my $m2o  = sub ($rel) { { type => 'many2one', relation => $rel, store => 1 } };

sub fields ($series) {
    return {
        'sale.order' => { name => $c->(), state => $sel->(), partner_id => $m2o->('res.partner'), ( $series >= 18 ? ( locked => $bool->() ) : () ) },
        'purchase.order' => { name => $c->(), state => $sel->(), partner_id => $m2o->('res.partner'), partner_ref => $c->(), ( $series == 19 ? ( locked => $bool->() ) : () ) },
        'account.move' => { name => $c->(), state => $sel->(), partner_id => $m2o->('res.partner'), move_type => $c->() },
        'res.partner' => { name => $c->() },
    };
}

sub _fault ($class, $msg) { Odoo::Test::FakeOdoo::_fault( $class, $msg ) }

sub fake ($class, %o) {
    my $series = $o{series} // 16;
    my $fx = { log => [], seq => 0, %{ $o{fx} // {} } };
    my $fake = Odoo::Test::FakeOdoo->new( series => $series, fields => fields($series), records => $o{records} // {} );
    $fake->{documents_fx} = $fx;
    my $m = $fake->{methods};
    my $rows = sub ($fk, $model, $ids) { map { $fk->{data}{$model}{$_} or _fault( 'MissingError', "$model $_ gone" ) } @$ids };
    my $log = sub ($model, $meth, $ids, $kw) {
        push @{ $fx->{log} }, "$model.$meth(" . join( ',', @$ids ) . ')' . ( $kw->{context} && %{ $kw->{context} } ? ' ' . join( ',', map { "$_=" . ( $kw->{context}{$_} ? 1 : 0 ) } sort keys %{ $kw->{context} } ) : '' );
    };
    my $set = sub ($r, $state) { $r->{state} = $state };

    $m->{'sale.order.action_confirm'} = sub ( $fk, $args, $kw ) {
        $log->( 'sale.order', 'action_confirm', $args->[0], $kw );
        for my $r ( $rows->( $fk, 'sale.order', $args->[0] ) ) {
            _fault( 'UserError', 'It is not allowed to confirm an order in the following states: done, cancel' ) if $r->{state} !~ /^(?:draft|sent)\z/;
            $set->( $r, $series > 16 || !$fx->{lock_on_confirm} ? 'sale' : 'done' );
            $r->{locked} = 1 if $series > 16 && $fx->{lock_on_confirm};
        }
        return JSON::PP::true;
    };
    $m->{'sale.order.action_cancel'} = sub ( $fk, $args, $kw ) {
        $log->( 'sale.order', 'action_cancel', $args->[0], $kw );
        my @r = $rows->( $fk, 'sale.order', $args->[0] );
        _fault( 'UserError', 'You cannot cancel a locked order. Please unlock it first.' ) if $series >= 18 && grep { $_->{locked} } @r;
        if ( $series < 19 && !$kw->{context}{disable_cancel_warning} && grep { $_->{state} ne 'draft' } @r ) {
            return { type => 'ir.actions.act_window', res_model => 'sale.order.cancel', target => 'new' };    # the wizard: nothing changed
        }
        $set->( $_, 'cancel' ) for @r;
        return JSON::PP::true;
    };
    $m->{'sale.order.action_draft'} = sub ( $fk, $args, $kw ) {
        $log->( 'sale.order', 'action_draft', $args->[0], $kw );
        for my $r ( $rows->( $fk, 'sale.order', $args->[0] ) ) { $set->( $r, 'draft' ) if $r->{state} =~ /^(?:cancel|sent)\z/ }
        return JSON::PP::true;
    };

    $m->{'purchase.order.button_confirm'} = sub ( $fk, $args, $kw ) {
        $log->( 'purchase.order', 'button_confirm', $args->[0], $kw );
        for my $r ( $rows->( $fk, 'purchase.order', $args->[0] ) ) {
            next if $r->{state} !~ /^(?:draft|sent)\z/;
            $set->( $r, $fx->{double_validation} ? 'to approve' : $fx->{lock_on_confirm} && $series < 19 ? 'done' : 'purchase' );
        }
        return JSON::PP::true;
    };
    $m->{'purchase.order.button_cancel'} = sub ( $fk, $args, $kw ) {
        $log->( 'purchase.order', 'button_cancel', $args->[0], $kw );
        my @r = $rows->( $fk, 'purchase.order', $args->[0] );
        _fault( 'UserError', 'Unable to cancel purchase order(s): You must first unlock them.' ) if $series == 19 && grep { $_->{locked} } @r;
        _fault( 'UserError', 'Unable to cancel this purchase order. You must first cancel the related vendor bills.' ) if $fx->{bill_state} && $fx->{bill_state} !~ /^(?:cancel|draft)\z/;
        $set->( $_, 'cancel' ) for @r;
        return JSON::PP::true;
    };
    $m->{'purchase.order.button_draft'} = sub ( $fk, $args, $kw ) {
        $log->( 'purchase.order', 'button_draft', $args->[0], $kw );
        $set->( $_, 'draft' ) for $rows->( $fk, 'purchase.order', $args->[0] );
        return {};
    };

    $m->{'account.move.action_post'} = sub ( $fk, $args, $kw ) {
        $log->( 'account.move', 'action_post', $args->[0], $kw );
        for my $r ( $rows->( $fk, 'account.move', $args->[0] ) ) {
            _fault( 'UserError', 'The move is not a draft' ) if $r->{state} ne 'draft';
            $r->{name} = sprintf 'INV/2026/%05d', ++$fx->{seq} if !length( $r->{name} // '' ) || $r->{name} eq '/';
            $set->( $r, 'posted' );
        }
        return JSON::PP::true;
    };
    $m->{'account.move.button_draft'} = sub ( $fk, $args, $kw ) {
        $log->( 'account.move', 'button_draft', $args->[0], $kw );
        for my $r ( $rows->( $fk, 'account.move', $args->[0] ) ) {
            _fault( 'UserError', 'Only posted/cancelled journal entries can be reset to draft.' ) if $series > 16 && $r->{state} !~ /^(?:posted|cancel)\z/;
            _fault( 'UserError', 'You cannot modify a posted entry of this journal because it is in strict mode.' ) if $fx->{strict_journal} && $r->{state} eq 'posted';
            $set->( $r, 'draft' );
        }
        return JSON::PP::true;
    };
    $m->{'account.move.button_cancel'} = sub ( $fk, $args, $kw ) {
        $log->( 'account.move', 'button_cancel', $args->[0], $kw );
        for my $r ( $rows->( $fk, 'account.move', $args->[0] ) ) {
            _fault( 'UserError', 'Only draft journal entries can be cancelled.' ) if $series > 16 && $r->{state} ne 'draft';
            $set->( $r, 'cancel' );
        }
        return JSON::PP::true;
    };

    # Odoo deletes an order only from the states the source says
    my %unlink_ok = ( 'sale.order' => [qw(draft cancel)], 'purchase.order' => [qw(cancel)], 'account.move' => [qw(draft cancel)] );
    for my $model ( keys %unlink_ok ) {
        # Odoo defaults the state of a new record to draft
        $m->{"$model.create"} = sub ( $fk, $args, $kw ) {
            my $v = $args->[0];
            my @ids = map { $fk->_create( $model, { state => 'draft', %$_ } ) } ref $v eq 'ARRAY' ? @$v : ($v);
            return ref $v eq 'ARRAY' ? \@ids : $ids[0];
        };
        $m->{"$model.unlink"} = sub ( $fk, $args, $kw ) {
            my $ok = { map { $_ => 1 } @{ $unlink_ok{$model} } };
            for my $r ( $rows->( $fk, $model, $args->[0] ) ) {
                _fault( 'UserError', "You can not delete $model $r->{id} in state $r->{state}" ) if !$ok->{ $r->{state} };
            }
            $fk->_unlink( $model, $_ ) for @{ $args->[0] };
            return JSON::PP::true;
        };
    }
    return ( $fake, $fx );
}

1;
