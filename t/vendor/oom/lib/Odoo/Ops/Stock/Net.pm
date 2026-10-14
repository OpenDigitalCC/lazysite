package Odoo::Ops::Stock::Net;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();
use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Profile;
use Odoo::Ops::Stock::Transfer;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Stock::Net - plan the transfers that net negatives against their certain counterparts

=head1 DESCRIPTION

C<stock.net>: for every negative quant in an internal location whose
counterpart is certain, one internal transfer that raises the negative
by exactly its match and lowers the counterpart by the same - so each
lot's total over internal locations is unchanged (SE3), which the
apply reads back.

Which counterparts are certain is a parameter (C<kinds>); the default
is the two that need no judgement:

    same-place    a positive quant of the lot in the same location
                  (loose or another package): the stock is there,
                  recorded against the wrong package; the transfer
                  moves it into the negative's package without leaving
                  the location
    mirror        the same package positive elsewhere by exactly the
                  negative quantity, with nothing else in that package
                  there: the package's record was left behind; the
                  transfer moves the whole package

and two that the "location unknown" sweep made usual on one site:

    unknown       a positive of the lot in the unknown bin: the sweep
                  put it there, the negative says where it was taken
                  from; loose or from a package into the negative's
                  package
    same-package  the same package positive elsewhere, quantities
                  differing: taken loose off that package into the
                  negative's package (SE2), so the source package is
                  never split (SA8)

Buckets: C<net> (a transfer), C<uncovered> (no counterpart of an
allowed kind - a count is the only repair), C<partial> (covered in
part; the transfer is planned for the part), C<reserved-counterpart>
(the only counterpart is reserved by an open picking - held),
C<split-package> (the only transfer would put a package in two
places - held). Positives in output locations are never counterparts
(SE4). With C<reverse=1> the plan is the opposite of a previous run's
transfers, named by its journal - the undo.

=cut

sub op_name ($class) { 'stock.net' }
sub summary ($class) { 'Plan internal transfers netting negative quants against certain counterparts' }
sub pack    ($class) { 'stock' }
sub params ($class) {
    {   kinds   => { type => 'list', default => 'same-place,mirror', help => 'counterpart kinds to net: same-place, mirror, unknown, same-package' },
        unknown => { type => 'str',  default => 'WH/Unknown', help => 'complete name of the "location unknown" bin' },
        output  => { type => 'str',  default => 'WH/Output',  help => 'complete-name prefix of output locations (never counterparts)' },
        product => { type => 'str',  help => 'only this product (default_code)' },
        lot     => { type => 'str',  help => 'only this lot (name)' },
        note    => { type => 'str',  default => 'Netted by stock.net: the stock was recorded against the wrong place or package', help => 'internal note on each transfer' },
        reverse => { type => 'path', help => 'journal.jsonl of a previous stock.net run: plan the opposite transfers' },
    };
}
sub read_scope ($class) {
    {   quant        => ['search_read'],
        location     => [qw(search_read read)],
        package      => ['search_read'],
        lot          => ['search_read'],
        picking_type => ['search'],
        'product.product' => [qw(search_read read)],
    };
}
sub write_scope ($class) {
    {   picking   => [qw(create read write)],
        move      => [qw(search_read create)],
        move_line => [qw(search create unlink)],
    };
}
# the apply also confirms, validates and posts on the picking
sub scope_for ($self, $phase) {
    my $s = $self->SUPER::scope_for($phase);
    if ( $phase eq 'apply' ) {
        my $pm = $self->physical_model('picking');
        $s->{$pm} = [ sort( @{ $s->{$pm} }, qw(action_confirm button_validate message_post) ) ];
        $s->{ $self->physical_model('quant') } = [ sort( @{ $s->{ $self->physical_model('quant') } // [] }, 'read' ) ];
    }
    return $s;
}

my $EPS = 0.001;
my %KIND = map { $_ => 1 } qw(same-place mirror unknown same-package);

sub plan ($self) {
    my $p = $self->profile;
    my $v = $p->validate( $self->client );
    Odoo::Error->throw( kind => 'refused', code => 'profile', message => 'stock profile does not match this server: ' . join( '; ', @{ $v->{missing} } ) ) if !$v->{ok};
    for my $k ( @{ $self->param('kinds') } ) {
        Odoo::Error->throw( kind => 'usage', message => "stock.net: unknown kind '$k' (same-place, mirror, unknown, same-package)" ) if !$KIND{$k};
    }
    return $self->_plan_reverse if $self->param('reverse');

    my %want = map { $_ => 1 } @{ $self->param('kinds') };
    my $f = sub ($lm, $lf) { $p->field( $lm => $lf ) };
    my $loc = $self->model('location');
    my $cn  = $f->( location => 'complete_name' );
    my $unk = $loc->search_read( [ [ $cn, '=', $self->param('unknown') ] ], ['id'], limit => 1 );
    $unk = @$unk ? $unk->[0]{id} : undef;
    my %is_out = map { $_->{id} => 1 } @{ $loc->search_read( [ [ $cn, '=like', $self->param('output') . '%' ] ], ['id'] ) };
    my $internal = $loc->search_read( [ [ $f->( location => 'usage' ), '=', 'internal' ] ], [ 'id', $cn ] );
    my %loc_name = map { $_->{id} => $_->{$cn} } @$internal;

    my @domain = ( [ $f->( quant => 'location' ), 'in', [ map { 0 + $_ } keys %loc_name ] ] );
    if ( my $code = $self->param('product') ) {
        my $pr = $self->client->model('product.product')->search_read( [ [ 'default_code', '=', $code ] ], ['id'] );
        Odoo::Error->throw( kind => 'usage', message => "stock.net: no product with default_code '$code'" ) if !@$pr;
        push @domain, [ $f->( quant => 'product' ), 'in', [ map { $_->{id} } @$pr ] ];
    }
    if ( my $ln = $self->param('lot') ) {
        my $lots = $self->model('lot')->search_read( [ [ $f->( lot => 'name' ), '=', $ln ] ], ['id'] );
        Odoo::Error->throw( kind => 'usage', message => "stock.net: no lot named '$ln'" ) if !@$lots;
        push @domain, [ $f->( quant => 'lot' ), 'in', [ map { $_->{id} } @$lots ] ];
    }
    my @fields = map { $f->( quant => $_ ) } qw(product lot location package quantity reserved);
    my @quants;
    for my $q ( @{ $self->model('quant')->all( \@domain, \@fields ) } ) {
        my $l = $p->to_logical( quant => $q );
        next if abs( $l->{quantity} // 0 ) <= $EPS;
        push @quants, { id => $q->{id}, map( { ( $_ => _id( $l->{$_} ), "${_}_name" => _label( $l->{$_} ) ) } qw(product lot location package) ),
            quantity => $l->{quantity}, reserved => $l->{reserved} // 0 };
    }
    my ( %pos, %by_pkg_loc, @negs );
    for my $q (@quants) {
        my $key = join '/', $q->{product}, $q->{lot} // '';
        if ( $q->{quantity} < -$EPS ) { push @negs, $q; next }
        next if $is_out{ $q->{location} };    # SE4
        push @{ $pos{$key} }, { %$q, free => $q->{quantity} - $q->{reserved} };
        $by_pkg_loc{ ( $q->{package} // 0 ) . '@' . $q->{location} }++ if $q->{package};
    }

    my $plan = $self->new_plan( input_count => scalar @negs );
    $plan->note( 'negatives considered: ' . scalar(@negs) . '; kinds netted: ' . join( ', ', sort keys %want ) );
    my %lot_total;    # SE3 invariant per product/lot, over internal locations
    for my $q (@quants) { $lot_total{ join '/', $q->{product}, $q->{lot} // '' } += $q->{quantity} }
    for my $n ( sort { $a->{quantity} <=> $b->{quantity} } @negs ) {
        my $key  = join '/', $n->{product}, $n->{lot} // '';
        my $need = -$n->{quantity};
        my @cands = grep { $_->{quantity} > $EPS && $_->{id} != $n->{id} } @{ $pos{$key} // [] };
        my ( @transfers, $held );
        my $plan_take = sub ($kind, $c, $qty, $result_package) {
            push @transfers, {
                kind => $kind, quant => $c, quantity => $qty,
                from => $c->{location}, from_name => $c->{location_name}, package => $c->{package}, package_name => $c->{package_name},
                to => $n->{location}, to_name => $n->{location_name},
                result_package => $result_package, result_package_name => $result_package ? $n->{package_name} : undef,
            };
            $c->{free} -= $qty;
            $need -= $qty;
        };
        # same-place: a positive in the same location, loose or in another package
        if ( $want{'same-place'} && $need > $EPS ) {
            for my $c ( sort { $b->{free} <=> $a->{free} } grep { $_->{location} == $n->{location} && ( $_->{package} // 0 ) != ( $n->{package} // 0 ) } @cands ) {
                last if $need <= $EPS;
                if ( $c->{free} <= $EPS ) { $held //= 'reserved-counterpart' if $c->{quantity} > $EPS; next }
                my $t = $need < $c->{free} ? $need : $c->{free};
                $plan_take->( 'same-place', $c, $t, $n->{package} );
            }
        }
        # mirror: the same package elsewhere, exactly the quantity, alone in that package there
        if ( $want{mirror} && $need > $EPS && $n->{package} ) {
            for my $c ( grep { $_->{package} && $_->{package} == $n->{package} && $_->{location} != $n->{location} } @cands ) {
                last if $need <= $EPS;
                next if abs( $c->{quantity} - $need ) > $EPS;
                next if ( $by_pkg_loc{"$c->{package}\@$c->{location}"} // 0 ) != 1;
                if ( $c->{free} < $need - $EPS ) { $held //= 'reserved-counterpart'; next }
                $plan_take->( 'mirror', $c, $need, $n->{package} );
            }
        }
        # unknown: the bin the sweep filled
        if ( $want{unknown} && $need > $EPS && $unk ) {
            for my $c ( sort { $b->{free} <=> $a->{free} } grep { $_->{location} == $unk && $_->{location} != $n->{location} } @cands ) {
                last if $need <= $EPS;
                if ( $c->{free} <= $EPS ) { $held //= 'reserved-counterpart' if $c->{quantity} > $EPS; next }
                my $t = $need < $c->{free} ? $need : $c->{free};
                if ( $c->{package} && $n->{package} && $c->{package} == $n->{package} && $t < $c->{quantity} - $EPS ) { $held //= 'split-package'; next }    # SA8
                $plan_take->( 'unknown', $c, $t, $n->{package} );
            }
        }
        # same-package, quantities differing: loose off that package into the negative's package
        if ( $want{'same-package'} && $need > $EPS && $n->{package} ) {
            for my $c ( grep { $_->{package} && $_->{package} == $n->{package} && $_->{location} != $n->{location} } @cands ) {
                last if $need <= $EPS;
                if ( $c->{free} <= $EPS ) { $held //= 'reserved-counterpart'; next }
                my $t = $need < $c->{free} ? $need : $c->{free};
                # the same package cannot be in two places after the move: a partial take arrives loose
                if ( $t < $c->{quantity} - $EPS ) { $held //= 'split-package'; next }
                $plan_take->( 'same-package', $c, $t, $n->{package} );
            }
        }

        my $qkey = "quant:$n->{id}";
        if ( !@transfers ) {
            $plan->add( bucket => $held // 'uncovered', action => 'hold', key => $qkey,
                reason => ( $held ? "counterpart is $held" : 'no counterpart of an allowed kind' ) . " for $n->{product_name} " . ( $n->{lot_name} // 'no lot' ) . " $n->{location_name} " . ( $n->{package_name} // 'loose' ) . " ($n->{quantity})" );
            next;
        }
        my $covered = 0;
        $covered += $_->{quantity} for @transfers;
        my $bucket = $covered < $need - $EPS ? 'partial' : 'net';
        my $running = $n->{quantity};
        for my $t (@transfers) {
            $running += $t->{quantity};
            $plan->add( %{ Odoo::Ops::Stock::Transfer::change( $self,
                bucket => $bucket, key => "$qkey:$t->{kind}:" . ( $t->{quant}{id} ),
                reason => "$t->{kind}: $t->{quantity} of $n->{product_name} " . ( $n->{lot_name} // 'no lot' ) . " from $t->{from_name} " . ( $t->{package_name} // 'loose' ) . " into $n->{location_name} " . ( $n->{package_name} // 'loose' ),
                product => $n->{product}, product_name => $n->{product_name}, lot => $n->{lot}, lot_name => $n->{lot_name},
                from => $t->{from}, from_name => $t->{from_name}, to => $t->{to}, to_name => $t->{to_name},
                package => $t->{package}, package_name => $t->{package_name},
                result_package => $t->{result_package}, result_package_name => $t->{result_package_name},
                quantity => $t->{quantity}, note => $self->param('note'),
                expect => [ { quant => $n->{id}, quantity => 0 + sprintf( '%.3f', $running ) },
                            { quant => $t->{quant}{id}, quantity => 0 + sprintf( '%.3f', $t->{quant}{quantity} - $t->{quantity} ) } ],
            ) } );
            $t->{quant}{quantity} -= $t->{quantity};
        }
    }
    $plan->note( 'invariant: each lot total over internal locations unchanged - ' . scalar( keys %lot_total ) . ' lots held' );
    return $plan;
}

# reverse=<journal> is a thin wrapper over undo_custom, the code oom-ops revert reaches
sub _plan_reverse ($self) {
    return Odoo::Ops::Stock::Transfer->reverse_plan( $self, $self->param('reverse') );
}

# how one done transfer is undone (Runner->revert_plan): the opposite transfer
sub undo_custom ($class, $entry) { return Odoo::Ops::Stock::Transfer->undo_change($entry) }

sub models_touched ($class, $c) { Odoo::Ops::Stock::Transfer->models_touched($c) }

sub apply_custom ($class, $client, $c) {
    Odoo::Error->throw( kind => 'usage', message => "stock.net cannot apply kind '$c->{kind}'" ) if ( $c->{kind} // '' ) ne 'transfer';
    my $profile = Odoo::Ops::Profile->load( pack => 'stock', series => $client->server_series );
    return Odoo::Ops::Stock::Transfer->apply( $client, $c, $profile );
}

sub _id    ($v) { ref $v eq 'ARRAY' ? $v->[0] : ( $v ? $v : undef ) }
sub _label ($v) { ref $v eq 'ARRAY' ? $v->[1] : undef }

1;
