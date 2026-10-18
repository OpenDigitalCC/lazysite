package Odoo::Ops::Stock::Transfer;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();
use Odoo::Error;
use Odoo::Commands qw(x2m_create);
use Odoo::Ops::Journal;
use Odoo::Ops::Profile;
use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Stock::Transfer - one internal transfer, planned and applied the same way by every stock write

=head1 DESCRIPTION

C<stock.transfer> plans one internal transfer of one or more lines (product,
lot, quantity, source package, result package) from one location to another,
with a reason, and is also the code every stock write applies a transfer with.

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

A transfer carries one line (C<product>, C<lot>, C<quantity>, C<package>,
C<result_package> on the change) or a list of them (C<lines>), all between the
same two locations. Lines of one product are one move; each line is one move
line. The steps are the same for any number of lines.

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
    my $lines = $t{lines};
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
            ( $lines ? ( lines => $lines ) : () ),
            quantity   => 0 + sprintf( '%.3f', $t{quantity} ),
            note       => $t{note},
            expect     => $t{expect} // [],    # [ { quant => id, quantity => after } ]
        },
        irreversible => 'a validated transfer is undone by the opposite transfer (oom-ops revert, or reverse=<journal>)',
        calls        => [ __PACKAGE__->calls ],
    };
}

=head2 calls

The (model, method) pairs a transfer is applied with, as C<[[model, method], ...]>
in physical model names (the stock models are the same on every series): what a C<custom> change of kind C<transfer> declares in
C<calls> so its operation's scope is checked when the plan is made.

=cut

sub calls ($class) {
    return (
        ( map { [ 'stock.picking', $_ ] } qw(create action_confirm button_validate message_post read) ),
        [ 'stock.move', 'search_read' ],
        ( map { [ 'stock.move.line', $_ ] } qw(search create unlink) ),
        [ 'stock.quant', 'read' ],
        [ 'stock.location', 'read' ],
        [ 'stock.picking.type', 'search' ],
        [ 'product.product', 'read' ],
    );
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
    my $pkg = $v->{package} || $v->{result_package} || ( $v->{lines} && grep { $_->{package} || $_->{result_package} } @{ $v->{lines} } );
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
                ( $v->{lines} ? ( lines => [ map { +{ %$_, package => $_->{result_package}, package_name => $_->{result_package_name},
                    result_package => $_->{package}, result_package_name => $_->{package_name} } } @{ $v->{lines} } ] ) : () ),
                quantity => $v->{quantity},
                note     => 'Reversal of ' . ( $e->{returned} // $e->{key} // "change $e->{seq}" ),
                expect   => [],
            },
            irreversible => 'a validated transfer is undone by the opposite transfer (oom-ops revert, or reverse=<journal>)',
            calls        => [ $class->calls ],
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

# --- the operation ---------------------------------------------------------

sub op_name ($class) { 'stock.transfer' }
sub summary ($class) { 'Plan one internal transfer of one or more lines (product, lot, quantity, package) from one location to another' }
sub pack    ($class) { 'stock' }
sub buckets ($class) {
    return [ { name => 'transfer', meaning => 'one internal transfer of the lines given, between two internal locations' } ];
}

sub params ($class) {
    {   from   => { type => 'str', required => 1, help => 'complete name of the source location, e.g. WH/Stock/Bay A' },
        to     => { type => 'str', required => 1, help => 'complete name of the destination, e.g. WH/Stock/Bay B' },
        reason => { type => 'str', required => 1, help => 'why: goes on the transfer as its note' },
        lines  => { type => 'rows', required => 1, max => 50,
            row  => { product => 'str', lot => 'str?', quantity => 'str', package => 'str?', result_package => 'str?' },
            help => 'product is a default_code, lot a lot name, package and result_package package names, quantity a positive number; a package moved whole names it as both package and result_package' },
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

sub plan ($self) {
    my $p = $self->profile;
    my $v = $p->validate( $self->client );
    Odoo::Error->throw( kind => 'refused', code => 'profile', message => 'stock profile does not match this server: ' . join( '; ', @{ $v->{missing} } ) ) if !$v->{ok};
    my $f   = sub ($lm, $lf) { $p->field( $lm => $lf ) };
    my %at;
    for my $which (qw(from to)) {
        my $rows = $self->model('location')->search_read( [ [ $f->( location => 'complete_name' ), '=', $self->param($which) ] ], [ 'id', $f->( location => 'usage' ) ], limit => 1 );
        Odoo::Error->throw( kind => 'usage', message => "stock.transfer: no location named '" . $self->param($which) . "'" ) if !@$rows;
        Odoo::Error->throw( kind => 'usage', message => "stock.transfer: '" . $self->param($which) . "' is not an internal location" )
            if $rows->[0]{ $f->( location => 'usage' ) } ne 'internal';
        $at{$which} = $rows->[0]{id};
    }
    Odoo::Error->throw( kind => 'usage', message => 'stock.transfer: from and to are the same location' ) if $at{from} == $at{to};

    Odoo::Error->throw( kind => 'usage', message => "stock.transfer: parameter 'lines' holds no rows" ) if !@{ $self->param('lines') };
    my ( @lines, %taken, @expect, $total );
    my $n = 0;
    for my $r ( @{ $self->param('lines') } ) {
        $n++;
        my $q = $r->{quantity};
        Odoo::Error->throw( kind => 'usage', message => "stock.transfer: parameter 'lines' row $n: key 'quantity' must be a positive number" )
            if $q !~ /\A\d+(?:\.\d+)?\z/ || $q <= 0;
        my $pr = $self->client->model('product.product')->search_read( [ [ 'default_code', '=', $r->{product} ] ], [ 'id', 'display_name' ] );
        Odoo::Error->throw( kind => 'usage', message => "stock.transfer: lines row $n: no product with default_code '$r->{product}'" ) if @$pr != 1;
        my %l = ( product => $pr->[0]{id}, product_name => $pr->[0]{display_name}, quantity => 0 + $q );
        if ( defined $r->{lot} ) {
            my $lots = $self->model('lot')->search_read( [ [ $f->( lot => 'name' ), '=', $r->{lot} ], [ $f->( lot => 'product' ), '=', $l{product} ] ], ['id'] );
            Odoo::Error->throw( kind => 'usage', message => "stock.transfer: lines row $n: no lot '$r->{lot}' of $r->{product}" ) if @$lots != 1;
            @l{qw(lot lot_name)} = ( $lots->[0]{id}, $r->{lot} );
        }
        for my $k (qw(package result_package)) {
            next if !defined $r->{$k};
            my $pk = $self->model('package')->search_read( [ [ $f->( package => 'name' ), '=', $r->{$k} ] ], ['id'] );
            Odoo::Error->throw( kind => 'usage', message => "stock.transfer: lines row $n: no package named '$r->{$k}'" ) if @$pk != 1;
            @l{ $k, "${k}_name" } = ( $pk->[0]{id}, $r->{$k} );
        }
        # the quant this line draws from, when it is one: its read-back is predicted
        my @d = ( [ $f->( quant => 'product' ), '=', $l{product} ], [ $f->( quant => 'location' ), '=', $at{from} ],
            [ $f->( quant => 'lot' ), '=', $l{lot} || JSON::PP::false ], [ $f->( quant => 'package' ), '=', $l{package} || JSON::PP::false ] );
        my $quants = $self->model('quant')->search_read( \@d, [ 'id', $f->( quant => 'quantity' ) ], limit => 2 );
        if ( @$quants == 1 ) {
            $taken{ $quants->[0]{id} } += $l{quantity};
            push @expect, [ $quants->[0]{id}, $quants->[0]{ $f->( quant => 'quantity' ) } ];
        }
        $total += $l{quantity};
        push @lines, \%l;
    }
    my %seen;
    my @expect_rows = map { { quant => $_->[0], quantity => 0 + sprintf( '%.3f', $_->[1] - $taken{ $_->[0] } ) } } grep { !$seen{ $_->[0] }++ } @expect;

    my $plan = $self->new_plan( input_count => 1 );
    my $names = join ', ', map { "$_->{quantity} of $_->{product_name}" . ( $_->{lot_name} ? " $_->{lot_name}" : '' ) . ( $_->{package_name} ? " in $_->{package_name}" : '' ) } @lines;
    $plan->add( %{ change( $self,
        bucket => 'transfer', key => 'transfer:' . $self->param('from') . '>' . $self->param('to'),
        reason => "$names from " . $self->param('from') . ' to ' . $self->param('to'),
        from => $at{from}, from_name => $self->param('from'), to => $at{to}, to_name => $self->param('to'),
        lines => \@lines, quantity => $total, note => $self->param('reason'), expect => \@expect_rows,
    ) } );
    $plan->note( scalar(@lines) . ' line(s) from ' . $self->param('from') . ' to ' . $self->param('to') . '; reason: ' . $self->param('reason') );
    return $plan;
}

sub undo_custom ($class, $entry) { return $class->undo_change($entry) }

sub apply_custom ($class, $client, $c) {
    Odoo::Error->throw( kind => 'usage', message => "stock.transfer cannot apply kind '$c->{kind}'" ) if ( $c->{kind} // '' ) ne 'transfer';
    my $profile = Odoo::Ops::Profile->load( pack => 'stock', series => $client->server_series );
    return $class->apply( $client, $c, $profile );
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

    # one line as the change always carried it, or the list of them
    my @lines = $v->{lines} ? @{ $v->{lines} } : ( { map { $_ => $v->{$_} } qw(product lot package result_package quantity) } );
    Odoo::Error->throw( kind => 'usage', message => "transfer $c->{key} has no lines" ) if !@lines;
    my ( @products, %demand );
    for my $l (@lines) {
        push @products, $l->{product} if !exists $demand{ $l->{product} };
        $demand{ $l->{product} } += $l->{quantity};
    }

    my $type_id = _internal_type( $client, $p, $v->{from} );
    my %prod = map { $_->{id} => $_ } @{ $client->model('product.product')->read( \@products, [ 'uom_id', 'display_name' ] ) };
    for my $id (@products) {
        Odoo::Error->throw( kind => 'fault', message => "transfer $c->{key}: product $id was not found" ) if !$prod{$id};
    }
    my %pick = (
        $f->( picking => 'type' )        => $type_id,
        $f->( picking => 'source' )      => $v->{from},
        $f->( picking => 'destination' ) => $v->{to},
        $f->( picking => 'origin' )      => substr( $c->{key} // 'oom', 0, 64 ),
        $f->( picking => 'moves' )       => [ map { x2m_create( {
            $f->( move => 'name' ) ? ( $f->( move => 'name' ) => $prod{$_}{display_name} ) : (),
            $f->( move => 'product' )     => $_,
            $f->( move => 'demand' )      => 0 + sprintf( '%.3f', $demand{$_} ),
            $f->( move => 'uom' )         => $prod{$_}{uom_id}[0],
            $f->( move => 'source' )      => $v->{from},
            $f->( move => 'destination' ) => $v->{to},
        } ) } @products ],
    );
    $pick{ $f->( picking => 'immediate' ) } = JSON::PP::true if $f->( picking => 'immediate' );
    my $pid = $picking->create( \%pick );
    $picking->call( 'action_confirm', [ [$pid] ] );
    # SA6: the move ids are looked up after confirming, never assumed
    my %mv;
    for my $m ( @{ $move->search_read( [ [ $f->( move => 'picking' ), '=', $pid ] ], [ 'id', $f->( move => 'product' ) ] ) } ) {
        my $pr = $m->{ $f->( move => 'product' ) };
        $mv{ ref $pr ? $pr->[0] : $pr } = $m->{id};
    }
    for my $id (@products) {
        Odoo::Error->throw( kind => 'fault', message => "transfer $pid has no move for product $id after confirmation" ) if !$mv{$id};
    }
    # 17+: confirmation may have reserved lines of Odoo's choosing; ours replace them
    my $old = $line->search( [ [ $f->( move_line => 'picking' ), '=', $pid ] ] );
    $line->unlink($old) if @$old;
    for my $l (@lines) {
        my %ml = (
            $f->( move_line => 'move' )        => $mv{ $l->{product} },
            $f->( move_line => 'picking' )     => $pid,
            $f->( move_line => 'product' )     => $l->{product},
            $f->( move_line => 'source' )      => $v->{from},
            $f->( move_line => 'destination' ) => $v->{to},
            ( $l->{lot}            ? ( $f->( move_line => 'lot' ) => $l->{lot} ) : () ),
            ( $l->{package}        ? ( $f->( move_line => 'package' ) => $l->{package} ) : () ),
            ( $l->{result_package} ? ( $f->( move_line => 'result_package' ) => $l->{result_package} ) : () ),
            $f->( move_line => 'done' ) => $l->{quantity},
        );
        $ml{ $f->( move_line => 'picked' ) } = JSON::PP::true if $f->( move_line => 'picked' );
        $ml{product_uom_id} = $prod{ $l->{product} }{uom_id}[0];
        $line->create( \%ml );
    }
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
