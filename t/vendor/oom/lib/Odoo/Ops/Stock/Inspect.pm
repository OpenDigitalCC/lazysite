package Odoo::Ops::Stock::Inspect;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Stock::Inspect - the state of a stock record, classified

=head1 DESCRIPTION

C<stock.inspect>: validates the stock profile, reports the stock
modules installed, the picking types with their reservation method,
the valuation method, and then classifies what is wrong with the
quants - the survey a stock repair starts from. Aggregates only unless
C<list=1>, when every classified row is listed by name.

negatives
: every quant below zero in an internal location, matched against
positive, unreserved quants of the same product and lot, in this
order: C<same-place> (a positive in the same location - the stock is
there, against the wrong package), C<same-package> (the same package
positive elsewhere, not in output - the package's record was left
behind), C<unknown> (positive in the "location unknown" bin),
C<output> (positive in an output location, held by no delivery),
C<none> (a genuine shortfall, for a count). Matching is greedy per
negative; what a match covers is a quantity, so a negative can be
part-covered.

split packages
: packages whose quants sit in more than one internal location, or
carry a negative: C<mirror> (+q in unknown and -q in one other place,
same lot, netting to zero), C<partial> (the same, quantities differ),
C<neg-only> (negative somewhere, nothing in unknown), C<other>.

stranded in output
: free quantity in output locations - stock a pick put there that no
delivery has taken, by product and lot.

reservations
: open move lines holding stock, by picking type, and how many were
reserved long after their picking was created (a person pressing
Check Availability rather than the system at confirmation).

The "location unknown" bin and the output locations are named by
parameter; a site without them reports those classes empty.

=cut

sub op_name ($class) { 'stock.inspect' }
sub summary ($class) { 'Stock profile check, modules, and quant anomalies classified (aggregates only)' }
sub pack    ($class) { 'stock' }
sub params ($class) {
    {   unknown => { type => 'str', default => 'WH/Unknown', help => 'complete name of the "location unknown" bin' },
        output  => { type => 'str', default => 'WH/Output',  help => 'complete-name prefix of the output locations' },
        list    => { type => 'bool', default => 0, help => 'list every classified row by name (not only counts)' },
        later_than => { type => 'int', default => 120, help => 'seconds after picking creation beyond which a reservation counts as made later by a person' },
    };
}
sub read_scope ($class) {
    {   quant              => [qw(search_read search_count)],
        location           => ['search_read'],
        package            => ['search_read'],
        lot                => ['search_read'],
        move_line          => ['search_read'],
        picking            => [ 'search_read', 'read' ],
        picking_type       => ['search_read'],
        'ir.module.module' => ['search_read'],
        'product.category' => ['search_read'],
    };
}

my @MODULES = qw(stock sale_stock stock_account product_expiry mrp purchase_stock stock_picking_batch delivery);
my $EPS = 0.001;

sub report ($self) {
    my $p      = $self->profile;
    my $client = $self->client;
    my %r      = (
        server_version => $client->version->{server_version},
        profile        => { pack => $p->pack, series => $p->series, warnings => $p->warnings, validation => $p->validate($client) },
    );
    $r{modules} = $self->_modules;
    return \%r if !$r{modules}{stock};

    $self->{f} = sub ($lm, $lf) { $p->has_field( $lm => $lf ) ? $p->field( $lm => $lf ) : undef };
    $r{picking_types} = $self->_picking_types;
    $r{valuation}     = $self->_valuation;
    $self->_locations;
    $r{locations} = { unknown => $self->{unknown} ? 1 : 0, output => scalar @{ $self->{output} } };

    my $quants = $self->_internal_quants;
    $r{quants} = $self->_quant_totals($quants);
    $r{negatives}        = $self->_negatives($quants);
    $r{split_packages}   = $self->_split_packages($quants);
    $r{stranded_in_output} = $self->_stranded($quants);
    $r{reservations}     = $self->_reservations;
    return \%r;
}

sub _modules ($self) {
    my $rows = eval { $self->client->model('ir.module.module')->search_read( [ [ 'name', 'in', \@MODULES ] ], [qw(name state)] ) };
    return { error => 'module list not readable by this user' } if !$rows;
    return { map { $_->{name} => ( $_->{state} eq 'installed' ? 1 : 0 ) } @$rows };
}

sub _picking_types ($self) {
    my $f = $self->{f};
    my @fields = grep { defined } map { $f->( picking_type => $_ ) } qw(name code reservation_method warehouse);
    my $rows = $self->model('picking_type')->search_read( [], \@fields );
    return [ map {
        my $row = $_;
        +{  name => $row->{ $f->( picking_type => 'name' ) },
            code => $row->{ $f->( picking_type => 'code' ) },
            reservation_method => $row->{ $f->( picking_type => 'reservation_method' ) },
            warehouse => ref $row->{ $f->( picking_type => 'warehouse' ) // '' } ? $row->{ $f->( picking_type => 'warehouse' ) }[1] : undef,
        }
    } @$rows ];
}

# SC5: stock moves post journal entries only under real-time valuation
sub _valuation ($self) {
    my $cats = eval { $self->client->model('product.category')->search_read( [], [ 'name', 'property_valuation' ] ) };
    return { note => 'stock_account not installed or categories not readable' } if !$cats || !@$cats || !exists $cats->[0]{property_valuation};
    my %by;
    $by{ $_->{property_valuation} || 'unset' }++ for @$cats;
    return { categories_by_method => \%by };
}

sub _locations ($self) {
    my $f   = $self->{f};
    my $loc = $self->model('location');
    my $cn  = $f->( location => 'complete_name' );
    my $unk = $loc->search_read( [ [ $cn, '=', $self->param('unknown') ] ], ['id'], limit => 1 );
    $self->{unknown} = @$unk ? $unk->[0]{id} : undef;
    my $out = $loc->search_read( [ [ $cn, '=like', $self->param('output') . '%' ] ], ['id'] );
    $self->{output}  = [ map { $_->{id} } @$out ];
    $self->{is_out}  = { map { $_ => 1 } @{ $self->{output} } };
    my $internal = $loc->search_read( [ [ $f->( location => 'usage' ), '=', 'internal' ] ], [ 'id', $cn ] );
    $self->{loc_name} = { map { $_->{id} => $_->{$cn} } @$internal };
    return;
}

# every non-zero quant in an internal location, in logical shape
sub _internal_quants ($self) {
    my $p    = $self->profile;
    my $f    = $self->{f};
    my @ids  = map { 0 + $_ } keys %{ $self->{loc_name} };    # numeric: a string id in a many2one domain is a name search
    return [] if !@ids;
    my @fields = map { $f->( quant => $_ ) } qw(product lot location package quantity reserved);
    my $rows = $self->model('quant')->all( [ [ $f->( quant => 'location' ), 'in', \@ids ] ], \@fields );
    my @out;
    for my $q (@$rows) {
        my $l = $p->to_logical( quant => $q );
        next if abs( $l->{quantity} // 0 ) <= $EPS;
        push @out, {
            id       => $q->{id},
            product  => _id( $l->{product} ),  product_name => _label( $l->{product} ),
            lot      => _id( $l->{lot} ),      lot_name     => _label( $l->{lot} ),
            location => _id( $l->{location} ), location_name => _label( $l->{location} ),
            package  => _id( $l->{package} ),  package_name => _label( $l->{package} ),
            quantity => $l->{quantity}, reserved => $l->{reserved} // 0,
        };
    }
    return \@out;
}

sub _id    ($v) { ref $v eq 'ARRAY' ? $v->[0] : ( $v ? $v : undef ) }
sub _label ($v) { ref $v eq 'ARRAY' ? $v->[1] : undef }
sub _r     ($n) { 0 + sprintf '%.3f', $n }

sub _quant_totals ($self, $quants) {
    my %t = ( records => scalar @$quants, negative_records => 0, negative_units => 0, reserved_units => 0, units => 0 );
    for my $q (@$quants) {
        $t{units} += $q->{quantity};
        $t{reserved_units} += $q->{reserved};
        if ( $q->{quantity} < -$EPS ) { $t{negative_records}++; $t{negative_units} += -$q->{quantity} }
    }
    $t{$_} = _r( $t{$_} ) for qw(units negative_units reserved_units);
    return \%t;
}

sub _negatives ($self, $quants) {
    my ( %pos, @negs );
    for my $q (@$quants) {
        my $key = join '/', $q->{product}, $q->{lot} // '';
        if ( $q->{quantity} < -$EPS ) { push @negs, $q; next }
        my $free = $q->{quantity} - $q->{reserved};
        push @{ $pos{$key} }, { %$q, free => $free } if $free > $EPS;
    }
    my ( %cover, %mix, @rows, %batches );
    my $unk = $self->{unknown};
    for my $n ( sort { $a->{quantity} <=> $b->{quantity} } @negs ) {
        my $key  = join '/', $n->{product}, $n->{lot} // '';
        my $need = -$n->{quantity};
        my @matches;
        my $take = sub ($kind, @cands) {
            for my $c ( sort { ( abs( $a->{free} - $need ) > $EPS ) <=> ( abs( $b->{free} - $need ) > $EPS ) || $b->{free} <=> $a->{free} } @cands ) {
                last if $need <= $EPS;
                my $t = $need < $c->{free} ? $need : $c->{free};
                next if $t <= $EPS;
                push @matches, { kind => $kind, quantity => _r($t), location => $c->{location_name}, package => $c->{package_name} };
                $c->{free} -= $t;
                $need -= $t;
            }
        };
        my @cands = @{ $pos{$key} // [] };
        $take->( 'same-place',   grep { $_->{location} == $n->{location} } @cands );
        $take->( 'same-package', grep { $n->{package} && $_->{package} && $_->{package} == $n->{package}
                && !$self->{is_out}{ $_->{location} } && $_->{location} != $n->{location} } @cands );
        $take->( 'unknown', grep { $unk && $_->{location} == $unk } @cands );
        $take->( 'output',  grep { $self->{is_out}{ $_->{location} } } @cands );
        push @matches, { kind => 'none', quantity => _r($need) } if $need > $EPS;
        $cover{ $_->{kind} } += $_->{quantity} for @matches;
        my %kinds = map { $_->{kind} => 1 } @matches;
        $mix{ join '/', sort keys %kinds }++;
        $batches{$key} = 1;
        push @rows, { product => $n->{product_name}, lot => $n->{lot_name}, location => $n->{location_name},
            package => $n->{package_name}, quantity => _r( $n->{quantity} ), matches => \@matches };
    }
    my %out = (
        records => scalar @negs, batches => scalar keys %batches,
        units_by_match => { map { $_ => _r( $cover{$_} ) } keys %cover },
        records_by_match_mix => \%mix,
    );
    $out{rows} = \@rows if $self->param('list');
    return \%out;
}

sub _split_packages ($self, $quants) {
    my %by;
    push @{ $by{ $_->{package} } }, $_ for grep { $_->{package} } @$quants;
    my ( %counts, @rows );
    my $unk = $self->{unknown};
    for my $pid ( sort { $a <=> $b } keys %by ) {
        my @qs   = @{ $by{$pid} };
        my %locs = map { $_->{location} => 1 } @qs;
        my @neg  = grep { $_->{quantity} < -$EPS } @qs;
        next if keys %locs < 2 && !@neg;
        my %lots  = map { ( $_->{lot} // '' ) => 1 } @qs;
        my @unkq  = grep { $unk && $_->{location} == $unk } @qs;
        my @other = grep { !$unk || $_->{location} != $unk } @qs;
        my $kind  = 'other';
        if ( keys %lots == 1 && @unkq == 1 && @other == 1 && $other[0]{quantity} < -$EPS && $unkq[0]{quantity} > $EPS ) {
            $kind = abs( $unkq[0]{quantity} + $other[0]{quantity} ) < $EPS ? 'mirror' : 'partial';
        }
        elsif ( @neg && !@unkq ) { $kind = 'neg-only' }
        $counts{$kind}++;
        my $net = 0;
        $net += $_->{quantity} for @qs;
        push @rows, { package => $qs[0]{package_name}, kind => $kind, product => $qs[0]{product_name}, net => _r($net),
            reserved => _r( eval { my $s = 0; $s += $_->{reserved} for @qs; $s } ),
            quants => [ map { { location => $_->{location_name}, lot => $_->{lot_name}, quantity => _r( $_->{quantity} ) } } @qs ] };
    }
    my %out = ( packages_with_stock => scalar keys %by, flagged => scalar @rows, by_kind => \%counts );
    $out{rows} = \@rows if $self->param('list');
    return \%out;
}

sub _stranded ($self, $quants) {
    my ( %by, $units, $n );
    for my $q ( grep { $self->{is_out}{ $_->{location} } && $_->{quantity} > $EPS } @$quants ) {
        my $free = $q->{quantity} - $q->{reserved};
        next if $free <= $EPS;
        $n++;
        $units += $free;
        my $k = join ' ', $q->{product_name} // '', $q->{lot_name} // '';
        $by{$k} += $free;
    }
    my %out = ( records => $n // 0, free_units => _r( $units // 0 ), products_and_lots => scalar keys %by );
    $out{rows} = [ map { { product_lot => $_, free => _r( $by{$_} ) } } sort keys %by ] if $self->param('list');
    return \%out;
}

sub _reservations ($self) {
    my $p = $self->profile;
    my $f = $self->{f};
    my $ml = $self->model('move_line');
    my @domain = ( [ $f->( move_line => 'state' ), 'not in', [ 'done', 'cancel' ] ] );
    my $reserved_f = $f->( move_line => 'reserved' );
    if ($reserved_f) { push @domain, [ $reserved_f, '>', 0 ] }                        # 16
    else { push @domain, [ $f->( move_line => 'done' ), '>', 0 ], [ $f->( move_line => 'picked' ), '=', JSON::PP::false ] }    # 17+
    my @fields = grep { defined } map { $f->( move_line => $_ ) } qw(picking created creator updated updater reserved done);
    my $lines = $ml->all( \@domain, \@fields );
    return { lines => 0 } if !@$lines;
    my %pick_ids = map { my $i = _id( $_->{ $f->( move_line => 'picking' ) } ); defined $i ? ( $i => 1 ) : () } @$lines;
    my $picks = $self->model('picking')->read( [ map { 0 + $_ } sort { $a <=> $b } keys %pick_ids ], [ map { $f->( picking => $_ ) } qw(type created) ] );
    my %pick = map { $_->{id} => $_ } @$picks;
    my ( %by_type, $later, $touched );
    my $limit = $self->param('later_than');
    for my $l (@$lines) {
        my $pid = _id( $l->{ $f->( move_line => 'picking' ) } ) // next;
        my $pk  = $pick{$pid} // next;
        my $type = _label( $pk->{ $f->( picking => 'type' ) } ) // '?';
        $by_type{$type}++;
        my $gap = _epoch( $l->{ $f->( move_line => 'created' ) } ) - _epoch( $pk->{ $f->( picking => 'created' ) } );
        $later++ if $gap > $limit;
        $touched++ if _id( $l->{ $f->( move_line => 'updater' ) } ) && _id( $l->{ $f->( move_line => 'creator' ) } )
            && _id( $l->{ $f->( move_line => 'updater' ) } ) != _id( $l->{ $f->( move_line => 'creator' ) } );
    }
    return { lines => scalar @$lines, by_picking_type => \%by_type, reserved_later_by_a_person => $later // 0, changed_by_another_user => $touched // 0 };
}

sub _epoch ($s) {
    return 0 if !defined $s || $s !~ /^(\d{4})-(\d\d)-(\d\d)[ T](\d\d):(\d\d):(\d\d)/;
    require Time::Local;
    return Time::Local::timegm( $6, $5, $4, $3, $2 - 1, $1 );
}

1;
