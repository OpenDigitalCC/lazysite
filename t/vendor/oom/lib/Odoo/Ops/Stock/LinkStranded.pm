package Odoo::Ops::Stock::LinkStranded;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();
use Scalar::Util qw(blessed);
use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Profile;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Stock::LinkStranded - put stranded pick stock through to the order's done delivery

=head1 SYNOPSIS

    oom-ops run stock.link-stranded --conf ops.conf --set orders=S02591,S02577
    oom-ops apply --conf ops.conf --plan plan.json

=head1 DESCRIPTION

The shape it repairs (SA3): a line added to a pick that is already
done becomes a stand-alone done move into the output location with no
sale line and no onward move. The goods sit in output, the sale
line's C<qty_delivered> never moves, nothing reaches the invoice.

For each order (C<orders=>, a list of names, or C<rows=>, a file of
C<{ key, values: { order, date? } }>) the plan finds the stranded moves
- done, no sale line, no onward move, on a non-outgoing transfer of the
order, ending where the delivery starts - and plans one change of kind
C<link> per stranded move: the delivery, the product, the lots and
quantities of the stranded move's lines, the sale line, and the
C<qty_delivered> expected afterwards.

Buckets: C<link>, and the holds C<no-order>, C<no-stranded>,
C<invoiced> (SA4), C<no-sale-line> (the product has no single sale
line on the order, or the sale line sits on no single delivery),
C<delivery-not-done> (validate it normally instead), C<not-free> (the
stock is no longer free in output), C<over-delivery> (C<allow_over=1>
permits) and C<already-linked> (the delivery already carries an
unlinked extra move for the product). An order that is held as a
whole counts one row; an order with stranded moves counts one row per
move.

Apply creates the move lines on the done delivery (Odoo makes a done
move of each, and moves the goods from output to the customer), then
sets the sale line and the stranded move as the origin on each new
move, backdates it to the delivery's C<date_done> (or C<date=>), posts
an internal note on the delivery and reads back the sale line's
C<qty_delivered>. It is irreversible.

=cut

sub op_name ($class) { 'stock.link-stranded' }
sub summary ($class) { 'Plan the linking of stranded pick stock (a line added to a done pick) to the order\'s done delivery' }
sub pack    ($class) { 'stock' }
sub params ($class) {
    {   orders     => { type => 'list', help => 'sale order names' },
        rows       => { type => 'path', help => 'orders file: .jsonl of { key, values: { order, date? } }' },
        allow_over => { type => 'bool', default => 0, help => 'permit a delivery that exceeds the ordered quantity' },
        date       => { type => 'str',  help => 'backdate to YYYY-MM-DD (default: the delivery\'s own done date)' },
        note       => { type => 'str',  help => 'text added to the delivery\'s note' },
    };
}
sub read_scope ($class) {
    {   order     => [qw(search_read read)],
        sale_line => [qw(search_read read)],
        picking   => [qw(search_read read)],
        picking_type => ['search_read'],
        move      => [qw(search_read read)],
        move_line => [qw(search_read read)],
        quant     => ['search_read'],
        'product.product' => ['read'],
    };
}
sub write_scope ($class) {
    {   picking   => [qw(message_post)],
        move      => [qw(write)],
        move_line => [qw(create write read)],
    };
}

my $EPS = 0.001;

sub plan ($self) {
    my $p = $self->profile;
    my $v = $p->validate( $self->client );
    Odoo::Error->throw( kind => 'refused', code => 'profile', message => 'stock profile does not match this server: ' . join( '; ', @{ $v->{missing} } ) ) if !$v->{ok};
    my @in = grep { defined $self->param($_) } qw(orders rows);
    Odoo::Error->throw( kind => 'usage', message => 'stock.link-stranded: give exactly one of orders, rows (got ' . ( @in ? "@in" : 'none' ) . ')' ) if @in != 1;
    my $date = $self->param('date');
    Odoo::Error->throw( kind => 'usage', message => "stock.link-stranded: date '$date' is not YYYY-MM-DD" ) if defined $date && $date !~ /^\d{4}-\d\d-\d\d\z/;
    my @orders = $self->_orders;
    my $plan = $self->new_plan;    # input_count is set once the stranded moves are counted
    my $count = 0;
    $count += $self->_plan_order( $plan, $_ ) for @orders;
    $plan->set_input_count($count);
    $plan->note( 'orders considered: ' . scalar(@orders) . '; rows planned: ' . $count );
    return $plan;
}

sub _orders ($self) {
    return map { +{ key => $_, order => $_ } } @{ $self->param('orders') } if defined $self->param('orders');
    my $path = $self->param('rows');
    open my $fh, '<:raw', $path or Odoo::Error->throw( kind => 'config', message => "stock.link-stranded: cannot read $path: $!" );
    my @out;
    while ( my $line = <$fh> ) {
        next if $line !~ /\S/;
        my $d = eval { Odoo::Ops::json()->decode($line) } // Odoo::Error->throw( kind => 'config', message => "$path line $.: not JSON" );
        my $val = ref $d->{values} eq 'HASH' ? $d->{values} : $d;
        push @out, { key => $d->{key} // $val->{order}, order => $val->{order}, date => $val->{date}, held => $d->{held} };
    }
    close $fh;
    return @out;
}

# returns the number of plan rows it added
sub _plan_order ($self, $plan, $o) {
    my $f = sub ($lm, $lf) { $self->profile->field( $lm => $lf ) };
    my $name = $o->{order};
    my $hold = sub ($bucket, $reason) {
        $plan->add( bucket => $bucket, action => 'hold', key => "link:$o->{key}", reason => $reason );
        return 1;
    };
    if ( my $h = $o->{held} ) { my ($k) = $h =~ /^(\w+):/; return $hold->( 'held-' . ( $k // 'flag' ), $h ) }
    return $hold->( 'no-order', 'row names no order' ) if !defined $name || $name eq '';
    my $orders = $self->model('order')->search_read( [ [ $f->( order => 'name' ), '=', $name ] ], [ 'id', $f->( order => 'pickings' ) ] );
    return $hold->( 'no-order', "no sale order named $name" ) if @$orders != 1;
    my $so = $orders->[0];

    # SA4: any invoice, draft or posted, makes the recompute read account.move.line
    my $inv = eval { $self->model('order')->read_one( $so->{id}, [ $f->( order => 'invoices' ) ] )->{ $f->( order => 'invoices' ) } };
    return $hold->( 'invoiced', "$name has invoice records this user cannot read: delete the draft first, or link with accounting read access" ) if !defined $inv;
    return $hold->( 'invoiced', "$name has " . scalar(@$inv) . ' invoice(s): delete the draft first, or link with accounting read access' ) if @$inv;

    my $pids = $so->{ $f->( order => 'pickings' ) } // [];
    my $pickings = @$pids ? $self->model('picking')->search_read( [ [ 'id', 'in', $pids ] ], [ map { $f->( picking => $_ ) } qw(name state type source destination done_at) ] ) : [];
    my %code = map { $_->{id} => $_->{code} } @{ @$pickings ? $self->model('picking_type')->search_read( [ [ 'id', 'in', [ map { _id( $_->{ $f->( picking => 'type' ) } ) } @$pickings ] ] ], [ 'id', $f->( picking_type => 'code' ) ] ) : [] };
    my $state = $f->( picking => 'state' );
    my $code  = sub ($pk) { $code{ _id( $pk->{ $f->( picking => 'type' ) } ) } // '' };
    my @outs   = grep { $code->($_) eq 'outgoing' && $_->{$state} ne 'cancel' } @$pickings;
    my @others = grep { $code->($_) ne 'outgoing' && $_->{$state} ne 'cancel' } @$pickings;
    my %out_src = map { _id( $_->{ $f->( picking => 'source' ) } ) => 1 } @outs;

    my $mf = sub ($x) { $f->( move => $x ) };
    my $moves = @others ? $self->model('move')->search_read( [ [ $mf->('picking'), 'in', [ map { $_->{id} } @others ] ], [ $mf->('state'), '=', 'done' ] ],
        [ map { $mf->($_) } qw(picking product destination sale_line dest_moves move_lines) ] ) : [];
    my @stranded = grep { !_id( $_->{ $mf->('sale_line') } ) && !@{ $_->{ $mf->('dest_moves') } // [] } && $out_src{ _id( $_->{ $mf->('destination') } ) // 0 } } @$moves;
    return $hold->( 'no-stranded', "$name has no stranded moves" ) if !@stranded;

    my @sols = grep { _id( $_->{ $f->( sale_line => 'product' ) } ) } @{ $self->model('sale_line')->search_read( [ [ $f->( sale_line => 'order' ), '=', $so->{id} ] ],
        [ 'id', map { $f->( sale_line => $_ ) } qw(product ordered delivered) ] ) };
    my $out_moves = @outs ? $self->model('move')->search_read( [ [ $mf->('picking'), 'in', [ map { $_->{id} } @outs ] ] ],
        [ map { $mf->($_) } qw(picking product sale_line state) ] ) : [];

    my $lf = sub ($x) { $f->( move_line => $x ) };
    my %cum;      # sale line -> quantity added by earlier moves of this plan
    my $date = $o->{date} // $self->param('date');
    my $n = 0;
    for my $m ( sort { $a->{id} <=> $b->{id} } @stranded ) {
        $n++;
        my $key  = "link:$o->{key}:move$m->{id}";
        my $pid  = _id( $m->{ $mf->('product') } );
        my $pname = _label( $m->{ $mf->('product') } );
        my $mhold = sub ($bucket, $reason) { $plan->add( bucket => $bucket, action => 'hold', key => $key, reason => "$name move $m->{id} ($pname): $reason" ); return };
        my @cands = grep { _id( $_->{ $f->( sale_line => 'product' ) } ) == $pid } @sols;
        if ( @cands != 1 ) { $mhold->( 'no-sale-line', scalar(@cands) . ' sale lines for the product' ); next }
        my $sol = $cands[0];
        my %del = map { _id( $_->{ $mf->('picking') } ) => 1 } grep { ( _id( $_->{ $mf->('sale_line') } ) // 0 ) == $sol->{id} } @$out_moves;
        my @dels = grep { $del{ $_->{id} } } @outs;
        if ( @dels != 1 ) { $mhold->( 'no-sale-line', scalar(@dels) . ' deliveries carry the sale line' ); next }
        my $d = $dels[0];
        my $dname = $d->{ $f->( picking => 'name' ) };
        if ( $d->{$state} ne 'done' ) { $mhold->( 'delivery-not-done', "$dname is $d->{$state}, not done: validate it normally" ); next }
        my @loose = grep { _id( $_->{ $mf->('picking') } ) == $d->{id} && _id( $_->{ $mf->('product') } ) == $pid && !_id( $_->{ $mf->('sale_line') } ) && $_->{ $mf->('state') } eq 'done' } @$out_moves;
        if (@loose) { $mhold->( 'already-linked', "$dname already carries unlinked done move(s) " . join( ', ', map { $_->{id} } @loose ) . ' for the product: check by hand' ); next }

        my $lines = $self->model('move_line')->read( $m->{ $mf->('move_lines') }, [ map { $lf->($_) } qw(lot result_package done) ] );
        my @ln = map { +{ lot => _id( $_->{ $lf->('lot') } ), lot_name => _label( $_->{ $lf->('lot') } ),
            package => _id( $_->{ $lf->('result_package') } ), package_name => _label( $_->{ $lf->('result_package') } ), quantity => $_->{ $lf->('done') } } }
            grep { ( $_->{ $lf->('done') } // 0 ) > $EPS } @$lines;
        my $qty = 0;
        $qty += $_->{quantity} for @ln;
        if ( !@ln ) { $mhold->( 'not-free', 'the stranded move has no done lines' ); next }

        # the stock must still be free where the stranded move left it
        my $loc = _id( $m->{ $mf->('destination') } );
        my ( $short, $free_text );
        for my $l (@ln) {
            my $quants = $self->model('quant')->search_read(
                [ [ $f->( quant => 'location' ), '=', $loc ], [ $f->( quant => 'product' ), '=', $pid ],
                  [ $f->( quant => 'lot' ), '=', ( $l->{lot} ? $l->{lot} : JSON::PP::false ) ],
                  [ $f->( quant => 'package' ), '=', ( $l->{package} ? $l->{package} : JSON::PP::false ) ] ],
                [ map { $f->( quant => $_ ) } qw(quantity reserved) ] );
            my $free = 0;
            $free += $_->{ $f->( quant => 'quantity' ) } - ( $_->{ $f->( quant => 'reserved' ) } // 0 ) for @$quants;
            if ( $free + $EPS < $l->{quantity} ) { $short = 1; $free_text = ( $l->{lot_name} // 'no lot' ) . ": " . _g($free) . ' free, ' . _g( $l->{quantity} ) . ' needed'; last }
        }
        if ($short) { $mhold->( 'not-free', "the stock is no longer free in " . _label( $m->{ $mf->('destination') } ) . " ($free_text)" ); next }

        my $ordered = $sol->{ $f->( sale_line => 'ordered' ) };
        my $before  = $sol->{ $f->( sale_line => 'delivered' ) } + ( $cum{ $sol->{id} } // 0 );
        my $after   = $before + $qty;
        if ( $after > $ordered + $EPS && !$self->param('allow_over') ) {
            $mhold->( 'over-delivery', "delivered " . _g($before) . " + " . _g($qty) . " = " . _g($after) . " exceeds ordered " . _g($ordered) . ' (allow_over=1 permits)' );
            next;
        }
        $cum{ $sol->{id} } += $qty;
        my $stamp = defined $date ? "$date 12:00:00" : $d->{ $f->( picking => 'done_at' ) };
        $plan->add(
            bucket => 'link', action => 'custom', handler => $self->op_name, kind => 'link',
            model => $self->physical_model('picking'), id => $d->{id}, key => $key,
            before => { $state => 'done' },
            reason => "$name: $pname " . _g($qty) . " ("
                . join( ', ', map { ( $_->{lot_name} // 'no lot' ) . '=' . _g( $_->{quantity} ) } @ln )
                . ") from " . _label( $m->{ $mf->('destination') } ) . " (stranded move $m->{id} on " . _label( $m->{ $mf->('picking') } ) . ") onto $dname, sale line $sol->{id}: delivered " . _g($before) . ' to ' . _g($after),
            vals => {
                order => $name, delivery => { id => $d->{id}, name => $dname },
                product => $pid, product_name => $pname,
                stranded_move => $m->{id}, stranded_picking => _label( $m->{ $mf->('picking') } ),
                from => $loc, from_name => _label( $m->{ $mf->('destination') } ),
                to => _id( $d->{ $f->( picking => 'destination' ) } ),
                sale_line => $sol->{id}, lines => \@ln,
                delivered_before => 0 + _g($before), delivered_after => 0 + _g($after),
                date => $stamp, note => $self->param('note'),
            },
            irreversible => 'a done move is undone by a return, a separate write (stock.link-stranded has no inverse)',
        );
    }
    return $n;
}

# --- apply -----------------------------------------------------------------

sub undo_custom ($class, $entry) {
    return ( undef, 'undone by a return picking - plan one with stock.return' );
}

sub apply_custom ($class, $client, $c) {
    Odoo::Error->throw( kind => 'usage', message => "stock.link-stranded cannot apply kind '$c->{kind}'" ) if ( $c->{kind} // '' ) ne 'link';
    my $p = Odoo::Ops::Profile->load( pack => 'stock', series => $client->server_series );
    my @did;
    my $out = eval { $class->_apply( $client, $p, $c->{vals}, \@did ) };
    if ( !$out ) {
        my $e = $@;
        my ( $kind, $msg ) = blessed($e) && $e->isa('Odoo::Error') ? ( $e->kind, $e->message ) : ( 'fault', "$e" );
        $msg =~ s/\s+\z//;
        Odoo::Error->throw( kind => $kind, message => "$msg; done before the failure: " . ( @did ? join( '; ', @did ) : 'nothing' ) . ' (nothing is rolled back)' );
    }
    return $out;
}

sub _apply ($class, $client, $p, $v, $did) {
    my $f = sub ($lm, $lf) { $p->has_field( $lm => $lf ) ? $p->field( $lm => $lf ) : undef };
    my $sale = $client->model( $p->model_name('sale_line') );
    my $dcol = $f->( sale_line => 'delivered' );
    my $now  = $sale->read_one( $v->{sale_line}, [$dcol] );
    Odoo::Error->throw( kind => 'refused', code => 'stale', message => "sale line $v->{sale_line} now reads delivered " . ( $now ? $now->{$dcol} : 'gone' ) . ", planned from $v->{delivered_before}: re-plan" )
        if !$now || abs( $now->{$dcol} - $v->{delivered_before} ) > $EPS;

    my $move = $client->model( $p->model_name('move') );
    my $line = $client->model( $p->model_name('move_line') );
    my $prod = $client->model('product.product')->read_one( $v->{product}, ['uom_id'] );
    my $uom  = $prod->{uom_id}[0];
    my $stamp = $v->{date};
    my $stranded = $v->{stranded_move};
    my @new;
    for my $l ( @{ $v->{lines} } ) {
        my %ml = (
            $f->( move_line => 'picking' )     => $v->{delivery}{id},
            $f->( move_line => 'product' )     => $v->{product},
            $f->( move_line => 'source' )      => $v->{from},
            $f->( move_line => 'destination' ) => $v->{to},
            $f->( move_line => 'done' )        => $l->{quantity},
            product_uom_id                     => $uom,
        );
        $ml{ $f->( move_line => 'lot' ) }     = $l->{lot}     if $l->{lot};
        $ml{ $f->( move_line => 'package' ) } = $l->{package} if $l->{package};
        $ml{ $f->( move_line => 'picked' ) }  = JSON::PP::true if $f->( move_line => 'picked' );
        my $id = $line->create( \%ml );
        $id = $id->[0] if ref $id eq 'ARRAY';
        my $row = $line->read_one( $id, [ $f->( move_line => 'move' ) ] );
        my $mid = $row && ref $row->{ $f->( move_line => 'move' ) } ? $row->{ $f->( move_line => 'move' ) }[0] : undef;
        Odoo::Error->throw( kind => 'fault', message => "the line created on $v->{delivery}{name} made no move" ) if !$mid;
        # link at once: an unlinked done delivery move is the shape the plan holds on
        my %w = ( $f->( move => 'sale_line' ) => $v->{sale_line}, $f->( move => 'origin_moves' ) => [ [ 4, $stranded ] ] );
        $w{ $f->( move => 'date' ) } = $stamp if defined $stamp;
        $move->write( $mid, \%w );
        $line->write( $id, { $f->( move_line => 'date' ) => $stamp } ) if defined $stamp;
        push @new, { move => $mid, line => $id, lot => $l->{lot_name}, quantity => $l->{quantity} };
        push @$did, "line $id and move $mid on $v->{delivery}{name}";
    }
    my $picking = $client->model( $p->model_name('picking') );
    my $u = $client->model('res.users')->read_one( $client->uid, [ 'email', 'partner_id' ] ) // {};
    my $h = sub ($s) { ( $s // '' ) =~ s/&/&amp;/gr =~ s/</&lt;/gr =~ s/>/&gt;/gr };
    my $body = '<p><b>' . $h->("Stranded pick stock linked to this delivery ($v->{order})") . '</b></p><ul><li>'
        . $h->( "$v->{product_name} " . _g( $v->{delivered_after} - $v->{delivered_before} ) . ' (' . join( ', ', map { ( $_->{lot} // 'no lot' ) . '=' . _g( $_->{quantity} ) } @new )
            . ") from $v->{stranded_picking} move $stranded (left in $v->{from_name}), now delivered on sale line $v->{sale_line}" )
        . '</li>' . ( defined $v->{note} && length $v->{note} ? '<li>' . $h->( $v->{note} ) . '</li>' : '' )
        . '</ul><p>These lines were added to the pick after it was done, so Odoo left the goods in output and off the order. Recorded by stock.link-stranded.</p>';
    $picking->call( 'message_post', [ [ $v->{delivery}{id} ] ], body => $body, message_type => 'comment', subtype_xmlid => 'mail.mt_note',
        ( ref $u->{partner_id} ? ( author_id => $u->{partner_id}[0] ) : () ), email_from => ( $u->{email} || 'noreply@oom.invalid' ) );
    push @$did, 'noted';

    my $after = $sale->read_one( $v->{sale_line}, [$dcol] )->{$dcol};
    my $ok = abs( $after - $v->{delivered_after} ) <= $EPS;
    return { id => $v->{delivery}{id}, after => ( $ok ? { delivered => $after, moves => \@new } : undef ), returned => $v->{delivery}{name} };
}

sub _id    ($v) { ref $v eq 'ARRAY' ? $v->[0] : ( $v ? $v : undef ) }
sub _label ($v) { ref $v eq 'ARRAY' ? $v->[1] : undef }
sub _g     ($n) { 0 + sprintf( '%.3f', $n ) }

1;
