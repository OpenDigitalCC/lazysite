package Odoo::Test::StockFixture;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Test::FakeOdoo;

# A fake Odoo 16 with enough stock to exercise the stock pack offline:
# a stock bay, a "location unknown" bin, an output location; packages
# recorded in two places; negatives with every kind of counterpart;
# open reservations made at confirmation and later by a person.

my $c  = sub { { type => 'char', store => 1 } };
my $m2o = sub ($rel) { { type => 'many2one', relation => $rel, store => 1 } };
my $fl = sub { { type => 'float', store => 1 } };

sub fields () {
    return {
        'ir.module.module' => { name => $c->(), state => $c->() },
        'product.category' => { name => $c->(), property_valuation => $c->() },
        'product.product'  => { name => $c->(), default_code => $c->(), display_name => $c->(), uom_id => $m2o->('uom.uom') },
        'stock.location'   => { name => $c->(), complete_name => $c->(), usage => $c->(), location_id => $m2o->('stock.location'),
            active => { type => 'boolean' }, warehouse_id => $m2o->('stock.warehouse') },
        'stock.warehouse'  => { name => $c->() },
        'stock.quant.package' => { name => $c->(), location_id => $m2o->('stock.location') },
        'stock.lot' => { name => $c->(), product_id => $m2o->('product.product'), expiration_date => { type => 'datetime' }, create_date => { type => 'datetime' } },
        'stock.quant' => { product_id => $m2o->('product.product'), lot_id => $m2o->('stock.lot'), location_id => $m2o->('stock.location'),
            package_id => $m2o->('stock.quant.package'), quantity => $fl->(), reserved_quantity => $fl->(), inventory_quantity => $fl->(),
            company_id => $m2o->('res.company') },
        'res.company' => { name => $c->() },
        'stock.picking.type' => { name => $c->(), code => $c->(), reservation_method => $c->(), warehouse_id => $m2o->('stock.warehouse'),
            default_location_src_id => $m2o->('stock.location'), default_location_dest_id => $m2o->('stock.location') },
        'stock.picking' => { name => $c->(), origin => $c->(), state => $c->(), picking_type_id => $m2o->('stock.picking.type'),
            location_id => $m2o->('stock.location'), location_dest_id => $m2o->('stock.location'), partner_id => $m2o->('res.partner'),
            date_done => { type => 'datetime' }, scheduled_date => { type => 'datetime' }, immediate_transfer => { type => 'boolean' },
            move_ids => { type => 'one2many', relation => 'stock.move', relation_field => 'picking_id' },
            move_line_ids => { type => 'one2many', relation => 'stock.move.line', relation_field => 'picking_id' },
            sale_id => $m2o->('sale.order'), note => { type => 'html' }, create_date => { type => 'datetime' } },
        'res.partner' => { name => $c->() },
        'sale.order'  => { name => $c->(), state => $c->(), partner_id => $m2o->('res.partner'), date_order => { type => 'datetime' },
            picking_ids => { type => 'one2many', relation => 'stock.picking' }, invoice_ids => { type => 'many2many', relation => 'account.move' },
            order_line => { type => 'one2many', relation => 'sale.order.line' } },
        'account.move' => { name => $c->() },
        'sale.order.line' => { order_id => $m2o->('sale.order'), product_id => $m2o->('product.product'), product_uom_qty => $fl->(),
            qty_delivered => $fl->(), qty_invoiced => $fl->() },
        'stock.move' => { name => $c->(), product_id => $m2o->('product.product'), product_uom_qty => $fl->(), quantity_done => $fl->(),
            product_uom => $m2o->('uom.uom'), location_id => $m2o->('stock.location'), location_dest_id => $m2o->('stock.location'),
            picking_id => $m2o->('stock.picking'), state => $c->(), date => { type => 'datetime' }, sale_line_id => $m2o->('sale.order.line'),
            move_orig_ids => { type => 'many2many', relation => 'stock.move' }, move_dest_ids => { type => 'many2many', relation => 'stock.move' },
            move_line_ids => { type => 'one2many', relation => 'stock.move.line' }, reference => $c->() },
        'uom.uom' => { name => $c->() },
        'stock.move.line' => { product_id => $m2o->('product.product'), lot_id => $m2o->('stock.lot'), lot_name => $c->(),
            package_id => $m2o->('stock.quant.package'), result_package_id => $m2o->('stock.quant.package'),
            location_id => $m2o->('stock.location'), location_dest_id => $m2o->('stock.location'),
            reserved_uom_qty => $fl->(), qty_done => $fl->(), move_id => $m2o->('stock.move'), picking_id => $m2o->('stock.picking'),
            product_uom_id => $m2o->('uom.uom'),
            state => $c->(), date => { type => 'datetime' }, reference => $c->(), create_date => { type => 'datetime' },
            create_uid => $m2o->('res.users'), write_date => { type => 'datetime' }, write_uid => $m2o->('res.users') },
        'res.users' => { name => $c->(), login => $c->(), email => $c->(), partner_id => $m2o->('res.partner') },
        'expiry.picking.confirmation' => { pick_ids => { type => 'many2many', relation => 'stock.picking' } },
        'stock.backorder.confirmation' => { pick_ids => { type => 'many2many', relation => 'stock.picking' } },
        'stock.immediate.transfer'     => { pick_ids => { type => 'many2many', relation => 'stock.picking' } },
    };
}

# locations: 1 WH/Stock, 2 WH/Unknown, 3 WH/Output, 4 Customers, 5 WH/Stock/Bay A
sub records () {
    return {
        'ir.module.module' => [ map { { id => $_->[0], name => $_->[1], state => $_->[2] } }
                [ 1, 'stock', 'installed' ], [ 2, 'sale_stock', 'installed' ], [ 3, 'product_expiry', 'uninstalled' ], [ 4, 'stock_account', 'installed' ] ],
        'product.category' => [ { id => 1, name => 'All', property_valuation => 'manual_periodic' } ],
        'product.product'  => [ { id => 1, name => 'Compost 40L', default_code => 'C40', display_name => '[C40] Compost 40L', uom_id => 1 },
                                { id => 2, name => 'Pot 30cm', default_code => 'P30', display_name => '[P30] Pot 30cm', uom_id => 1 } ],
        'uom.uom'          => [ { id => 1, name => 'Units' } ],
        'stock.warehouse'  => [ { id => 1, name => 'WH' } ],
        'stock.location'   => [
            { id => 1, name => 'WH/Stock',       complete_name => 'WH/Stock',       usage => 'internal', active => 1, warehouse_id => 1 },
            { id => 2, name => 'WH/Unknown',     complete_name => 'WH/Unknown',     usage => 'internal', active => 1, warehouse_id => 1 },
            { id => 3, name => 'WH/Output',      complete_name => 'WH/Output',      usage => 'internal', active => 1, warehouse_id => 1 },
            { id => 4, name => 'Customers',      complete_name => 'Partners/Customers', usage => 'customer', active => 1 },
            { id => 5, name => 'WH/Stock/Bay A', complete_name => 'WH/Stock/Bay A', usage => 'internal', active => 1, warehouse_id => 1, location_id => 1 },
        ],
        'stock.quant.package' => [ map { { id => $_, name => "PAL-$_" } } 1 .. 5 ],
        'stock.lot' => [ { id => 1, name => 'L1', product_id => 1 }, { id => 2, name => 'L2', product_id => 1 }, { id => 3, name => 'L3', product_id => 2 } ],
        'res.company' => [ { id => 1, name => 'Co' } ],
        'stock.quant' => [
            # PAL-1 mirror: +10 in Unknown, -10 in Bay A (same lot)        -> negative matched 'same-package'? no: unknown counts first? order: same-place, same-package(not output), unknown
            { id => 1, product_id => 1, lot_id => 1, location_id => 2, package_id => 1, quantity => 10, reserved_quantity => 0 },
            { id => 2, product_id => 1, lot_id => 1, location_id => 5, package_id => 1, quantity => -10, reserved_quantity => 0 },
            # PAL-2 partial: +8 in Unknown, -5 in Stock
            { id => 3, product_id => 1, lot_id => 2, location_id => 2, package_id => 2, quantity => 8, reserved_quantity => 0 },
            { id => 4, product_id => 1, lot_id => 2, location_id => 1, package_id => 2, quantity => -5, reserved_quantity => 0 },
            # PAL-3 neg-only: -4 in Stock, nothing in Unknown; loose +4 in the same place (same-place match)
            { id => 5, product_id => 2, lot_id => 3, location_id => 1, package_id => 3, quantity => -4, reserved_quantity => 0 },
            { id => 6, product_id => 2, lot_id => 3, location_id => 1, package_id => undef, quantity => 4, reserved_quantity => 0 },
            # PAL-4 in two positive places (other)
            { id => 7, product_id => 2, lot_id => 3, location_id => 1, package_id => 4, quantity => 3, reserved_quantity => 0 },
            { id => 8, product_id => 2, lot_id => 3, location_id => 5, package_id => 4, quantity => 3, reserved_quantity => 0 },
            # stranded in Output: 6 free, 2 reserved
            { id => 9, product_id => 1, lot_id => 1, location_id => 3, package_id => 5, quantity => 8, reserved_quantity => 2 },
            # a loose negative with nothing anywhere: 'none'
            { id => 10, product_id => 2, lot_id => undef, location_id => 5, package_id => undef, quantity => -7, reserved_quantity => 0 },
            # reserved positive must not be used as a counterpart
            { id => 11, product_id => 2, lot_id => undef, location_id => 1, package_id => undef, quantity => 7, reserved_quantity => 7 },
        ],
        'stock.picking.type' => [
            { id => 1, name => 'Pick',      code => 'internal', reservation_method => 'manual',     warehouse_id => 1 },
            { id => 2, name => 'Delivery',  code => 'outgoing', reservation_method => 'at_confirm', warehouse_id => 1 },
            { id => 3, name => 'Internal',  code => 'internal', reservation_method => 'at_confirm', warehouse_id => 1 },
        ],
        'res.users'   => [ { id => 2, name => 'Tester', login => 'tester', email => 'tester@ours.example', partner_id => 1 }, { id => 9, name => 'Warehouse Person', login => 'wh' } ],
        'res.partner' => [ { id => 1, name => 'Customer Ltd' } ],
        'stock.picking' => [
            { id => 1, name => 'WH/PICK/00001', origin => 'S00001', state => 'assigned', picking_type_id => 1, location_id => 1, location_dest_id => 3, create_date => '2026-10-01 09:00:00' },
            { id => 2, name => 'WH/OUT/00001',  origin => 'S00001', state => 'assigned', picking_type_id => 2, location_id => 3, location_dest_id => 4, create_date => '2026-10-01 09:00:00' },
        ],
        'stock.move.line' => [
            # reserved at confirmation (within 2 minutes of the picking)
            { id => 1, product_id => 2, lot_id => undef, location_id => 1, location_dest_id => 3, reserved_uom_qty => 7, qty_done => 0, picking_id => 1, state => 'assigned',
                create_date => '2026-10-01 09:00:30', create_uid => 2, write_date => '2026-10-01 09:00:30', write_uid => 2 },
            # reserved three days later by a person, and changed since by another
            { id => 2, product_id => 1, lot_id => 1, location_id => 3, location_dest_id => 4, package_id => 5, reserved_uom_qty => 2, qty_done => 0, picking_id => 2, state => 'assigned',
                create_date => '2026-10-04 11:00:00', create_uid => 9, write_date => '2026-10-05 08:00:00', write_uid => 2 },
            # a done line, ignored
            { id => 3, product_id => 1, lot_id => 1, location_id => 1, location_dest_id => 3, reserved_uom_qty => 0, qty_done => 5, picking_id => 1, state => 'done',
                create_date => '2026-09-01 09:00:00', create_uid => 2, write_date => '2026-09-01 09:00:00', write_uid => 2 },
        ],
    };
}

sub new ($class, %args) {
    my $f = Odoo::Test::FakeOdoo->new( fields => fields(), records => records(), series => 16, %args );
    # the stock behaviour the write operations rely on: confirming a
    # picking, validating it (quants move by its lines), the chatter
    $f->{methods}{'stock.picking.action_confirm'} = sub ($fk, $args, $kw) {
        $fk->record( 'stock.picking', $_ )->{state} = 'assigned' for @{ $args->[0] };
        return 1;
    };
    $f->{methods}{'stock.picking.message_post'} = sub ($fk, $args, $kw) {
        push @{ $fk->{posted} }, [ ( ref $args->[0] ? $args->[0][0] : $args->[0] ), $kw->{body}, $kw ];
        return 1;
    };
    $f->{methods}{'stock.picking.button_validate'} = sub ($fk, $args, $kw) {
        for my $pid ( @{ $args->[0] } ) {
            my $r = _validate( $fk, $pid, %{ $kw->{context} // {} } );
            return $r if ref $r;
        }
        return JSON::PP::true;
    };
    # the wizards button_validate opens: created with the action's context, processed by id
    for my $w (qw(stock.backorder.confirmation stock.immediate.transfer expiry.picking.confirmation)) {
        $f->{methods}{"$w.create"} = sub ($fk, $args, $kw) {
            my $ctx = $kw->{context} // {};
            my $id = $fk->insert( $w, { pick_ids => [ @{ $ctx->{button_validate_picking_ids} // [] } ], ctx => $ctx } );
            return $fk->{wizard_ids_as_list} ? [$id] : $id;
        };
    }
    my $process = sub ($w, %extra) {
        return sub ($fk, $args, $kw) {
            my $wid = $args->[0][0];
            die "fake: wizard id nested one level too deep (SD2)\n" if ref $wid;
            my $rec = $fk->record( $w, $wid ) or die "fake: no wizard $wid\n";
            push @{ $fk->{wizards_processed} }, $w;
            for my $pid ( @{ $rec->{pick_ids} } ) {
                my $r = _validate( $fk, $pid, %{ $rec->{ctx} }, %extra );
                return $r if ref $r;
            }
            return JSON::PP::true;
        };
    };
    $f->{methods}{'stock.backorder.confirmation.process_cancel_backorder'} = $process->( 'stock.backorder.confirmation', skip_backorder => 1 );
    $f->{methods}{'stock.backorder.confirmation.process'}                  = $process->( 'stock.backorder.confirmation', skip_backorder => 1 );
    $f->{methods}{'stock.immediate.transfer.process'}                      = $process->( 'stock.immediate.transfer', skip_immediate => 1 );
    $f->{methods}{'expiry.picking.confirmation.process'}                   = $process->( 'expiry.picking.confirmation', skip_expired => 1 );
    $f->{methods}{'stock.picking.action_assign'} = sub ($fk, $args, $kw) {
        $fk->record( 'stock.picking', $_ )->{state} = 'assigned' for @{ $args->[0] };
        return 1;
    };
    # a reserved line that goes releases what it reserved
    $f->{methods}{'stock.move.line.unlink'} = sub ($fk, $args, $kw) {
        for my $id ( @{ $args->[0] } ) {
            my $l = delete $fk->{data}{'stock.move.line'}{$id} or next;
            my ($q) = grep { $_->{product_id} == $l->{product_id} && ( $_->{lot_id} // 0 ) == ( $l->{lot_id} // 0 ) && $_->{location_id} == $l->{location_id} && ( $_->{package_id} // 0 ) == ( $l->{package_id} // 0 ) }
                values %{ $fk->{data}{'stock.quant'} };
            $q->{reserved_quantity} -= $l->{reserved_uom_qty} // 0 if $q && !$l->{qty_done};
        }
        return 1;
    };
    # SA3: a line added to a picking already done becomes a stand-alone done move, no sale line, no onward move
    $f->{methods}{'stock.move.line.create'} = sub ($fk, $args, $kw) {
        my $v = $args->[0];
        my @made = map {
            my $vals = $_;
            my $pk = $vals->{picking_id} ? $fk->record( 'stock.picking', $vals->{picking_id} ) : undef;
            if ( $pk && !$vals->{move_id} && ( $pk->{state} // '' ) eq 'done' ) {
                my $mid = $fk->insert( 'stock.move', { name => 'stand-alone', product_id => $vals->{product_id}, product_uom_qty => $vals->{qty_done}, quantity_done => $vals->{qty_done},
                    product_uom => $vals->{product_uom_id}, location_id => $vals->{location_id}, location_dest_id => $vals->{location_dest_id}, picking_id => $vals->{picking_id},
                    state => 'done', date => '2026-10-13 12:00:00', move_orig_ids => [], move_dest_ids => [], move_line_ids => [] } );
                my $lid = $fk->_create( 'stock.move.line', { %$vals, move_id => $mid, state => 'done' } );
                push @{ $fk->record( 'stock.move', $mid )->{move_line_ids} }, $lid;
                _move_quant( $fk, $vals->{product_id}, $vals->{lot_id}, $vals->{location_id}, $vals->{package_id}, -$vals->{qty_done} );
                _move_quant( $fk, $vals->{product_id}, $vals->{lot_id}, $vals->{location_dest_id}, $vals->{result_package_id}, $vals->{qty_done} );
                $lid;
            }
            else { $fk->_create( 'stock.move.line', $vals ) }
        } ref $v eq 'ARRAY' ? @$v : ($v);
        return ref $v eq 'ARRAY' ? \@made : $made[0];
    };
    # linking a move to a sale line is what makes the delivered quantity move (SC1)
    $f->{methods}{'stock.move.write'} = sub ($fk, $args, $kw) {
        my ( $ids, $vals ) = @$args;
        for my $id (@$ids) {
            my $r = $fk->{data}{'stock.move'}{$id} or die "fake: record $id gone\n";
            $fk->_assign( 'stock.move', $r, $vals );
            # move_orig_ids and move_dest_ids are the two ends of one relation
            for my $o ( @{ $r->{move_orig_ids} // [] } ) {
                my $om = $fk->{data}{'stock.move'}{$o} or next;
                push @{ $om->{move_dest_ids} }, $id if !grep { $_ == $id } @{ $om->{move_dest_ids} // [] };
            }
        }
        _recompute_delivered($fk) if exists $vals->{sale_line_id};
        return 1;
    };
    add_stock_for_sales($f) if $args{sales};
    return $f;
}

# --- validation ---------------------------------------------------------------
# Returns true, or a window action like Odoo's button_validate. Order of the
# checks as in Odoo: immediate, backorder, then product_expiry.
sub _validate ($fk, $pid, %skip) {
    my $pk = $fk->record( 'stock.picking', $pid );
    my @moves = grep { ( $_->{picking_id} // 0 ) == $pid && ( $_->{state} // '' ) ne 'cancel' } values %{ $fk->{data}{'stock.move'} };
    my @lines = grep { ( $_->{picking_id} // 0 ) == $pid } values %{ $fk->{data}{'stock.move.line'} };
    my $action = sub ($model) { +{ type => 'ir.actions.act_window', res_model => $model, context => { button_validate_picking_ids => [$pid], %skip } } };
    if ( !grep { ( $_->{qty_done} // 0 ) > 0 } @lines ) {
        die "fake: a picking without done quantities opens the immediate-transfer wizard\n" if !@moves;
        return $action->('stock.immediate.transfer') if !$skip{skip_immediate};
    }
    if ( !$skip{skip_backorder} ) {
        for my $m (@moves) {
            my $done = 0;
            $done += $_->{qty_done} // 0 for grep { ( $_->{move_id} // 0 ) == $m->{id} } @lines;
            return $action->('stock.backorder.confirmation') if $done + 0.001 < ( $m->{product_uom_qty} // 0 );
        }
    }
    if ( !$skip{skip_expired} ) {
        for my $l ( grep { ( $_->{qty_done} // 0 ) > 0 && $_->{lot_id} } @lines ) {
            my $lot = $fk->record( 'stock.lot', $l->{lot_id} );
            next if !$lot->{expiration_date} || ( $lot->{create_date} // '' ) eq $lot->{expiration_date};
            return $action->('expiry.picking.confirmation') if $lot->{expiration_date} lt '2026-10-13 00:00:00';
        }
    }
    for my $l (@lines) {
        next if ( $l->{state} // '' ) eq 'done' || !( $l->{qty_done} // 0 );
        _move_quant( $fk, $l->{product_id}, $l->{lot_id}, $l->{location_id}, $l->{package_id}, -$l->{qty_done} );
        _move_quant( $fk, $l->{product_id}, $l->{lot_id}, $l->{location_dest_id}, $l->{result_package_id}, $l->{qty_done} );
        $l->{state} = 'done';
    }
    # SA8: a package the transfer puts stock into may not end up in two locations
    my %where;
    for my $q ( values %{ $fk->{data}{'stock.quant'} } ) {
        next if !$q->{package_id} || abs( $q->{quantity} ) < 0.001;
        $where{ $q->{package_id} }{ $q->{location_id} } = 1;
    }
    for my $pk2 ( keys %where ) {
        die "fake: You cannot move the same package content more than once in the same transfer or split the same package into two location.\n"
            if keys %{ $where{$pk2} } > 1 && grep { ( $_->{result_package_id} // 0 ) == $pk2 } @lines;
    }
    for my $m (@moves) {
        my $done = 0;
        $done += $_->{qty_done} // 0 for grep { ( $_->{move_id} // 0 ) == $m->{id} } @lines;
        $m->{quantity_done} = $done;
        $m->{state} = $done > 0 || !@lines ? 'done' : 'cancel';
    }
    $pk->{state} = 'done';
    $pk->{date_done} = '2026-10-13 12:00:00';
    if ( my $push = delete $fk->{push}{$pid} ) {
        # the push rule: a delivery for what the pick moved, its moves carrying the sale lines
        my $did = $fk->insert( 'stock.picking', { name => "WH/OUT/$push->{num}", origin => $pk->{origin}, state => 'assigned', picking_type_id => 2,
            location_id => 3, location_dest_id => 4, partner_id => 1, sale_id => $push->{order}, create_date => '2026-10-13 12:00:00' } );
        push @{ $fk->record( 'sale.order', $push->{order} )->{picking_ids} }, $did;
        for my $m ( grep { ( $_->{quantity_done} // 0 ) > 0 } @moves ) {
            my $dm = $fk->insert( 'stock.move', { name => "out $m->{product_id}", product_id => $m->{product_id}, product_uom_qty => $m->{quantity_done}, quantity_done => 0,
                product_uom => 1, location_id => 3, location_dest_id => 4, picking_id => $did, state => 'assigned', sale_line_id => $m->{sale_line_id},
                move_orig_ids => [ $m->{id} ], move_dest_ids => [], move_line_ids => [] } );
            push @{ $m->{move_dest_ids} }, $dm;
        }
    }
    _recompute_delivered($fk);
    return JSON::PP::true;
}

# qty_delivered of a sale line: done moves on outgoing pickings linked to it
sub _recompute_delivered ($fk) {
    for my $sl ( values %{ $fk->{data}{'sale.order.line'} } ) {
        my $q = 0;
        for my $m ( values %{ $fk->{data}{'stock.move'} } ) {
            next if ( $m->{sale_line_id} // 0 ) != $sl->{id} || ( $m->{state} // '' ) ne 'done';
            my $pk = $m->{picking_id} ? $fk->record( 'stock.picking', $m->{picking_id} ) : undef;
            my $type = $pk ? $fk->record( 'stock.picking.type', $pk->{picking_type_id} ) : undef;
            $q += $m->{quantity_done} // 0 if $type && $type->{code} eq 'outgoing';
        }
        $sl->{qty_delivered} = $q;
    }
    return;
}

# --- sales: lots, stock and orders for the dispatch tests -------------------------
# Lots 4 LA, 5 LB (C40), 6 LX (C40, expired), 7 LN (C40, expiration equals its creation: never given
# one, SC4), 8 L9 (P30). Packages 11, 12. Quants 101-108 (ids over 100):
#   101 LA loose 40 in WH/Stock        102 LA in PAL-11 100 in Bay A       103 LB loose 20 in WH/Stock
#   104 LB in PAL-12 60 in WH/Stock    105 LX loose 30                     106 LN loose 10
#   107 L9 loose 50                    108 LA loose 25 in WH/Output
sub add_stock_for_sales ($fk) {
    $fk->insert( 'stock.quant.package', { id => $_, name => "PAL-$_" } ) for 11, 12;
    $fk->insert( 'stock.lot', $_ ) for
        { id => 4, name => 'LA', product_id => 1, create_date => '2026-06-01 09:00:00' },
        { id => 5, name => 'LB', product_id => 1, create_date => '2026-06-01 09:00:00' },
        { id => 6, name => 'LX', product_id => 1, create_date => '2025-12-01 09:00:00', expiration_date => '2026-01-01 00:00:00' },
        { id => 7, name => 'LN', product_id => 1, create_date => '2026-03-01 10:00:00', expiration_date => '2026-03-01 10:00:00' },
        { id => 8, name => 'L9', product_id => 2, create_date => '2026-06-01 09:00:00' };
    my $q = sub ($id, $product, $lot, $loc, $pkg, $qty) {
        $fk->insert( 'stock.quant', { id => $id, product_id => $product, lot_id => $lot, location_id => $loc, package_id => $pkg, quantity => $qty, reserved_quantity => 0 } );
    };
    $q->( 101, 1, 4, 1, undef, 40 );  $q->( 102, 1, 4, 5, 11, 100 );  $q->( 103, 1, 5, 1, undef, 20 );
    $q->( 104, 1, 5, 1, 12, 60 );     $q->( 105, 1, 6, 1, undef, 30 ); $q->( 106, 1, 7, 1, undef, 10 );
    $q->( 107, 2, 8, 1, undef, 50 );  $q->( 108, 1, 4, 3, undef, 25 );
    return $fk;
}

# One sale order with its delivery and (unless steps => 1) its pick, moves chained pick -> delivery.
#   add_order($fake, name => 'S00123', lines => [ [ product, qty ], ... ],
#       reserve => { product => [ [ quant, qty ], ... ] },    # lines the pick holds, reserved on the quants
#       pick_state => 'done', invoices => 1, extra_out => 1, steps => 1 )
# Returns { order, pick, delivery, lines => { product => sale line }, pick_moves => {...}, out_moves => {...} }.
sub add_order ($fk, %o) {
    my $num = $o{name} =~ s/\D//gr;
    my $two = ( $o{steps} // 2 ) == 2;
    my $oid = $fk->insert( 'sale.order', { name => $o{name}, state => 'sale', partner_id => 1, date_order => '2026-09-01 10:00:00',
        invoice_ids => [ map { 900 + $_ } 1 .. ( $o{invoices} // 0 ) ], order_line => [], picking_ids => [] } );
    my $pick_done = ( $o{pick_state} // '' ) eq 'done';
    my $src = $two ? 3 : 1;
    my $push = $o{push};    # Odoo 19: no delivery until the pick is validated; a push rule then makes it
    my $did = $push ? undef : $fk->insert( 'stock.picking', { name => "WH/OUT/$num", origin => $o{name}, state => ( $two && !$pick_done ? 'waiting' : 'assigned' ), picking_type_id => 2,
        location_id => $src, location_dest_id => 4, partner_id => 1, sale_id => $oid, create_date => '2026-09-01 10:00:00' } );
    my $pid = $two ? $fk->insert( 'stock.picking', { name => "WH/PICK/$num", origin => $o{name}, state => ( $pick_done ? 'done' : 'assigned' ), picking_type_id => 1,
        location_id => 1, location_dest_id => 3, partner_id => 1, sale_id => $oid, create_date => '2026-09-01 10:00:00' } ) : undef;
    $fk->{push}{$pid} = { order => $oid, num => $num } if $push;
    my @pickings = grep { defined } ( $pid, $did );
    if ( $o{extra_out} ) {
        push @pickings, $fk->insert( 'stock.picking', { name => "WH/OUT/$num-B", origin => $o{name}, state => 'assigned', picking_type_id => 2, location_id => $src, location_dest_id => 4, sale_id => $oid } );
    }
    $fk->record( 'sale.order', $oid )->{picking_ids} = \@pickings;
    my ( %sol, %pm, %dm );
    for my $l ( @{ $o{lines} } ) {
        my ( $product, $qty ) = @$l;
        my $sl = $fk->insert( 'sale.order.line', { order_id => $oid, product_id => $product, product_uom_qty => $qty, qty_delivered => 0, qty_invoiced => 0 } );
        push @{ $fk->record( 'sale.order', $oid )->{order_line} }, $sl;
        $sol{$product} = $sl;
        my $dm = $push ? undef : $fk->insert( 'stock.move', { name => "out $product", product_id => $product, product_uom_qty => $qty, quantity_done => 0, product_uom => 1,
            location_id => $src, location_dest_id => 4, picking_id => $did, state => ( $two && !$pick_done ? 'waiting' : 'assigned' ), sale_line_id => $sl, move_orig_ids => [], move_dest_ids => [], move_line_ids => [] } );
        $dm{$product} = $dm if $dm;
        next if !$two;
        my $pm = $fk->insert( 'stock.move', { name => "pick $product", product_id => $product, product_uom_qty => $qty, quantity_done => ( $pick_done ? $qty : 0 ), product_uom => 1,
            location_id => 1, location_dest_id => 3, picking_id => $pid, state => ( $pick_done ? 'done' : 'assigned' ), move_orig_ids => [], move_dest_ids => ( $dm ? [$dm] : [] ), move_line_ids => [],
            ( $push ? ( sale_line_id => $sl ) : () ) } );
        $fk->record( 'stock.move', $dm )->{move_orig_ids} = [$pm] if $dm;
        $pm{$product} = $pm;
        for my $r ( @{ $o{reserve}{$product} // [] } ) {
            my $quant = $fk->record( 'stock.quant', $r->[0] );
            $quant->{reserved_quantity} += $r->[1];
            my $ml = $fk->insert( 'stock.move.line', { product_id => $product, lot_id => $quant->{lot_id}, package_id => $quant->{package_id}, location_id => $quant->{location_id},
                location_dest_id => 3, reserved_uom_qty => $r->[1], qty_done => 0, move_id => $pm, picking_id => $pid, state => 'assigned',
                create_date => '2026-09-01 10:00:30', create_uid => 2, write_date => '2026-09-01 10:00:30', write_uid => 2 } );
            push @{ $fk->record( 'stock.move', $pm )->{move_line_ids} }, $ml;
        }
    }
    return { order => $oid, pick => $pid, delivery => $did, lines => \%sol, pick_moves => \%pm, out_moves => \%dm };
}

# find or create the quant for product/lot/location/package and add the quantity
sub _move_quant ($fk, $product, $lot, $location, $package, $delta) {
    my ($q) = grep { $_->{product_id} == $product && ( $_->{lot_id} // 0 ) == ( $lot // 0 ) && $_->{location_id} == $location && ( $_->{package_id} // 0 ) == ( $package // 0 ) }
        values %{ $fk->{data}{'stock.quant'} };
    if ( !$q ) {
        my $id = $fk->insert( 'stock.quant', { product_id => $product, lot_id => $lot, location_id => $location, package_id => $package, quantity => 0, reserved_quantity => 0 } );
        $q = $fk->record( 'stock.quant', $id );
    }
    $q->{quantity} += $delta;
    return;
}

1;
