package Odoo::Ops::Stock::Transfer;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();
use Odoo::Error;
use Odoo::Commands qw(x2m_create);
use Odoo::Ops::Journal;

=head1 NAME

Odoo::Ops::Stock::Transfer - one internal transfer, planned and applied the same way by every stock write

=head1 DESCRIPTION

A stock repair is a transfer: product and lot, from a location (and
package) to a location (and package), a quantity, a reason. The
stock operations plan transfers as C<custom> changes of kind
C<transfer> and this module applies them: create the picking and its
move, stage the move line with the done quantity (never let Odoo fill
it from a reservation - SA9), validate, refuse any wizard Odoo opens,
and read back the picking's state and the quants the transfer should
have changed.

Series: 16 creates the picking as an immediate transfer so confirming
reserves nothing (SA7) and stages C<qty_done>; 17 and later have no
immediate flag, stage C<quantity> with C<picked>, and the lines Odoo
reserved on confirmation are removed before ours are staged.

A validated picking cannot be un-validated; the undo of a transfer is
the opposite transfer, which the operation plans as its own change
when asked (C<reverse>).

=cut

my $EPS = 0.001;

# the models a validated transfer writes (the picking, its moves and
# lines, and the quants the validation moves): the invariants of each
# are checked around the apply
sub models_touched ($class, $c) { ( $c->{model}, qw(stock.move stock.move.line stock.quant) ) }

# the change a plan carries for one transfer
sub change ($op, %t) {
    my $p = $op->profile;
    my @expect;    # quants that must read back as predicted: [ domain-ish key, quantity after ]
    return {
        bucket  => $t{bucket}, action => 'custom', handler => $op->op_name, kind => 'transfer',
        model   => $p->model_name('picking'), key => $t{key},
        reason  => $t{reason},
        vals    => {
            product    => $t{product},  product_name => $t{product_name},
            lot        => $t{lot},      lot_name     => $t{lot_name},
            from       => $t{from},     from_name    => $t{from_name},
            to         => $t{to},       to_name      => $t{to_name},
            package    => $t{package},  package_name => $t{package_name},            # source package (undef: loose)
            result_package => $t{result_package}, result_package_name => $t{result_package_name},
            quantity   => 0 + sprintf( '%.3f', $t{quantity} ),
            note       => $t{note},
            expect     => $t{expect} // [],    # [ { quant => id, quantity => after } ]
        },
        irreversible => 'a validated transfer is undone by the opposite transfer (oom-ops revert, or reverse=<journal>)',
    };
}

=head2 undo_change($journal_entry)

The undo of one done transfer, as the C<undo_custom> of the operations
that plan transfers returns it: the opposite transfer as a C<custom>
change of the same handler (the destination back to the source, the
result package back to the source package), carrying C<undoes>, or
C<(undef, $reason)> for an entry that is no transfer.

Series caveat, said in the reason: Odoo 16 refuses a move that puts a
package in two places, so a package that the original transfer left in
two places (a partial take) cannot go back by a move there, and the
apply will refuse where Odoo does.

=cut

sub undo_change ($class, $e) {
    my $v = $e->{vals};
    return ( undef, "journal entry $e->{seq} is not a transfer: nothing to undo" )
        if ref $v ne 'HASH' || !$v->{from} || !$v->{to};
    my $pkg = $v->{package} || $v->{result_package};
    return (
        {   bucket => 'reverse', action => 'custom', handler => $e->{handler}, kind => 'transfer',
            model  => $e->{model}, key => 'reverse:' . ( $e->{key} // $e->{seq} ),
            reason => "undo $e->{key}: $v->{quantity} back from $v->{to_name} to $v->{from_name}"
                . ( $pkg ? '; package rule: Odoo 16 refuses a move that puts a package in two places, so on 16 this is refused where the original left the package split' : '' ),
            vals => {
                product => $v->{product}, product_name => $v->{product_name},
                lot     => $v->{lot},     lot_name     => $v->{lot_name},
                from    => $v->{to},      from_name    => $v->{to_name},
                to      => $v->{from},    to_name      => $v->{from_name},
                package => $v->{result_package}, package_name => $v->{result_package_name},
                result_package => $v->{package}, result_package_name => $v->{package_name},
                quantity => $v->{quantity},
                note     => 'Reversal of ' . ( $e->{returned} // $e->{key} // "change $e->{seq}" ),
                expect   => [],
            },
            irreversible => 'a validated transfer is undone by the opposite transfer (oom-ops revert, or reverse=<journal>)',
            undoes       => $e->{seq},
        },
    );
}

=head2 reverse_plan($op, $journal_path, $note_suffix)

The plan behind C<reverse=<journal>>: the C<undo_change> of every done
transfer of C<$op>'s handler in the journal, newest first. The same
code C<oom-ops revert> reaches through C<undo_custom>.

=cut

sub reverse_plan ($class, $op, $path, $suffix = undef) {
    my ( undef, $entries ) = Odoo::Ops::Journal->read($path);
    my @done = grep { ( $_->{action} // '' ) eq 'custom' && ( $_->{handler} // '' ) eq $op->op_name && ( $_->{outcome} // '' ) eq 'done'
        && ref $_->{vals} eq 'HASH' && $_->{vals}{from} } @$entries;
    my $plan = $op->new_plan( input_count => scalar @done );
    $plan->note( "reverse of $path: " . scalar(@done) . ' done transfers' );
    for my $e ( reverse @done ) {
        my ($undo) = $class->undo_change($e);
        $undo->{vals}{note} .= ": $suffix" if defined $suffix;
        $plan->add(%$undo);
    }
    return $plan;
}

# --- apply -----------------------------------------------------------------

sub apply ($class, $client, $c, $profile) {
    my $v  = $c->{vals};
    my $p  = $profile;
    my $f  = sub ($lm, $lf) { $p->has_field( $lm => $lf ) ? $p->field( $lm => $lf ) : undef };
    my $picking = $client->model( $p->model_name('picking') );
    my $move    = $client->model( $p->model_name('move') );
    my $line    = $client->model( $p->model_name('move_line') );
    my $series  = $client->server_series;

    my $type_id = _internal_type( $client, $p, $v->{from} );
    my $prod    = $client->model('product.product')->read_one( $v->{product}, [ 'uom_id', 'display_name' ] );
    my %pick = (
        $f->( picking => 'type' )        => $type_id,
        $f->( picking => 'source' )      => $v->{from},
        $f->( picking => 'destination' ) => $v->{to},
        $f->( picking => 'origin' )      => substr( $c->{key} // 'oom', 0, 64 ),
        $f->( picking => 'moves' )       => [ x2m_create( {
            $f->( move => 'name' ) ? ( $f->( move => 'name' ) => $prod->{display_name} ) : (),
            $f->( move => 'product' )     => $v->{product},
            $f->( move => 'demand' )      => $v->{quantity},
            $f->( move => 'uom' )         => $prod->{uom_id}[0],
            $f->( move => 'source' )      => $v->{from},
            $f->( move => 'destination' ) => $v->{to},
        } ) ],
    );
    $pick{ $f->( picking => 'immediate' ) } = JSON::PP::true if $f->( picking => 'immediate' );
    my $pid = $picking->create( \%pick );
    $picking->call( 'action_confirm', [ [$pid] ] );
    # SA6: the move id is looked up after confirming, never assumed
    my ($mv) = @{ $move->search_read( [ [ $f->( move => 'picking' ), '=', $pid ] ], ['id'] ) };
    Odoo::Error->throw( kind => 'fault', message => "transfer $pid has no move after confirmation" ) if !$mv;
    # 17+: confirmation may have reserved lines of Odoo's choosing; ours replace them
    my $old = $line->search( [ [ $f->( move_line => 'picking' ), '=', $pid ] ] );
    $line->unlink($old) if @$old;
    my %ml = (
        $f->( move_line => 'move' )        => $mv->{id},
        $f->( move_line => 'picking' )     => $pid,
        $f->( move_line => 'product' )     => $v->{product},
        $f->( move_line => 'source' )      => $v->{from},
        $f->( move_line => 'destination' ) => $v->{to},
        ( $v->{lot}            ? ( $f->( move_line => 'lot' ) => $v->{lot} ) : () ),
        ( $v->{package}        ? ( $f->( move_line => 'package' ) => $v->{package} ) : () ),
        ( $v->{result_package} ? ( $f->( move_line => 'result_package' ) => $v->{result_package} ) : () ),
        $f->( move_line => 'done' ) => $v->{quantity},
    );
    $ml{ $f->( move_line => 'picked' ) } = JSON::PP::true if $f->( move_line => 'picked' );
    $ml{product_uom_id} = $prod->{uom_id}[0];
    $line->create( \%ml );
    my $ret = $picking->call( 'button_validate', [ [$pid] ] );
    if ( ref $ret eq 'HASH' && $ret->{res_model} ) {
        Odoo::Error->throw( kind => 'fault', message => "validation opened $ret->{res_model} on transfer $pid; the plan allowed no wizard" );
    }
    if ( $v->{note} ) {
        eval { $picking->call( 'message_post', [$pid], body => $v->{note}, message_type => 'comment', subtype_xmlid => 'mail.mt_note' ) };
    }
    my $after = $picking->read_one( $pid, [ $f->( picking => 'name' ), $f->( picking => 'state' ) ] );
    my $ok = ( $after->{ $f->( picking => 'state' ) } // '' ) eq 'done';
    # the quants the plan predicted
    my $quant = $client->model( $p->model_name('quant') );
    my %got;
    for my $e ( @{ $v->{expect} } ) {
        my $q = $quant->read_one( $e->{quant}, [ $f->( quant => 'quantity' ) ] );
        my $now = $q ? $q->{ $f->( quant => 'quantity' ) } : 0;
        $got{ $e->{quant} } = $now;
        $ok = 0 if abs( $now - $e->{quantity} ) > $EPS;
    }
    return { id => $pid, after => ( $ok ? { %$after, quants => \%got } : undef ), returned => $after->{ $f->( picking => 'name' ) } };
}

# the internal picking type of the warehouse that holds a location
sub _internal_type ($client, $p, $location) {
    my $f  = sub ($lm, $lf) { $p->field( $lm => $lf ) };
    my $loc = $client->model( $p->model_name('location') )->read_one( $location, [ $f->( location => 'warehouse' ) ] );
    my $wh  = ref $loc->{ $f->( location => 'warehouse' ) } ? $loc->{ $f->( location => 'warehouse' ) }[0] : undef;
    # archived included: a one-step warehouse hides its internal type, and a
    # picking of a hidden type is still a valid transfer
    my @domain = ( [ $f->( picking_type => 'code' ), '=', 'internal' ], [ 'active', 'in', [ JSON::PP::true, JSON::PP::false ] ] );
    push @domain, [ $f->( picking_type => 'warehouse' ), '=', $wh ] if $wh;
    my $types = $client->model( $p->model_name('picking_type') )->search( \@domain, limit => 1, order => 'active desc, id' );
    Odoo::Error->throw( kind => 'fault', message => 'no internal picking type' . ( $wh ? " for warehouse $wh" : '' ) ) if !@$types;
    return $types->[0];
}

1;
