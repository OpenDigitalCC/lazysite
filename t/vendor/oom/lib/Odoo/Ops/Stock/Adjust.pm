package Odoo::Ops::Stock::Adjust;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();
use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Profile;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Stock::Adjust - a stock count applied through Odoo's inventory mode

=head1 SYNOPSIS

    oom-ops run stock.adjust --conf ops.conf --set reason='count 2026-10-19' \
        --set 'rows=[{"product":"ALM-1","location":"SHOP/Stock/A1","quantity":"24.500"}]'

=head1 DESCRIPTION

C<stock.adjust> sets what is on hand to what was counted, the way Odoo's own Physical Inventory screen does:
each row names a product (C<default_code>), a location (its complete name, an internal one), optionally a lot
(C<lot>, a name) and a package (C<package>, a name), and the counted C<quantity>. A row whose quant exists
and already holds that quantity is C<unchanged> (nothing is sent). Every other row is one change: the apply
creates the quant in the quant's inventory mode (Odoo makes it when it is missing, finds it when it is not,
and sets its counted quantity: C<stock.quant.create> with C<inventory_quantity> and the context
C<inventory_mode>), then calls C<action_apply_inventory> on it. Odoo makes the inventory move; the quantity is
not written. The C<reason> is the move's name (the context C<inventory_name>, as the adjustment name of Odoo's
own screen).

Planned, approved and applied like any stock operation. The apply reads the quant back and the change is
verified when it holds the counted quantity; the result also says the total of the product and lot over the
internal locations before and after (C<returned.lot_total_before>, C<returned.lot_total_after>), which a count
changes by its difference: the C<lot-totals-internal> invariant, which says a move leaves each total as it was,
does not judge a count and is not applied to it.

A revert is a counter-adjustment: a change of the same kind counting the quantity that was on hand before, planned
only while the quant still holds what the run left (a count that moved since is a stale plan).

Where Odoo asks something instead of applying (the inventory conflict wizard, the tracked-product wizard), the change
fails with Odoo's model named, and nothing further is applied; the quant is left with the counted quantity set, as
Odoo's screen leaves it before the Apply is confirmed. The user needs Odoo's inventory rights (C<stock.group_stock_user>);
without them Odoo treats the create as an ordinary one and refuses it.

Buckets: C<adjust> (one change), C<unchanged> (skipped). Hold: C<ambiguous> (more than one quant of the product, location,
lot and package, such as one for each owner: count it in Odoo).

=cut

sub op_name ($class) { 'stock.adjust' }
sub summary ($class) { 'Plan a stock count applied through Odoo\'s inventory mode (inventory_quantity, then action_apply_inventory)' }
sub pack    ($class) { 'stock' }
sub buckets ($class) {
    return [
        { name => 'adjust',    meaning => 'the quant is counted: Odoo\'s inventory mode sets the counted quantity and applies it, making the inventory move' },
        { name => 'unchanged', meaning => 'the quant already holds the counted quantity (or none is held and none was counted); nothing is sent' },
    ];
}
sub holds ($class) {
    return [ { name => 'ambiguous', meaning => 'more than one quant matches the product, location, lot and package (another owner, say); count it in Odoo' } ];
}

sub params ($class) {
    {   reason => { type => 'str', required => 1, help => 'why: it names the inventory move Odoo makes' },
        rows   => { type => 'rows', required => 1, max => 50,
            row  => { product => 'str', location => 'str', lot => 'str?', package => 'str?', quantity => 'str' },
            help => 'product is a default_code, location a complete name (internal), lot a lot name, package a package name, quantity the counted quantity (0 or more)' },
    };
}

sub read_scope ($class) {
    {   quant    => ['search_read'],
        location => ['search_read'],
        lot      => ['search_read'],
        package  => ['search_read'],
        'product.product' => ['search_read'],
    };
}
sub write_scope ($class) { { quant => [qw(create action_apply_inventory)] } }

# a count changes the total of a lot over the internal locations by its difference, which the lot-totals-internal
# invariant (a move leaves it as it was) cannot judge; the apply reads the totals and says them
sub models_touched ($class, $c) { () }

my $EPS = 0.0005;

sub _n ($v) { 0 + sprintf( '%.3f', $v ) }

sub plan ($self) {
    my $p = $self->profile;
    my $v = $p->validate( $self->client );
    Odoo::Error->throw( kind => 'refused', code => 'profile', message => 'stock profile does not match this server: ' . join( '; ', @{ $v->{missing} } ) ) if !$v->{ok};
    my $f = sub ( $lm, $lf ) { $p->field( $lm => $lf ) };
    my $rows = $self->param('rows');
    Odoo::Error->throw( kind => 'usage', message => "stock.adjust: parameter 'rows' holds no rows" ) if !@$rows;
    my $plan = $self->new_plan( input_count => scalar @$rows );
    my ( %loc, %seen );
    my $n = 0;
    for my $r (@$rows) {
        $n++;
        my $bad = sub ($why) { Odoo::Error->throw( kind => 'usage', message => "stock.adjust: rows row $n: $why" ) };
        $bad->("key 'quantity' must be a number of 0 or more") if $r->{quantity} !~ /\A\d+(?:\.\d+)?\z/;
        my $counted = _n( $r->{quantity} );
        my $pr = $self->client->model('product.product')->search_read( [ [ 'default_code', '=', $r->{product} ] ], [ 'id', 'display_name' ] );
        $bad->("no product with default_code '$r->{product}'") if @$pr != 1;
        my $product = $pr->[0];
        my $location = $loc{ $r->{location} } //= do {
            my $l = $self->model('location')->search_read( [ [ $f->( location => 'complete_name' ), '=', $r->{location} ] ], [ 'id', $f->( location => 'usage' ) ], limit => 1 );
            $bad->("no location named '$r->{location}'") if !@$l;
            $bad->("'$r->{location}' is not an internal location") if $l->[0]{ $f->( location => 'usage' ) } ne 'internal';
            $l->[0]{id};
        };
        my %at = ( product => $product->{id}, location => $location );
        if ( defined $r->{lot} ) {
            my $lots = $self->model('lot')->search_read( [ [ $f->( lot => 'name' ), '=', $r->{lot} ], [ $f->( lot => 'product' ), '=', $product->{id} ] ], ['id'] );
            $bad->("no lot '$r->{lot}' of $r->{product}") if @$lots != 1;
            $at{lot} = $lots->[0]{id};
        }
        if ( defined $r->{package} ) {
            my $pk = $self->model('package')->search_read( [ [ $f->( package => 'name' ), '=', $r->{package} ] ], ['id'] );
            $bad->("no package named '$r->{package}'") if @$pk != 1;
            $at{package} = $pk->[0]{id};
        }
        my $key = join ':', 'adjust', map { $at{$_} // 0 } qw(product location lot package);
        if ( my $first = $seen{$key} ) { $bad->("counts the same quant as row $first (product, location, lot and package) a second time") }
        $seen{$key} = $n;

        my @d = ( [ $f->( quant => 'product' ), '=', $at{product} ], [ $f->( quant => 'location' ), '=', $at{location} ],
            [ $f->( quant => 'lot' ), '=', $at{lot} || JSON::PP::false ], [ $f->( quant => 'package' ), '=', $at{package} || JSON::PP::false ] );
        my $quants = $self->model('quant')->search_read( \@d, [ 'id', $f->( quant => 'quantity' ), $f->( quant => 'reserved' ) ], limit => 2 );
        my $what = $product->{display_name} . ( defined $r->{lot} ? " $r->{lot}" : '' ) . ( defined $r->{package} ? " in $r->{package}" : '' ) . " at $r->{location}";
        if ( @$quants > 1 ) {
            $plan->add( bucket => 'ambiguous', action => 'hold', key => $key, model => $p->model_name('quant'),
                reason => "$what has more than one quant (another owner, say); count it in Odoo" );
            next;
        }
        my $q  = $quants->[0];
        my $on = $q ? _n( $q->{ $f->( quant => 'quantity' ) } ) : 0;
        my $reserved = $q ? _n( $q->{ $f->( quant => 'reserved' ) } // 0 ) : 0;
        if ( abs( $counted - $on ) <= $EPS ) {
            $plan->add( bucket => 'unchanged', action => 'skip', key => $key, model => $p->model_name('quant'),
                reason => $q ? "$what already holds $on" : "$what holds none and none was counted" );
            next;
        }
        $plan->add(
            bucket => 'adjust', action => 'custom', handler => $self->op_name, kind => 'adjust', key => $key,
            model  => $p->model_name('quant'), ( $q ? ( id => $q->{id}, before => { quantity => $on } ) : () ),
            line   => "$what: $on -> $counted" . ( $reserved > $counted + $EPS ? " (reserved $reserved)" : '' ),
            reason => "$what is counted at $counted; $on is on hand" . ( $q ? '' : ' (no quant: Odoo makes it)' ),
            calls  => [ __PACKAGE__->calls ],
            vals   => {
                product => $at{product}, product_name => $product->{display_name}, location => $at{location}, location_name => $r->{location},
                ( defined $at{lot}     ? ( lot => $at{lot}, lot_name => $r->{lot} )             : () ),
                ( defined $at{package} ? ( package => $at{package}, package_name => $r->{package} ) : () ),
                counted => $counted, on_hand => $on, note => $self->param('reason'),
            },
        );
    }
    $plan->note( 'counts applied through Odoo\'s inventory mode: stock.quant.create with inventory_quantity, then action_apply_inventory; reason: ' . $self->param('reason') );
    $plan->note('the lot-totals-internal invariant is not applied: a count changes a lot\'s total by its difference');
    return $plan;
}

=head2 calls

The (model, method) pairs an adjustment is applied with.

=cut

sub calls ($class) {
    return ( ( map { [ 'stock.quant', $_ ] } qw(create action_apply_inventory read search_read) ) );
}

=head2 undo_custom($journal_entry)

The counter-adjustment: the quantity on hand before, counted again, planned from the quantity the run left.

=cut

sub undo_custom ($class, $e) {
    my $v   = $e->{vals};
    my $now = ref $e->{returned} eq 'HASH' ? $e->{returned}{quantity} : undef;
    return ( undef, "journal entry $e->{seq} is not a count" ) if ref $v ne 'HASH' || !defined $v->{counted};
    # a custom change journals what apply_custom returned, not an after-image: it was verified when the read-back is the count
    return ( undef, 'the count was not verified, so there is no quantity to take back from' ) if !defined $now || abs( $now - $v->{counted} ) > $EPS;
    my $quant = $e->{returned}{quant} // $e->{id};
    return {
        action => 'custom', handler => $e->{handler}, kind => 'adjust', bucket => 'undo-adjust',
        model  => $e->{model}, id => $quant, key => "undo:$e->{key}",
        before => { quantity => $now },
        calls  => [ $class->calls ],
        line   => "$v->{product_name}" . ( defined $v->{lot_name} ? " $v->{lot_name}" : '' ) . " at $v->{location_name}: $now -> $v->{on_hand}",
        reason => "the count of $v->{product_name} at $v->{location_name} goes back to $v->{on_hand} (it was counted at $v->{counted})",
        vals   => { %$v, counted => $v->{on_hand}, on_hand => $now, note => "revert: $v->{note}" },
    };
}

sub apply_custom ($class, $client, $c) {
    Odoo::Error->throw( kind => 'usage', message => "stock.adjust cannot apply kind '" . ( $c->{kind} // '' ) . "'" ) if ( $c->{kind} // '' ) ne 'adjust';
    my $v = $c->{vals};
    my $p = Odoo::Ops::Profile->load( pack => 'stock', series => $client->server_series );
    my $f = sub ( $lf ) { $p->field( quant => $lf ) };
    my $quant = $client->model( $p->model_name('quant') );
    my $ctx   = { inventory_mode => JSON::PP::true, ( defined $v->{note} && length $v->{note} ? ( inventory_name => $v->{note} ) : () ) };

    my $total = sub {
        my @d = ( [ $f->('product') => '=', $v->{product} ], [ $f->('location') . '.usage', '=', 'internal' ], [ $f->('lot') => '=', $v->{lot} || JSON::PP::false ] );
        my $sum = 0;
        $sum += $_->{ $f->('quantity') } // 0 for @{ $quant->search_read( \@d, [ 'id', $f->('quantity') ] ) };
        return _n($sum);
    };
    my $before = $total->();

    # Odoo's Physical Inventory: a create in inventory mode finds the quant or makes it, and sets the counted quantity
    my %vals = (
        $f->('product') => $v->{product}, $f->('location') => $v->{location},
        ( $v->{lot}     ? ( $f->('lot')     => $v->{lot} )     : () ),
        ( $v->{package} ? ( $f->('package') => $v->{package} ) : () ),
        inventory_quantity => $v->{counted},
    );
    my $made = $client->execute_kw( $quant->name, 'create', [ \%vals ], { context => $ctx } );
    my $qid  = ref $made eq 'ARRAY' ? $made->[0] : $made;
    Odoo::Error->throw( kind => 'fault', message => "stock.adjust: Odoo gave no quant for the count of $v->{product_name} at $v->{location_name}" )
        if !defined $qid || ref $qid || $qid !~ /\A\d+\z/;
    my $ret = $client->execute_kw( $quant->name, 'action_apply_inventory', [ [$qid] ], { context => $ctx } );
    Odoo::Error->throw( kind => 'fault',
        message => "stock.adjust: action_apply_inventory opened $ret->{res_model} instead of applying the count of $v->{product_name} at $v->{location_name}; the plan allowed no wizard" )
        if ref $ret eq 'HASH' && $ret->{res_model};

    # absence is a quantity of nothing: Odoo removes an emptied quant when it likes
    my $rows = eval { $quant->read( [$qid], [ $f->('quantity') ] ) };
    die $@ if $@ && !( ref $@ && $@->can('is_missing') && $@->is_missing );
    my $now = ref $rows eq 'ARRAY' && @$rows ? _n( $rows->[0]{ $f->('quantity') } // 0 ) : 0;
    my $ok  = abs( $now - $v->{counted} ) <= $EPS;
    return {
        id => $qid, after => ( $ok ? { quantity => $now } : undef ),
        returned => { quant => $qid, on_hand => $v->{on_hand}, counted => $v->{counted}, quantity => $now, lot_total_before => $before, lot_total_after => $total->() },
    };
}

1;
