package Odoo::Ops::Stock::Relocate;

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

Odoo::Ops::Stock::Relocate - move stock whose place a document has now established

=head1 DESCRIPTION

C<stock.relocate>: every free quant in one location (the "location
unknown" bin, a bay emptied by a count) goes to the location a
document now names, one internal transfer per quant, with the reason
on each transfer. Packages travel whole and keep their identity; a
quant partly reserved travels for its free part only (held
C<reserved> when nothing is free); negatives never travel (they are
C<stock.net>'s business). C<product> and C<lot> narrow the set.

Buckets: C<relocate>, C<reserved>, C<negative>; a source holding no
stock of the filter plans nothing and says so in a note. Each change predicts the
source quant at zero (or at its reserved part) and the apply reads
it back. C<reverse=<journal>> plans the way back.

=cut

sub op_name ($class) { 'stock.relocate' }
sub summary ($class) { 'Plan internal transfers moving the free stock of one location to another, with the reason' }
sub pack    ($class) { 'stock' }
# What a plan of this operation sorts rows into (oom-ops describe prints them;
# t/99-declared-buckets.t checks them against what the tests plan).
sub buckets ($class) {
    return [
        { name => 'relocate', meaning => 'a free quant moves to the location a document names, by one internal transfer' },
        { name => 'reverse', meaning => 'reverse=JOURNAL: the way back for a previous run\'s transfer' },
    ];
}
sub holds ($class) {
    return [
        { name => 'reserved', meaning => 'the quant is reserved by an open picking and nothing of it is free' },
        { name => 'negative', meaning => 'the quant is negative; stock.net repairs those' },
    ];
}

sub params ($class) {
    {   from    => { type => 'str', required => 1, help => 'complete name of the source location, e.g. WH/Unknown' },
        to      => { type => 'str', required => 1, help => 'complete name of the destination, e.g. WH/Stock/Bay A' },
        reason  => { type => 'str', required => 1, help => 'why: the document that established the place (goes on each transfer)' },
        product => { type => 'str', help => 'only this product (default_code)' },
        lot     => { type => 'str', help => 'only this lot (name)' },
        reverse => { type => 'path', help => 'journal.jsonl of a previous stock.relocate run: plan the way back' },
    };
}
sub read_scope ($class) {
    {   quant        => ['search_read'],
        location     => [qw(search_read read)],
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

sub plan ($self) {
    my $p = $self->profile;
    my $v = $p->validate( $self->client );
    Odoo::Error->throw( kind => 'refused', code => 'profile', message => 'stock profile does not match this server: ' . join( '; ', @{ $v->{missing} } ) ) if !$v->{ok};
    return $self->_plan_reverse if $self->param('reverse');
    my $f   = sub ($lm, $lf) { $p->field( $lm => $lf ) };
    my $loc = $self->model('location');
    my $cn  = $f->( location => 'complete_name' );
    my %at;
    for my $which (qw(from to)) {
        my $rows = $loc->search_read( [ [ $cn, '=', $self->param($which) ] ], [ 'id', $f->( location => 'usage' ) ], limit => 1 );
        Odoo::Error->throw( kind => 'usage', message => "stock.relocate: no location named '" . $self->param($which) . "'" ) if !@$rows;
        Odoo::Error->throw( kind => 'usage', message => "stock.relocate: '" . $self->param($which) . "' is not an internal location" )
            if $rows->[0]{ $f->( location => 'usage' ) } ne 'internal';
        $at{$which} = $rows->[0]{id};
    }
    Odoo::Error->throw( kind => 'usage', message => 'stock.relocate: from and to are the same location' ) if $at{from} == $at{to};

    my @domain = ( [ $f->( quant => 'location' ), '=', $at{from} ] );
    if ( my $code = $self->param('product') ) {
        my $pr = $self->client->model('product.product')->search_read( [ [ 'default_code', '=', $code ] ], ['id'] );
        Odoo::Error->throw( kind => 'usage', message => "stock.relocate: no product with default_code '$code'" ) if !@$pr;
        push @domain, [ $f->( quant => 'product' ), 'in', [ map { $_->{id} } @$pr ] ];
    }
    if ( my $ln = $self->param('lot') ) {
        my $lots = $self->model('lot')->search_read( [ [ $f->( lot => 'name' ), '=', $ln ] ], ['id'] );
        Odoo::Error->throw( kind => 'usage', message => "stock.relocate: no lot named '$ln'" ) if !@$lots;
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
    my $plan = $self->new_plan( input_count => scalar @quants );
    $plan->note( 'from ' . $self->param('from') . " ($at{from}) to " . $self->param('to') . " ($at{to}): " . scalar(@quants) . ' quants; reason: ' . $self->param('reason') );
    $plan->note( 'nothing to move: no stock of the filter in ' . $self->param('from') ) if !@quants;
    # a package goes whole when every quant of it here goes; a partial package arrives loose
    my %pkg_quants;
    push @{ $pkg_quants{ $_->{package} } }, $_ for grep { $_->{package} } @quants;
    for my $q ( sort { $a->{id} <=> $b->{id} } @quants ) {
        my $what = ( $q->{product_name} // '' ) . ' ' . ( $q->{lot_name} // 'no lot' ) . ' ' . ( $q->{package_name} // 'loose' );
        if ( $q->{quantity} < -$EPS ) {
            $plan->add( bucket => 'negative', action => 'hold', key => "quant:$q->{id}", reason => "$what is negative ($q->{quantity}); net it first" );
            next;
        }
        my $free = $q->{quantity} - $q->{reserved};
        if ( $free <= $EPS ) {
            $plan->add( bucket => 'reserved', action => 'hold', key => "quant:$q->{id}", reason => "$what is wholly reserved ($q->{reserved} of $q->{quantity})" );
            next;
        }
        my $whole = $q->{package} && $free >= $q->{quantity} - $EPS
            && !grep { $_->{id} != $q->{id} && ( $_->{quantity} - $_->{reserved} ) < $_->{quantity} - $EPS } @{ $pkg_quants{ $q->{package} } };
        $plan->add( %{ Odoo::Ops::Stock::Transfer::change( $self,
            bucket => 'relocate', key => "quant:$q->{id}",
            reason => "$free of $what to " . $self->param('to') . ( $q->{package} && !$whole ? ' (loose: the package stays, partly reserved)' : '' ),
            product => $q->{product}, product_name => $q->{product_name}, lot => $q->{lot}, lot_name => $q->{lot_name},
            from => $at{from}, from_name => $self->param('from'), to => $at{to}, to_name => $self->param('to'),
            package => $q->{package}, package_name => $q->{package_name},
            result_package => ( $whole ? $q->{package} : undef ), result_package_name => ( $whole ? $q->{package_name} : undef ),
            quantity => $free, note => $self->param('reason'),
            expect => [ { quant => $q->{id}, quantity => 0 + sprintf( '%.3f', $q->{quantity} - $free ) } ],
        ) } );
    }
    return $plan;
}

# reverse=<journal> is a thin wrapper over undo_custom, the code oom-ops revert reaches
sub _plan_reverse ($self) {
    return Odoo::Ops::Stock::Transfer->reverse_plan( $self, $self->param('reverse'), $self->param('reason') );
}

# how one done transfer is undone (Runner->revert_plan): the opposite transfer
sub undo_custom ($class, $entry) { return Odoo::Ops::Stock::Transfer->undo_change($entry) }

sub models_touched ($class, $c) { Odoo::Ops::Stock::Transfer->models_touched($c) }

sub apply_custom ($class, $client, $c) {
    Odoo::Error->throw( kind => 'usage', message => "stock.relocate cannot apply kind '$c->{kind}'" ) if ( $c->{kind} // '' ) ne 'transfer';
    my $profile = Odoo::Ops::Profile->load( pack => 'stock', series => $client->server_series );
    return Odoo::Ops::Stock::Transfer->apply( $client, $c, $profile );
}

sub _id    ($v) { ref $v eq 'ARRAY' ? $v->[0] : ( $v ? $v : undef ) }
sub _label ($v) { ref $v eq 'ARRAY' ? $v->[1] : undef }

1;
