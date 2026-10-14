package Odoo::Ops::Stock::Dispatch;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();
use Scalar::Util qw(blessed);
use Time::Local qw(timegm);
use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Profile;
use Odoo::Ops::Stock::Validate;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Stock::Dispatch - record dispatches that happened without being recorded

=head1 SYNOPSIS

    oom-ops run stock.dispatch --conf ops.conf --set rows=orders.jsonl
    oom-ops apply --conf ops.conf --plan plan.json

=head1 DESCRIPTION

C<stock.dispatch> takes rows already in its own shape, one per sale
order, from C<rows=> (a C<.jsonl> or C<.json> file) or C<records=> (a
list, for a program):

    { "key": "S00123", "values": {
        "order": "S00123", "date": "2026-09-07",
        "lines": [ { "product": "C40", "qty": 120, "lots": { "L1": 70, "L2": 50 } },
                   { "product": "P30", "qty": 10,  "lots": { "L3": 10 } } ],
        "note":  "Loading sheet 2026-09-07, answered by J.S.",
        "allow": [ "expired", "stage-out" ] } }

C<product> is C<default_code>; C<lots> maps lot names to quantities
(their sum is what the paper says left; a line without lots is C<qty>
of lot-free stock); C<date> is the paper's dispatch date; C<allow>
names the holds the owner has ruled through for this order
(C<expired>, C<stage-out>, C<reserved>); C<note> goes on the
transfers' chatter. A row carrying C<held> is held with that reason
(bucket C<held-E<lt>kindE<gt>>), as Source rows are. The portal is a
Source's business; this operation reads no portal.

Per order the plan finds the sale order, its pick and delivery, the
move of each paper line, and chooses the quants each lot quantity is
drawn from - one pool per lot drawn down across the lines; tiers in
order: stock the move already reserves, free stock, stock another move
reserved; within a tier loose before packages, largest first; output
locations never count as available for a pick (SE4). A partial take
from a package arrives loose, so the package is never split (SA8, SE2).
One C<custom> change of kind C<dispatch> carries the whole staged plan.

Buckets: C<dispatch>, and the holds C<no-order>, C<invoiced> (SA4),
C<multi-out>, C<no-delivery>, C<already-done>, C<stage-out>,
C<quantity-differs>, C<no-move>, C<reserved>, C<shortfall>,
C<expired>, C<paper-date>, C<staff-edit>, C<blocker> and
C<held-*>. Buckets sum to the row count; a row with several problems
lands in the first and its reason names all of them.

Apply, for one order and stopping at the first failure (nothing is
rolled back; the failure names what was done): stage the paper's
lines on the pick, validate it, stage the same lots on the delivery
and validate it (wizards: see L<Odoo::Ops::Stock::Validate>),
backdate both transfers, their moves and lines to the paper date
(SC6), post an internal note on each (SD1), and read back both
pickings and each sale line's C<qty_delivered> (SC1: the delta is the
paper quantity). A dispatch is irreversible: a validated picking is
undone by a return, a separate write.

=cut

sub op_name ($class) { 'stock.dispatch' }
sub summary ($class) { 'Plan the recording of dispatches that left without being recorded: stage, validate, backdate, note' }
sub pack    ($class) { 'stock' }
sub params ($class) {
    {   rows    => { type => 'path', help => 'orders file: .jsonl or .json (a list) of { key, values: { order, date, lines, note, allow }, held? }' },
        records => { type => 'json', help => 'in-process rows (a list) - for a program, not the command line' },
    };
}
sub read_scope ($class) {
    {   order        => [qw(search_read read)],
        sale_line    => [qw(search_read read)],
        picking      => [qw(search_read read)],
        picking_type => ['search_read'],
        move         => [qw(search_read read)],
        move_line    => [qw(search_read read)],
        quant        => ['search_read'],
        lot          => ['search_read'],
        location     => ['search_read'],
        'product.product' => ['search_read'],
    };
}
sub write_scope ($class) {
    {   picking        => [qw(write action_assign button_validate message_post)],
        move           => [qw(search write)],
        move_line      => [qw(search create unlink write)],
        backorder_wizard => [qw(create process_cancel_backorder)],
        'expiry.picking.confirmation' => [qw(create process)],
    };
}

my $EPS = 0.001;
my $STAFF_EDIT_GRACE = 120;    # seconds between a line being made and written that still count as the system
my %ALLOW = map { $_ => 1 } qw(expired stage-out reserved);

# --- plan ------------------------------------------------------------------

sub plan ($self) {
    my $p = $self->profile;
    my $v = $p->validate( $self->client );
    Odoo::Error->throw( kind => 'refused', code => 'profile', message => 'stock profile does not match this server: ' . join( '; ', @{ $v->{missing} } ) ) if !$v->{ok};
    my @in = grep { defined $self->param($_) } qw(records rows);
    Odoo::Error->throw( kind => 'usage', message => 'stock.dispatch: give exactly one of records, rows (got ' . ( @in ? "@in" : 'none' ) . ')' ) if @in != 1;
    my $rows = $self->_rows;
    my $plan = $self->new_plan( input_count => scalar @$rows );
    my $env  = $self->_environment;
    $plan->note( 'orders considered: ' . scalar(@$rows) . '; acting user ' . ( $env->{email} ? "has email $env->{email}" : 'has no email address (SA1)' ) );
    for my $row (@$rows) { $self->_plan_row( $plan, $env, $row ) }
    return $plan;
}

sub _f ($self, $lm, $lf) { $self->profile->field( $lm => $lf ) }

sub _environment ($self) {
    my $uid = $self->client->uid;
    my $u   = $self->client->model('res.users')->read_one( $uid, [ 'email', 'partner_id' ] ) // {};
    my $f   = sub ($lf) { $self->_f( location => $lf ) };
    my $locs = $self->model('location')->search_read( [], [ 'id', $f->('parent'), $f->('usage'), $f->('complete_name') ] );
    my %kids;
    my %loc = map { $_->{id} => $_ } @$locs;
    for my $l (@$locs) {
        my $par = ref $l->{ $f->('parent') } ? $l->{ $f->('parent') }[0] : 0;
        push @{ $kids{$par} }, $l->{id} if $par;
    }
    return {
        uid     => $uid,
        email   => ( $u->{email} ? $u->{email} : undef ),
        partner => ( ref $u->{partner_id} ? $u->{partner_id}[0] : undef ),
        loc     => \%loc,
        kids    => \%kids,
        now     => Odoo::Ops::iso_time( $self->ctx->now ) =~ s/T/ /r =~ s/Z\z//r,
    };
}

# the location and every location under it
sub _subtree ($env, $id) {
    my ( @out, @todo ) = ();
    @todo = ($id);
    my %seen;
    while ( defined( my $i = shift @todo ) ) {
        next if $seen{$i}++;
        push @out, $i;
        push @todo, @{ $env->{kids}{$i} // [] };
    }
    return @out;
}

sub _plan_row ($self, $plan, $env, $row) {
    my $p    = $self->profile;
    my $key  = $row->{key};
    my $val  = $row->{values};
    my $hold = sub ($bucket, $reason) {
        $plan->add( bucket => $bucket, action => 'hold', key => "dispatch:$key", reason => $reason );
        return;
    };
    if ( my $h = $row->{held} ) {
        my ($kind) = $h =~ /^(\w+):/;
        return $hold->( 'held-' . ( $kind // 'flag' ), $h );
    }
    return $hold->( 'held-flag', $row->{error} ) if defined $row->{error};
    return $hold->( 'held-flag', 'row has no values' ) if ref $val ne 'HASH';
    my $order_name = $val->{order};
    return $hold->( 'no-order', 'row names no order' ) if !defined $order_name || $order_name eq '';
    my %allow = map { $_ => 1 } grep { $ALLOW{$_} } @{ $val->{allow} // [] };
    for my $a ( @{ $val->{allow} // [] } ) {
        Odoo::Error->throw( kind => 'usage', message => "stock.dispatch: row $key allows '$a' (known: " . join( ', ', sort keys %ALLOW ) . ')' ) if !$ALLOW{$a};
    }

    my @problems;    # [ bucket, text ] - the first names the bucket
    my $problem = sub ($bucket, $text) { push @problems, [ $bucket, $text ]; return };

    # 1. the order, its invoices, its deliveries (SA4)
    my $f = sub ($lm, $lf) { $self->_f( $lm => $lf ) };
    my $orders = $self->model('order')->search_read( [ [ $f->( order => 'name' ), '=', $order_name ] ], [ 'id', $f->( order => 'name' ), $f->( order => 'pickings' ) ] );
    return $hold->( 'no-order', "no sale order named $order_name" ) if !@$orders;
    return $hold->( 'no-order', "$order_name names more than one sale order" ) if @$orders > 1;
    my $so = $orders->[0];
    my $invoices = eval { $self->model('order')->read_one( $so->{id}, [ $f->( order => 'invoices' ) ] )->{ $f->( order => 'invoices' ) } };
    return $hold->( 'invoiced', "$order_name has invoice records this user cannot read: check with Accounts" ) if !defined $invoices;
    return $hold->( 'invoiced', "$order_name has " . scalar(@$invoices) . ' invoice(s), draft or posted: check with Accounts (a draft can be deleted first)' ) if @$invoices;

    my $pickings = @{ $so->{ $f->( order => 'pickings' ) } // [] }
        ? $self->model('picking')->search_read( [ [ 'id', 'in', $so->{ $f->( order => 'pickings' ) } ] ],
            [ map { $f->( picking => $_ ) } qw(name state type source destination) ] ) : [];
    my %code = map { $_->{id} => $_->{code} } @{ $self->model('picking_type')->search_read( [ [ 'id', 'in', [ map { _id( $_->{ $f->( picking => 'type' ) } ) } @$pickings ] ] ],
        [ 'id', $f->( picking_type => 'code' ) ] ) };
    my $type = sub ($pk) { $code{ _id( $pk->{ $f->( picking => 'type' ) } ) } // '' };
    my $state = $f->( picking => 'state' );
    my @out = grep { $type->($_) eq 'outgoing' && $_->{$state} ne 'cancel' } @$pickings;
    return $hold->( 'multi-out', "$order_name has " . scalar(@out) . ' outgoing pickings (' . join( ', ', map { $_->{ $f->( picking => 'name' ) } } @out ) . '): not one chain' ) if @out > 1;
    my ( $del, $del_src, $pick, $pending );
    if (@out) {
        $del = $out[0];
        return $hold->( 'already-done', "$del->{ $f->( picking => 'name' ) } is already done: the portal rows are stale" ) if $del->{$state} eq 'done';
        $del_src = _id( $del->{ $f->( picking => 'source' ) } );
        my @picks = grep { $type->($_) eq 'internal' && $_->{$state} ne 'cancel' && _id( $_->{ $f->( picking => 'destination' ) } ) == $del_src } @$pickings;
        return $hold->( 'multi-out', "$order_name has " . scalar(@picks) . ' picks into ' . _label( $del->{ $f->( picking => 'source' ) } ) . ': not one chain' ) if @picks > 1;
        $pick = $picks[0];
    }
    else {
        # Odoo 19 makes the delivery of a two-step warehouse by a push rule when the pick is validated (live 2026-10-13):
        # an order with one open pick and no delivery is dispatched through the pick, the delivery found at apply
        my @ip = grep { $type->($_) eq 'internal' && $_->{$state} ne 'cancel' } @$pickings;
        return $hold->( 'no-delivery', "$order_name has no delivery to record on" ) if @ip != 1 || $ip[0]{$state} eq 'done';
        $pick    = $ip[0];
        $pending = 1;
        $del_src = _id( $pick->{ $f->( picking => 'destination' ) } );
        $del     = { id => undef, $f->( picking => 'name' ) => 'the delivery the pick makes', $state => 'none', $f->( picking => 'source' ) => $pick->{ $f->( picking => 'destination' ) } };
    }

    # 2. where the facts are staged
    my $stage = ( $pick && $pick->{$state} ne 'done' ) ? 'pick' : 'delivery';
    if ( $pick && $stage eq 'delivery' && !$allow{'stage-out'} ) {
        $problem->( 'stage-out', "the pick $pick->{ $f->( picking => 'name' ) } is done, so the facts are staged on the delivery and drawn from " . _label( $del->{ $f->( picking => 'source' ) } ) . ' (allow stage-out to permit)' );
    }
    my $stager = $stage eq 'pick' ? $pick : $del;

    # 5. checks that turn Odoo's refusals into holds
    my $date = $val->{date};
    $problem->( 'paper-date', defined $date && $date ne '' ? "the paper date '$date' is not a date (YYYY-MM-DD)" : 'the paper has no dispatch date' ) if !_valid_date($date);
    $problem->( 'blocker', "the acting user (id $env->{uid}) has no email address: validating a quantity that differs from demand would raise 'Unable to send message' (SA1)" ) if !$env->{email};

    # 3. each paper line: product, sale line, moves
    my @plines = ref $val->{lines} eq 'ARRAY' ? @{ $val->{lines} } : ();
    $problem->( 'no-move', "row for $order_name has no lines" ) if !@plines;
    my @codes = grep { defined && length } map { $_->{product} } @plines;
    my $prods = @codes ? $self->client->model('product.product')->search_read( [ [ 'default_code', 'in', \@codes ] ], [ 'id', 'default_code', 'display_name' ] ) : [];
    my %prod = map { $_->{default_code} => $_ } @$prods;

    my $mf = sub ($lf) { $f->( move => $lf ) };
    my @move_fields = map { $mf->($_) } qw(product demand state uom source destination picking sale_line origin_moves dest_moves);
    my $del_moves = $pending ? [] : $self->model('move')->search_read( [ [ $mf->('picking'), '=', $del->{id} ], [ $mf->('state'), '!=', 'cancel' ] ], [@move_fields] );
    my $pick_moves = $pick ? $self->model('move')->search_read( [ [ $mf->('picking'), '=', $pick->{id} ], [ $mf->('state'), '!=', 'cancel' ] ], [@move_fields] ) : [];
    my @sl_ids = grep { $_ } map { _id( $_->{ $mf->('sale_line') } ) } @{ $pending ? $pick_moves : $del_moves };
    my %sol = map { $_->{id} => $_ } @{ @sl_ids ? $self->model('sale_line')->search_read( [ [ 'id', 'in', \@sl_ids ] ], [ 'id', map { $f->( sale_line => $_ ) } qw(ordered delivered) ] ) : [] };

    # the lines of the staging picking: what the system holds (own reservation) and who touched them (staff-edit)
    my $lf = sub ($x) { $f->( move_line => $x ) };
    my @ml_fields = grep { defined } map { $self->profile->has_field( move_line => $_ ) ? $lf->($_) : undef } qw(product lot package result_package source destination reserved done picked move date created creator updater updated);
    my $stage_lines = $self->model('move_line')->search_read( [ [ $lf->('picking'), '=', $stager->{id} ] ], [@ml_fields] );
    if ($date && _valid_date($date)) {
        for my $l (@$stage_lines) {
            my ( $c, $u, $w, $made ) = ( _id( $l->{ $lf->('creator') } ), _id( $l->{ $lf->('updater') } ), $l->{ $lf->('updated') }, $l->{ $lf->('created') } );
            next if !$c || !$u || $c == $u || !$w;
            # Odoo reserves as the superuser and the confirming user touches the line in the same breath: the system, not a person
            next if $made && _epoch($w) - _epoch($made) <= $STAFF_EDIT_GRACE;
            $problem->( 'staff-edit', "move line $l->{id} of " . $stager->{ $f->( picking => 'name' ) } . " was changed by user $u (created by $c) on " . substr( $w, 0, 10 ) . ', since the paper date: a person decides' ) if substr( $w, 0, 10 ) ge $date;
        }
    }

    my ( @moves, %pool_cache );
    my $placeholder = 0;    # a drawn lot carries an expiration equal to its creation (SC4)
    my %seen_product;
    for my $pl (@plines) {
        my $code = $pl->{product} // '';
        my $pr   = $prod{$code};
        if ( !$pr ) { $problem->( 'no-move', "no product with default_code '$code'" ); next }
        if ( $seen_product{ $pr->{id} }++ ) { $problem->( 'no-move', "$code is on the paper twice: one line per product" ); next }
        my @dm = grep { _id( $_->{ $mf->('product') } ) == $pr->{id} } @{ $pending ? $pick_moves : $del_moves };
        if ( !@dm )     { $problem->( 'no-move', "$code is not on $order_name" ); next }
        if ( @dm > 1 )  { $problem->( 'no-move', "$code has " . scalar(@dm) . ' moves on the ' . ( $pending ? 'pick' : 'delivery' ) . ': not one line' ); next }
        my $dmove = $dm[0];
        my $sl    = $sol{ _id( $dmove->{ $mf->('sale_line') } ) // 0 };
        if ( !$sl ) { $problem->( 'no-move', "the " . ( $pending ? 'pick' : 'delivery' ) . " move for $code has no sale line" ); next }
        my @staging = $pending ? ($dmove) : $stage eq 'delivery' ? ($dmove)
            : grep { my $m = $_; grep { $_ == $m->{id} } @{ $dmove->{ $mf->('origin_moves') } // [] } } @$pick_moves;
        @staging = grep { _id( $_->{ $mf->('product') } ) == $pr->{id} } @$pick_moves if $stage eq 'pick' && !@staging;
        if ( @staging != 1 ) { $problem->( 'no-move', "$code has " . scalar(@staging) . " moves on the pick $pick->{ $f->( picking => 'name' ) }: not one line" ) if $stage eq 'pick'; next }
        my $smove = $staging[0];

        # the paper quantity
        my %lots = ref $pl->{lots} eq 'HASH' ? %{ $pl->{lots} } : ();
        my $paper = 0;
        if (%lots) { $paper += $_ for values %lots }
        else       { $paper = $pl->{qty} // 0 }
        if ( %lots && defined $pl->{qty} && abs( $pl->{qty} - $paper ) > $EPS ) {
            $problem->( 'quantity-differs', "$code: qty $pl->{qty} but the lots add to $paper" );
            next;
        }
        if ( $paper <= 0 ) { $problem->( 'quantity-differs', "$code: the paper quantity is not above zero" ); next }
        my ( $ordered, $delivered ) = ( $sl->{ $f->( sale_line => 'ordered' ) }, $sl->{ $f->( sale_line => 'delivered' ) } );
        if ( $delivered + $paper > $ordered + $EPS ) {
            $problem->( 'quantity-differs', "$code: delivered $delivered + paper $paper exceeds ordered $ordered: the delivery would over-deliver" );
            next;
        }

        # 4. portions
        my @mylines = grep { _id( $_->{ $lf->('move') } ) == $smove->{id} } @$stage_lines;
        my $portions = $self->_portions( $env, $stage, $pr, $smove, \@mylines, \%lots, $paper, $del_src, \%pool_cache, $mf );
        my @expired;
        my %lot_row = %{ $portions->{lots} };
        for my $s ( @{ $portions->{short} } ) {
            $problem->( 'shortfall', "$code lot $s->{lot_name}: " . _g( $s->{short} ) . ' short of ' . _g( $s->{wanted} ) . " (the stock bay holds " . _g( $s->{wanted} - $s->{short} ) . ')' );
        }
        my @released = grep { $_->{reserved_by_other} } @{ $portions->{portions} };
        if (@released) {
            my $who = $self->_reserved_by( $smove, \@released );
            $_->{reserved_by} = $who->{ $_->{key} } // [] for @released;
            $problem->( 'reserved', "$code: " . join( '; ', map { _g( $_->{quantity} ) . " of $_->{lot_name} is reserved by " . ( join( ', ', @{ $_->{reserved_by} } ) || 'another move' ) } @released ) . ' (allow reserved to release)' )
                if !$allow{reserved};
        }
        for my $lid ( sort { $a <=> $b } grep { $_ } map { $_->{lot} } @{ $portions->{portions} } ) {
            my $lr = $lot_row{$lid} or next;
            my ( $exp, $created ) = ( $lr->{expiration}, $lr->{created} );
            next if !$exp || $exp eq '0';
            if ( $created && abs( _epoch($exp) - _epoch($created) ) <= 5 ) { $placeholder = 1; next }    # SC4: never given one - not expired, but Odoo's own check still asks (live 16)
            if ( $exp lt $env->{now} ) {
                push @expired, "$lr->{name} (expired " . substr( $exp, 0, 10 ) . ')';
            }
        }
        $problem->( 'expired', "$code: " . join( ', ', @expired ) . ' (allow expired to dispatch it)' ) if @expired && !$allow{expired};

        my %system;
        for my $l (@mylines) {
            my $q = $self->profile->has_field( move_line => 'reserved' ) ? ( $l->{ $lf->('reserved') } || $l->{ $lf->('done') } || 0 ) : ( $l->{ $lf->('done') } || 0 );
            my $ln = _id( $l->{ $lf->('lot') } ) ? _label( $l->{ $lf->('lot') } ) : 'no lot';
            $system{$ln} += $q;
        }
        my %paper_by = %lots ? %lots : ( 'no lot' => $paper );
        my @changed = map { "$_: system had " . _g( $system{$_} // 0 ) . ', paper says ' . _g( $paper_by{$_} // 0 ) } grep { abs( ( $paper_by{$_} // 0 ) - ( $system{$_} // 0 ) ) > $EPS } sort keys %{ { %paper_by, %system } };

        my @ports = map { +{ %$_ } } @{ $portions->{portions} };
        push @moves, {
            product => $pr->{id}, product_code => $code, product_name => $pr->{display_name},
            paper => 0 + sprintf( '%.3f', $paper ), paper_lots => { map { $_ => 0 + $lots{$_} } keys %lots },
            move => $smove->{id}, out_move => ( $pending ? undef : $dmove->{id} ),
            uom => _id( $smove->{ $mf->('uom') } ), destination => _id( $smove->{ $mf->('destination') } ),
            out_uom => ( $pending ? undef : _id( $dmove->{ $mf->('uom') } ) ), out_destination => ( $pending ? undef : _id( $dmove->{ $mf->('destination') } ) ),
            sale_line => $sl->{id}, ordered => $ordered, delivered_before => $delivered, delivered_after => 0 + sprintf( '%.3f', $delivered + $paper ),
            system => \%system, changed => \@changed,
        };
        $moves[-1]{portions} = [ map { +{ lot => $_->{lot}, lot_name => $_->{lot_name}, package => $_->{package}, package_name => $_->{package_name},
            location => $_->{location}, location_name => $_->{location_name}, quantity => 0 + sprintf( '%.3f', $_->{quantity} ),
            ( $_->{reserved_by_other} ? ( releases => $_->{reserved_by} // [] ) : () ) } } @ports ];
        # the delivery receives the same lots from the pick's destination, loose
        if ( $stage eq 'pick' ) {
            my %by;
            my @order;
            for my $pt (@ports) {
                my $k = $pt->{lot} // 0;
                push @order, $k if !exists $by{$k};
                $by{$k}{lot} = $pt->{lot};
                $by{$k}{lot_name} = $pt->{lot_name};
                $by{$k}{quantity} += $pt->{quantity};
            }
            $moves[-1]{out_lines} = [ map { +{ lot => $by{$_}{lot}, lot_name => $by{$_}{lot_name}, location => $del_src, location_name => _label( $del->{ $f->( picking => 'source' ) } ),
                package => undef, quantity => 0 + sprintf( '%.3f', $by{$_}{quantity} ) } } @order ];
        }
    }

    # a product on the delivery with no paper line is not touched: the delivery is then validated short, and the remainder closed
    if (@problems) {
        my ( $bucket, ) = @{ $problems[0] };
        my @texts;
        my %seen;
        push @texts, $_->[1] for grep { !$seen{ $_->[1] }++ } @problems;
        return $hold->( $bucket, "$order_name: " . join( '; ', @texts ) );
    }

    my $dn = $del->{ $f->( picking => 'name' ) };
    my $pn = $pick ? $pick->{ $f->( picking => 'name' ) } : undef;
    my $reason = "$order_name $date: " . join( '; ', map { "$_->{product_code} " . _g( $_->{paper} ) . ( %{ $_->{paper_lots} } ? ' (' . lots_text( $_->{paper_lots} ) . ')' : '' ) } @moves )
        . ( $stage eq 'pick' ? " on $pn then $dn" : " on $dn" . ( $pick ? " (pick $pn already done)" : '' ) );
    my %res;
    for my $m (@moves) { for my $pt ( @{ $m->{portions} } ) { push @{ $res{$m->{product_code}} }, @{ $pt->{releases} } if $pt->{releases} } }
    $plan->add(
        bucket => 'dispatch', action => 'custom', handler => $self->op_name, kind => 'dispatch',
        model => $self->physical_model('picking'), id => ( $pending ? $pick->{id} : $del->{id} ), key => "dispatch:$key",
        before => { $state => ( $pending ? $pick->{$state} : $del->{$state} ) },
        reason => $reason,
        vals => {
            order => $order_name, order_id => $so->{id}, date => $date, note => $val->{note},
            stage => $stage,
            pick => $pick ? { id => $pick->{id}, name => $pn, state => $pick->{$state} } : undef,
            delivery => { id => $del->{id}, name => $dn, state => $del->{$state}, pending => ( $pending ? JSON::PP::true : JSON::PP::false ) },
            moves => \@moves,
            close_backorder => JSON::PP::true,
            allow_expired => ( $allow{expired} || $placeholder ? JSON::PP::true : JSON::PP::false ),
            reservations_released => \%res,
        },
        irreversible => 'a validated picking is undone by a return, a separate write (stock.dispatch has no inverse)',
    );
    return;
}

sub lots_text ($lots) { join ', ', map { "$_=" . _g( $lots->{$_} ) } sort keys %$lots }

# Which quants each lot quantity is drawn from. One pool per lot, drawn
# down across the paper's lines (the same lot named twice must not be
# satisfied twice from one quant). Returns { portions, short, lots }.
sub _portions ($self, $env, $stage, $pr, $smove, $mylines, $lots, $paper, $del_src, $cache, $mf) {
    my $f  = sub ($lm, $lf) { $self->_f( $lm => $lf ) };
    my $lf = sub ($x) { $f->( move_line => $x ) };
    my $src = _id( $smove->{ $mf->('source') } );
    my @tree = _subtree( $env, $src );
    # SE4: stock in the delivery's source (output) is not available to a pick
    if ( $stage eq 'pick' ) { my %out = map { $_ => 1 } _subtree( $env, $del_src ); @tree = grep { !$out{$_} } @tree }
    @tree = grep { ( $env->{loc}{$_}{ $f->( location => 'usage' ) } // '' ) eq 'internal' } @tree;

    # what the move already reserves, per lot/package/location
    my %own;
    for my $l (@$mylines) {
        my $q = $self->profile->has_field( move_line => 'reserved' ) ? ( $l->{ $lf->('reserved') } // 0 )
              : ( $self->profile->has_field( move_line => 'picked' ) && $l->{ $lf->('picked') } ? 0 : ( $l->{ $lf->('done') } // 0 ) );
        $own{ join '/', _id( $l->{ $lf->('lot') } ) // 0, _id( $l->{ $lf->('package') } ) // 0, _id( $l->{ $lf->('source') } ) // 0 } += $q;
    }
    my %want = %$lots ? %$lots : ( '' => $paper );
    my $lot_rows = %$lots
        ? $self->model('lot')->search_read( [ [ $f->( lot => 'name' ), 'in', [ keys %$lots ] ] ], [ 'id', map { $f->( lot => $_ ) } qw(name product expiration created) ] ) : [];
    my %lot_by_name;
    my %lot_row;
    for my $r (@$lot_rows) {
        next if _id( $r->{ $f->( lot => 'product' ) } ) != $pr->{id};
        $lot_by_name{ $r->{ $f->( lot => 'name' ) } } = $r->{id};
        $lot_row{ $r->{id} } = { id => $r->{id}, name => $r->{ $f->( lot => 'name' ) }, expiration => $r->{ $f->( lot => 'expiration' ) }, created => $r->{ $f->( lot => 'created' ) } };
    }
    my ( @portions, @short, %pool );
    for my $name ( sort keys %want ) {
        my $qty = $want{$name};
        my $lot = $name eq '' ? 0 : $lot_by_name{$name};
        if ( !defined $lot ) {
            push @short, { lot_name => $name, wanted => $qty, short => $qty };
            next;
        }
        if ( !$pool{$lot} ) {
            my $quants = @tree ? $self->model('quant')->search_read(
                [ [ $f->( quant => 'product' ), '=', $pr->{id} ], [ $f->( quant => 'lot' ), '=', ( $lot ? $lot : JSON::PP::false ) ],
                    [ $f->( quant => 'location' ), 'in', \@tree ], [ $f->( quant => 'quantity' ), '>', 0 ] ],
                [ map { $f->( quant => $_ ) } qw(quantity reserved package location) ] ) : [];
            my @tiers = ( [], [], [] );    # own, free, another move's reservation
            for my $c (@$quants) {
                my $pkg = _id( $c->{ $f->( quant => 'package' ) } ) // 0;
                my $loc = _id( $c->{ $f->( quant => 'location' ) } );
                my $q   = $c->{ $f->( quant => 'quantity' ) };
                my $res = $c->{ $f->( quant => 'reserved' ) } // 0;
                my $own = $own{"$lot/$pkg/$loc"} // 0;
                my $mine   = $q < $own ? $q : $own;
                my $others = $res - $mine > 0 ? $res - $mine : 0;
                $others = $q - $mine if $others > $q - $mine;
                my $free = $q - $mine - $others;
                for my $t ( [ 0, $mine, 0 ], [ 1, $free, 0 ], [ 2, $others, 1 ] ) {
                    push @{ $tiers[ $t->[0] ] }, { qty => $t->[1], package => $pkg, package_name => _label( $c->{ $f->( quant => 'package' ) } ),
                        location => $loc, location_name => _label( $c->{ $f->( quant => 'location' ) } ), other => $t->[2] }
                        if $t->[1] > $EPS;
                }
            }
            # loose before packages, largest first
            $pool{$lot} = [ map { sort { ( $a->{package} ? 1 : 0 ) <=> ( $b->{package} ? 1 : 0 ) || $b->{qty} <=> $a->{qty} } @$_ } @tiers ];
        }
        my $left = $qty;
        for my $cell ( @{ $pool{$lot} } ) {
            last if $left <= $EPS;
            my $take = $cell->{qty} < $left ? $cell->{qty} : $left;
            next if $take <= $EPS;
            push @portions, {
                lot => ( $lot || undef ), lot_name => ( $name eq '' ? undef : $name ),
                package => ( $cell->{package} || undef ), package_name => $cell->{package_name},
                location => $cell->{location}, location_name => $cell->{location_name},
                quantity => $take, reserved_by_other => $cell->{other},
                key => join( '/', $lot, $cell->{package}, $cell->{location} ),
            };
            $cell->{qty} -= $take;
            $left -= $take;
        }
        push @short, { lot_name => ( $name eq '' ? 'no lot' : $name ), wanted => $qty, short => $left } if $left > $EPS;
    }
    return { portions => \@portions, short => \@short, lots => \%lot_row };
}

# the pickings whose lines reserve a quant another move is about to take
sub _reserved_by ($self, $smove, $ports) {
    my $f  = sub ($lm, $lf) { $self->_f( $lm => $lf ) };
    my $lf = sub ($x) { $f->( move_line => $x ) };
    my %out;
    for my $pt (@$ports) {
        # a domain term product != 0 matches nothing on Odoo 16 (live): the product is named
        my @dom = ( [ $lf->('product'), '=', _id( $smove->{ $f->( move => 'product' ) } ) ], [ $lf->('source'), '=', $pt->{location} ], [ $lf->('move'), '!=', $smove->{id} ] );
        push @dom, [ $lf->('lot'), '=', $pt->{lot} ] if $pt->{lot};
        my $rows = $self->model('move_line')->search_read( \@dom, [ $lf->('picking'), $lf->('lot'), $lf->('package'), $lf->('state'), grep { defined } ( $self->profile->has_field( move_line => 'reserved' ) ? $lf->('reserved') : undef ) ] );
        for my $r (@$rows) {
            next if ( $r->{ $lf->('state') } // '' ) =~ /^(done|cancel)\z/;
            next if ( _id( $r->{ $lf->('package') } ) // 0 ) != ( $pt->{package} // 0 );
            next if ( _id( $r->{ $lf->('lot') } ) // 0 ) != ( $pt->{lot} // 0 );
            my $pk = $r->{ $lf->('picking') };
            push @{ $out{ $pt->{key} } }, _label($pk) // 'a move without a picking' if ref $pk;
        }
    }
    return \%out;
}

# --- rows ----------------------------------------------------------------------

sub _rows ($self) {
    my @docs;
    if ( defined( my $recs = $self->param('records') ) ) {
        Odoo::Error->throw( kind => 'usage', message => 'stock.dispatch: records must be a list' ) if ref $recs ne 'ARRAY';
        @docs = @$recs;
    }
    else {
        my $path = $self->param('rows');
        Odoo::Error->throw( kind => 'config', message => "stock.dispatch: cannot read $path" ) if !-r $path;
        open my $fh, '<:raw', $path or Odoo::Error->throw( kind => 'config', message => "cannot read $path: $!" );
        if ( $path =~ /\.jsonl\z/i ) {
            while ( my $line = <$fh> ) {
                next if $line !~ /\S/;
                push @docs, eval { Odoo::Ops::json()->decode($line) } // Odoo::Error->throw( kind => 'config', message => "$path line $.: not JSON" );
            }
        }
        else {
            my $raw = do { local $/; <$fh> };
            my $d = eval { Odoo::Ops::json()->decode($raw) } // Odoo::Error->throw( kind => 'config', message => "$path is not valid JSON" );
            Odoo::Error->throw( kind => 'config', message => "$path must hold a list of rows" ) if ref $d ne 'ARRAY';
            @docs = @$d;
        }
        close $fh;
    }
    my @rows;
    for my $i ( 0 .. $#docs ) {
        my $d = $docs[$i];
        Odoo::Error->throw( kind => 'usage', message => 'stock.dispatch: row #' . ( $i + 1 ) . ' is not a map' ) if ref $d ne 'HASH';
        my %e = ( key => $d->{key} // ( ref $d->{values} eq 'HASH' ? $d->{values}{order} : undef ) // 'row' . ( $i + 1 ), values => $d->{values} );
        $e{held}  = $d->{held}  if defined $d->{held};
        $e{error} = $d->{error} if defined $d->{error};
        push @rows, \%e;
    }
    return \@rows;
}

# --- apply -----------------------------------------------------------------

sub undo_custom ($class, $entry) {
    return ( undef, 'undone by a return picking - plan one with stock.return' );
}

sub apply_custom ($class, $client, $c) {
    Odoo::Error->throw( kind => 'usage', message => "stock.dispatch cannot apply kind '$c->{kind}'" ) if ( $c->{kind} // '' ) ne 'dispatch';
    my $profile = Odoo::Ops::Profile->load( pack => 'stock', series => $client->server_series );
    my $v = $c->{vals};
    my @did;
    my $out = eval { $class->_apply( $client, $profile, $v, \@did ) };
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
    my $picking = $client->model( $p->model_name('picking') );
    my $sale    = $client->model( $p->model_name('sale_line') );
    my @moves   = @{ $v->{moves} };

    # 0. nothing written when the order moved on since planning
    for my $m (@moves) {
        my $now = $sale->read_one( $m->{sale_line}, [ $f->( sale_line => 'delivered' ) ] );
        my $q = $now ? $now->{ $f->( sale_line => 'delivered' ) } : undef;
        Odoo::Error->throw( kind => 'refused', code => 'stale', message => "sale line $m->{sale_line} ($m->{product_code}) now reads delivered " . ( $q // 'gone' ) . ", planned from $m->{delivered_before}: re-plan" )
            if !defined $q || abs( $q - $m->{delivered_before} ) > $EPS;
    }
    my $stamp = "$v->{date} 12:00:00";
    my ( @validated, %wizards );

    # 1-2. the pick
    if ( $v->{stage} eq 'pick' ) {
        my $pid = $v->{pick}{id};
        $class->_stage( $client, $p, $pid, [ map { +{ move => $_->{move}, product => $_->{product}, uom => $_->{uom}, destination => $_->{destination}, lines => $_->{portions} } } @moves ] );
        push @$did, "staged $v->{pick}{name}";
        $wizards{$pid} = Odoo::Ops::Stock::Validate->run( $client, $p, $pid, close_backorder => 1, allow_expired => $v->{allow_expired} );
        push @validated, $pid;
        push @$did, "validated $v->{pick}{name}";
    }
    # 3. the delivery; when a push rule makes it as the pick is validated (Odoo 19), it is found now through the pick's moves
    my $did_ = $v->{delivery}{id};
    if ( !$did_ ) {
        my $mv = $client->model( $p->model_name('move') );
        my %found;
        for my $m (@moves) {
            my $pm = $mv->read_one( $m->{move}, [ $f->( move => 'dest_moves' ) ] );
            my @dest = @{ $pm ? $pm->{ $f->( move => 'dest_moves' ) } // [] : [] };
            my $rows = @dest ? $mv->read( \@dest, [ map { $f->( move => $_ ) } qw(product picking uom destination state) ] ) : [];
            my @mine = grep { ( ref $_->{ $f->( move => 'product' ) } ? $_->{ $f->( move => 'product' ) }[0] : 0 ) == $m->{product} && $_->{ $f->( move => 'state' ) } ne 'cancel' && ref $_->{ $f->( move => 'picking' ) } } @$rows;
            Odoo::Error->throw( kind => 'fault', message => "validating $v->{pick}{name} made " . scalar(@mine) . " delivery moves for $m->{product_code}, not one" ) if @mine != 1;
            $m->{out_move}        = $mine[0]{id};
            $m->{out_uom}         = $mine[0]{ $f->( move => 'uom' ) }[0];
            $m->{out_destination} = $mine[0]{ $f->( move => 'destination' ) }[0];
            $found{ $mine[0]{ $f->( move => 'picking' ) }[0] } = $mine[0]{ $f->( move => 'picking' ) }[1];
        }
        Odoo::Error->throw( kind => 'fault', message => "validating $v->{pick}{name} made " . scalar( keys %found ) . ' deliveries, not one' ) if keys %found != 1;
        my ( $dkey, $dname ) = %found;
        $did_ = 0 + $dkey;    # a hash key is a string; a JSON string is not an id
        $v->{delivery}{id}   = $did_;
        $v->{delivery}{name} = $dname;
        push @$did, "found $dname made by the pick";
    }
    my $dstate = $picking->read_one( $did_, [ $f->( picking => 'state' ) ] )->{ $f->( picking => 'state' ) };
    if ( $dstate !~ /^(assigned|partially_available)\z/ ) {
        $picking->call( 'action_assign', [ [$did_] ] );
        push @$did, "assigned $v->{delivery}{name}";
    }
    $class->_stage( $client, $p, $did_, [ map { +{ move => $_->{out_move}, product => $_->{product}, uom => $_->{out_uom}, destination => $_->{out_destination},
        lines => ( $v->{stage} eq 'pick' ? $_->{out_lines} : $_->{portions} ) } } @moves ] );
    push @$did, "staged $v->{delivery}{name}";
    $wizards{$did_} = Odoo::Ops::Stock::Validate->run( $client, $p, $did_, close_backorder => 1, allow_expired => $v->{allow_expired} );
    push @validated, $did_;
    push @$did, "validated $v->{delivery}{name}";

    # 4. backdate both transfers, their moves and lines (SC6)
    my $move = $client->model( $p->model_name('move') );
    my $line = $client->model( $p->model_name('move_line') );
    for my $pid (@validated) {
        $picking->write( $pid, { $f->( picking => 'done_at' ) => $stamp } );
        my $mids = $move->search( [ [ $f->( move => 'picking' ), '=', $pid ] ] );
        if (@$mids) {
            $move->write( $mids, { $f->( move => 'date' ) => $stamp } );
            my $lids = $line->search( [ [ $f->( move_line => 'move' ), 'in', $mids ] ] );
            $line->write( $lids, { $f->( move_line => 'date' ) => $stamp } ) if @$lids;
        }
    }
    push @$did, "backdated to $stamp";

    # 5. the note on each transfer
    my $u = $client->model('res.users')->read_one( $client->uid, [ 'email', 'partner_id' ] ) // {};
    my $partner = ref $u->{partner_id} ? $u->{partner_id}[0] : undef;
    my %names = ( $did_ => $v->{delivery}{name}, ( $v->{pick} ? ( $v->{pick}{id} => $v->{pick}{name} ) : () ) );
    for my $pid (@validated) {
        $picking->call( 'message_post', [ [$pid] ],
            body => _note_html( $v, $pid, $names{$pid}, $wizards{$pid} ), message_type => 'comment', subtype_xmlid => 'mail.mt_note',
            ( $partner ? ( author_id => $partner ) : () ), email_from => ( $u->{email} || 'noreply@oom.invalid' ) );
    }
    push @$did, 'noted ' . scalar(@validated) . ' transfer(s)';

    # 6. read back
    my ( $ok, %after ) = (1);
    for my $pid (@validated) {
        my $r = $picking->read_one( $pid, [ $f->( picking => 'state' ), $f->( picking => 'done_at' ) ] );
        $after{pickings}{ $names{$pid} } = $r->{ $f->( picking => 'state' ) };
        $ok = 0 if $r->{ $f->( picking => 'state' ) } ne 'done';
    }
    for my $m (@moves) {
        my $now = $sale->read_one( $m->{sale_line}, [ $f->( sale_line => 'delivered' ) ] )->{ $f->( sale_line => 'delivered' ) };
        $after{delivered}{ $m->{product_code} } = $now;
        $ok = 0 if abs( $now - $m->{delivered_after} ) > $EPS;
    }
    $after{reservations_released} = $v->{reservations_released};
    $after{wizards} = { map { $names{$_} => $wizards{$_} } keys %wizards };
    return { id => $did_, after => ( $ok ? \%after : undef ), returned => join( ', ', map { $names{$_} } @validated ) };
}

# Replace the move's open lines with the plan's lines, each with its done quantity.
sub _stage ($class, $client, $p, $pid, $specs) {
    my $f    = sub ($lm, $lf) { $p->has_field( $lm => $lf ) ? $p->field( $lm => $lf ) : undef };
    my $line = $client->model( $p->model_name('move_line') );
    my $done = $f->( move_line => 'done' );
    for my $s (@$specs) {
        my $old = $line->search_read( [ [ $f->( move_line => 'move' ), '=', $s->{move} ] ], [ 'id', $done, grep { defined } $f->( move_line => 'picked' ) ] );
        my @open = map { $_->{id} } @$old;
        $line->unlink( \@open ) if @open;
        for my $l ( @{ $s->{lines} } ) {
            my %ml = (
                $f->( move_line => 'move' )        => $s->{move},
                $f->( move_line => 'picking' )     => $pid,
                $f->( move_line => 'product' )     => $s->{product},
                $f->( move_line => 'source' )      => $l->{location},
                $f->( move_line => 'destination' ) => $s->{destination},
                $done                              => $l->{quantity},
                product_uom_id                     => $s->{uom},
            );
            $ml{ $f->( move_line => 'lot' ) }     = $l->{lot}     if $l->{lot};
            $ml{ $f->( move_line => 'package' ) } = $l->{package} if $l->{package};
            $ml{ $f->( move_line => 'picked' ) }  = JSON::PP::true if $f->( move_line => 'picked' );
            $line->create( \%ml );
        }
    }
    return;
}

sub _note_html ($v, $pid, $name, $wizards) {
    my $h = sub ($s) { ( $s // '' ) =~ s/&/&amp;/gr =~ s/</&lt;/gr =~ s/>/&gt;/gr };
    my $body = '<p><b>' . $h->("Dispatch recorded from paper ($v->{order}, $name)") . '</b></p><ul>';
    for my $m ( @{ $v->{moves} } ) {
        my $paper = %{ $m->{paper_lots} } ? lots_text( $m->{paper_lots} ) : 'no lot ' . _g( $m->{paper} );
        my $sys = join( '; ', map { "$_=" . _g( $m->{system}{$_} ) } sort keys %{ $m->{system} } ) || '(no lines)';
        $body .= '<li>' . $h->("$m->{product_name}: paper $paper; system held $sys; ")
            . $h->( @{ $m->{changed} } ? 'changed: ' . join( ', ', @{ $m->{changed} } ) : 'no change, the system already agreed with the paper' ) . '</li>';
    }
    $body .= '<li>' . $h->("dispatch date: $v->{date}") . '</li>';
    $body .= '<li>' . $h->( "office note: $v->{note}" ) . '</li>' if defined $v->{note} && length $v->{note};
    $body .= '<li>' . $h->( 'wizards answered: ' . join( ', ', @{ $wizards // [] } ) ) . '</li>' if $wizards && @$wizards;
    return $body . '</ul><p>Recorded by stock.dispatch.</p>';
}

# --- small helpers ---------------------------------------------------------

sub _id    ($v) { ref $v eq 'ARRAY' ? $v->[0] : ( $v ? $v : undef ) }
sub _label ($v) { ref $v eq 'ARRAY' ? $v->[1] : undef }
sub _g     ($n) { 0 + sprintf( '%.3f', $n ) }

sub _valid_date ($s) {
    return 0 if !defined $s || $s !~ /^(\d{4})-(\d\d)-(\d\d)\z/;
    my ( $y, $m, $d ) = ( $1, $2, $3 );
    return 0 if $m < 1 || $m > 12 || $d < 1 || $d > 31 || $y < 1970;
    my $ok = eval { timegm( 0, 0, 0, $d, $m - 1, $y ); 1 };
    return $ok ? 1 : 0;
}

sub _epoch ($s) {
    my ( $y, $mo, $d, $h, $mi, $se ) = $s =~ /^(\d{4})-(\d\d)-(\d\d)[ T](\d\d):(\d\d):(\d\d)/ or return 0;
    return timegm( $se, $mi, $h, $d, $mo - 1, $y );
}

1;
