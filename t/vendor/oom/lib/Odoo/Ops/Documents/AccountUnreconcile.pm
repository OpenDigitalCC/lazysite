package Odoo::Ops::Documents::AccountUnreconcile;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Documents::Reconcile;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Documents::AccountUnreconcile - undo the reconciliation of journal items

=head1 SYNOPSIS

    oom-ops run account.unreconcile --conf ops.conf --set lines=696,698

=head1 DESCRIPTION

C<account.unreconcile> plans one call of Odoo's C<remove_move_reconcile()> on journal items
(C<account.move.line> ids): the partial reconciles the items hold are removed, and with them any full
reconcile they belonged to. The plan names every partial that goes (its id, the two items it joins, the amount and
date), the full reconciles dissolved, and the other items those partials joined, which are released too
(an item you did not name, on the other side of a partial). An item that holds no partial is held
C<not-reconciled>; an id that is no item is held C<unknown-line>.

Apply refuses C<stale> when the partials the items hold are not the ones the plan named, calls
C<remove_move_reconcile>, and reads back that the partials are gone, the full reconciles dissolved, and every
item the partials joined as it reads now (C<reconciled>, C<residual>, C<matching_number>).

Revert reconciles the items the partials joined again (C<account.reconcile>); Odoo allocates the amounts as it does
for any reconcile, so the partials made may differ from the ones removed when the items had several.

A write operation: plans only; C<apply> carries it out. Series: 16 and 18.

=cut

sub op_name ($class) { 'account.unreconcile' }
sub summary ($class) { 'Plan undoing the reconciliation of journal items (remove_move_reconcile), naming every partial removed' }
sub pack    ($class) { 'account' }
sub params ($class) {
    {   lines => { type => 'list', required => 1, help => 'the journal items (account.move.line ids), comma-separated, such as 696,698' },
    };
}
sub buckets ($class) {
    [ { name => 'unreconcile', meaning => 'the partial reconciles of the journal items are removed through Odoo\'s remove_move_reconcile(); the plan names each' } ];
}
sub holds ($class) {
    [
        { name => 'unknown-line', meaning => 'no journal item has one of the ids' },
        { name => 'not-reconciled', meaning => 'an item holds no partial reconcile, so there is nothing to remove' },
    ];
}
sub read_scope ($class) {
    {   'account.move.line' => [qw(read search_read)], 'account.account' => ['search_read'], 'account.partial.reconcile' => ['search_read'], 'account.full.reconcile' => ['search_read'],
    };
}
# the revert reconciles the items again, under this operation's scope
sub write_scope ($class) { { 'account.move.line' => [ 'remove_move_reconcile', 'reconcile' ], 'account.partial.reconcile' => ['unlink'] } }

sub plan ($self) {
    my $p   = Odoo::Ops::Documents::Reconcile::ready($self);
    my $n   = Odoo::Ops::Documents::Reconcile::names($p);
    my $f   = $n->{f};
    my $ids = Odoo::Ops::Documents::Reconcile::ids( $self, $self->param('lines') );
    @$ids = sort { $a <=> $b } @$ids;
    my ( $line ) = Odoo::Ops::Documents::Reconcile::read_lines( $self, $p, $n, $ids );
    my $plan = $self->new_plan( input_count => 1 );
    my $key  = $self->op_name . ':' . join( ',', @$ids );
    my @missing = grep { !$line->{$_} } @$ids;
    if (@missing) {
        $plan->add( bucket => 'unknown-line', action => 'hold', key => $key, reason => 'no journal item has id ' . join( ', ', @missing ) );
        return $plan;
    }
    my @open = grep { !@{ Odoo::Ops::Documents::Reconcile::idlist( $line->{$_}{ $f->{debits} } ) } && !@{ Odoo::Ops::Documents::Reconcile::idlist( $line->{$_}{ $f->{credits} } ) } } @$ids;
    if (@open) {
        $plan->add( bucket => 'not-reconciled', action => 'hold', key => $key,
            reason => 'journal item' . ( @open == 1 ? ' ' : 's ' ) . join( ', ', @open ) . ( @open == 1 ? ' holds' : ' hold' ) . ' no partial reconcile' );
        return $plan;
    }
    my $partials = Odoo::Ops::Documents::Reconcile::partials_of( $self->client, $n, $ids );
    my %involved = map { ( $_ => 1 ) } map { ( $_->{debit}, $_->{credit} ) } @$partials;
    my @inv = sort { $a <=> $b } keys %involved;
    my ($all) = Odoo::Ops::Documents::Reconcile::read_lines( $self, $p, $n, \@inv );
    $plan->note( 'partial reconcile ' . $_->{id} . ': journal item ' . $_->{debit} . ' (debit) with journal item ' . $_->{credit} . ' (credit), amount '
            . sprintf( '%.2f', $_->{amount} ) . ( $_->{date} ? ", dated $_->{date}" : '' ) . ( $_->{full_reconcile_id} ? ", part of full reconcile $_->{full_reconcile_id}" : '' ) ) for @$partials;
    my %full = map { ( $_->{full_reconcile_id} => 1 ) } grep { $_->{full_reconcile_id} } @$partials;
    $plan->note( 'full reconcile ' . join( ', ', sort { $a <=> $b } keys %full ) . ' is dissolved' ) if %full;
    my @others = grep { !$line->{$_} } @inv;
    $plan->note( 'released as well (not named): ' . join( '; ', map { Odoo::Ops::Documents::Reconcile::line_text( $n, $all->{$_} ) } @others ) ) if @others;
    my @pids = map { $_->{id} } @$partials;
    $plan->add(
        bucket => 'unreconcile', action => 'custom', handler => $self->op_name, kind => 'unreconcile', key => $key, model => $n->{model}{move_line},
        calls  => Odoo::Ops::Documents::Reconcile::unreconcile_calls($n),
        vals   => { via => 'lines', lines => $ids, partials => \@pids, names => $n },
        line   => 'remove ' . scalar(@pids) . ' partial reconcile' . ( @pids == 1 ? '' : 's' ) . ' (' . join( ', ', @pids ) . ') of journal item' . ( @$ids == 1 ? '' : 's' ) . ' ' . join( ', ', @$ids ),
        reason => 'Odoo\'s remove_move_reconcile() removes the partial reconciles ' . join( ', ', @pids ) . ' held by journal items ' . join( ', ', @$ids ),
    );
    return $plan;
}

sub apply_custom ($class, $client, $c) {
    Odoo::Error->throw( kind => 'usage', message => "$c->{handler} cannot apply kind '" . ( $c->{kind} // '' ) . "'" ) if ( $c->{kind} // '' ) ne 'unreconcile';
    return Odoo::Ops::Documents::Reconcile->apply_unreconcile( $client, $c );
}

# the items the removed partials joined are reconciled again
sub undo_custom ($class, $entry) {
    return ( undef, "$entry->{handler} cannot undo kind '" . ( $entry->{kind} // '' ) . "'" ) if ( $entry->{kind} // '' ) ne 'unreconcile';
    my $ret = ref $entry->{returned} eq 'HASH' ? $entry->{returned} : {};
    my @removed = @{ $ret->{removed} // [] };
    return ( undef, 'no partial reconcile was removed, so there is nothing to put back' ) if !@removed;
    my $lines = $ret->{lines} // [];
    return ( undef, 'the items the partials joined were not read back, so they cannot be reconciled again' ) if !@$lines;
    my $v = $entry->{vals};
    my $n = $v->{names};
    my @ids = map { $_->{id} } @$lines;
    return {
        action => 'custom', handler => 'account.reconcile', kind => 'reconcile', bucket => 'undo-unreconcile',
        model => $n->{model}{move_line}, key => 'undo:' . $n->{model}{move_line} . ' ' . join( ',', @ids ),
        calls => Odoo::Ops::Documents::Reconcile::reconcile_calls($n),
        vals  => { lines => \@ids, names => $n, snapshot => { map { $_->{id} => { residual => $_->{residual}, reconciled => $_->{reconciled} ? 1 : 0 } } @$lines }, expected => { kind => 'unknown' } },
        line  => 'reconcile journal items ' . join( ', ', @ids ) . ' again (they were joined by partial reconciles ' . join( ', ', @removed ) . ')',
        reason => 'the items the removed partial reconciles joined are reconciled again; Odoo allocates the amounts as it does for any reconcile',
    };
}

1;
