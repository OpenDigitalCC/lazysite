package Odoo::Ops::Documents::AccountStatementUndo;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Documents::Reconcile;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Documents::AccountStatementUndo - put bank statement lines back to liquidity and suspense

=head1 SYNOPSIS

    oom-ops run account.statement_undo --conf ops.conf --set lines=7,8

=head1 DESCRIPTION

C<account.statement_undo> plans Odoo's C<action_undo_reconciliation()> on bank statement lines
(C<account.bank.statement.line> ids). A reconciled statement line has its entry's liquidity line, and in
place of the suspense line the counterpart lines (an invoice's receivable, an expense, a write-off) with the
partials that join them to what they were matched with, and perhaps payments Odoo made for it. Odoo removes the
partials, deletes the payments, and rebuilds the entry as liquidity plus suspense; the line reads unreconciled.

The plan names what will be removed: each counterpart line (account, partner, balance, the entries it is matched
with) and each payment (name, amount, state). A line whose entry holds only the liquidity and suspense lines and
no payment is held C<not-reconciled>; an id that is no statement line is held C<unknown-line>.

Apply refuses C<stale> when the counterpart lines are not the ones the plan named, calls the action, and reads
back the statement line (C<is_reconciled>, the check flag), the lines of its entry now, and that the partials and
the payments named are gone.

The check flag is C<to_check> on 16 and C<checked> on 18, with the meaning inverted (16 flags a line that needs
checking; 18 flags a line that has been checked); the answer gives the field as Odoo names it.

This cannot be reverted: Odoo deletes the counterpart lines and the payments, and OOM does not recreate them
(C<oom-ops revert> holds the change C<irreversible> and says what was removed). Reconcile the line again with
C<account.reconcile> on the items to match.

A write operation: plans only; C<apply> carries it out. Series: 16 and 18.

=cut

sub op_name ($class) { 'account.statement_undo' }
sub summary ($class) { 'Plan putting bank statement lines back to liquidity plus suspense (action_undo_reconciliation); irreversible' }
sub pack    ($class) { 'account' }
sub params ($class) {
    {   lines => { type => 'list', required => 1, help => 'the bank statement lines (account.bank.statement.line ids), comma-separated, such as 7,8' },
    };
}
sub buckets ($class) {
    [ { name => 'undo', meaning => 'the statement line goes back to liquidity plus suspense through Odoo\'s action_undo_reconciliation(); the plan names what is removed (it cannot be reverted)' } ];
}
sub holds ($class) {
    [
        { name => 'unknown-line', meaning => 'no bank statement line has one of the ids' },
        { name => 'not-reconciled', meaning => 'the entry holds only its liquidity and suspense lines and no payment, so there is nothing to undo' },
    ];
}
sub read_scope ($class) {
    {   'account.bank.statement.line' => [qw(read search_read)], 'account.move.line' => ['search_read'], 'account.journal' => ['read'], 'account.payment' => ['search_read'],
        'account.partial.reconcile' => ['search_read'],
    };
}
sub write_scope ($class) { { 'account.bank.statement.line' => ['action_undo_reconciliation'] } }

sub _check_field ($p) { return $p->has_field( statement_line => 'to_check' ) ? ( 'to_check', $p->field( statement_line => 'to_check' ) ) : ( 'checked', $p->field( statement_line => 'checked' ) ) }

sub _cp_fields ($n) { return [ 'id', @{ $n->{f} }{qw(move account partner balance matching residual debits credits)} ] }

# the counterpart lines of a statement line's entry: every line that is neither on the journal's liquidity account nor on its suspense account
sub _entry ($client, $n, $st, $moves, $jr) {
    my $f = $n->{f};
    my $rows = @$moves ? $client->model( $n->{model}{move_line} )->search_read( [ [ $f->{move}, 'in', $moves ] ], _cp_fields($n), order => 'id' ) : [];
    my %by_move;
    push @{ $by_move{ Odoo::Ops::Documents::Reconcile::idof( $_->{ $f->{move} } ) // 0 } }, $_ for @$rows;
    return \%by_move;
}

sub plan ($self) {
    my $p   = Odoo::Ops::Documents::Reconcile::ready($self);
    my $n   = Odoo::Ops::Documents::Reconcile::names($p);
    my $f   = $n->{f};
    my $ids = Odoo::Ops::Documents::Reconcile::ids( $self, $self->param('lines') );
    @$ids = sort { $a <=> $b } @$ids;
    $n->{model}{statement_line} = $p->model_name('statement_line');
    $n->{model}{payment}        = $p->model_name('payment');
    $n->{model}{journal}        = $p->model_name('journal');
    my ( $flag_logical, $flag ) = _check_field($p);
    my %sf = map { $_ => $p->field( statement_line => $_ ) } qw(move reconciled amount label partner payments journal);
    $n->{st} = { %sf, flag => $flag, flag_logical => $flag_logical };
    $n->{j}  = { liquidity => $p->field( journal => 'liquidity' ), suspense => $p->field( journal => 'suspense' ) };
    $n->{p}  = { name => $p->field( payment => 'name' ), amount => $p->field( payment => 'amount' ), state => $p->field( payment => 'state' ) };
    my $plan = $self->new_plan( input_count => 1 );
    my $key  = $self->op_name . ':' . join( ',', @$ids );
    my $rows = $self->client->model( $n->{model}{statement_line} )->search_read( [ [ 'id', 'in', $ids ] ], [ 'id', @sf{qw(move reconciled amount label partner payments journal)}, $flag ], order => 'id' );
    my %st = map { $_->{id} => $_ } @$rows;
    my @missing = grep { !$st{$_} } @$ids;
    if (@missing) {
        $plan->add( bucket => 'unknown-line', action => 'hold', key => $key, reason => 'no bank statement line has id ' . join( ', ', @missing ) );
        return $plan;
    }
    my @jids = keys %{ { map { ( Odoo::Ops::Documents::Reconcile::idof( $_->{ $sf{journal} } ) // 0 ) => 1 } @$rows } };
    my %jr = map { $_->{id} => $_ } @{ $self->client->model( $n->{model}{journal} )->read( \@jids, [ 'id', @{ $n->{j} }{qw(liquidity suspense)} ] ) };
    my @moves = grep { defined } map { Odoo::Ops::Documents::Reconcile::idof( $_->{ $sf{move} } ) } @$rows;
    my $entry = _entry( $self->client, $n, \%st, \@moves, \%jr );
    my ( @hold, %cp, %pay, @partials );
    for my $id (@$ids) {
        my $r  = $st{$id};
        my $mv = Odoo::Ops::Documents::Reconcile::idof( $r->{ $sf{move} } ) // 0;
        my $j  = $jr{ Odoo::Ops::Documents::Reconcile::idof( $r->{ $sf{journal} } ) // 0 } // {};
        my %special = map { ( Odoo::Ops::Documents::Reconcile::idof( $j->{ $n->{j}{$_} } ) // 0 ) => 1 } qw(liquidity suspense);
        my @counter = grep { !$special{ Odoo::Ops::Documents::Reconcile::idof( $_->{ $f->{account} } ) // 0 } } @{ $entry->{$mv} // [] };
        my @pays = @{ Odoo::Ops::Documents::Reconcile::idlist( $r->{ $sf{payments} } ) };
        if ( !@counter && !@pays ) { push @hold, $id; next }
        $cp{$id}  = \@counter;
        $pay{$id} = \@pays;
    }
    if (@hold) {
        $plan->add( bucket => 'not-reconciled', action => 'hold', key => $key,
            reason => 'bank statement line' . ( @hold == 1 ? ' ' : 's ' ) . join( ', ', @hold ) . ': the entry holds only its liquidity and suspense lines and no payment' );
        return $plan;
    }
    my @all_cp = map { @{ $cp{$_} } } @$ids;
    my %cp_ids = map { $_->{id} => 1 } @all_cp;
    my @pay_ids = sort { $a <=> $b } map { @{ $pay{$_} } } @$ids;
    my %pay_row = @pay_ids ? map { $_->{id} => $_ } @{ $self->client->model( $n->{model}{payment} )->search_read( [ [ 'id', 'in', \@pay_ids ] ], [ 'id', @{ $n->{p} }{qw(name amount state)} ] ) } : ();
    my @pids = sort { $a <=> $b } keys %{ { map { ( $_ => 1 ) } map { ( @{ Odoo::Ops::Documents::Reconcile::idlist( $_->{ $f->{debits} } ) }, @{ Odoo::Ops::Documents::Reconcile::idlist( $_->{ $f->{credits} } ) } ) } @all_cp } };
    for my $id (@$ids) {
        my $r = $st{$id};
        my $flagnote = $flag_logical eq 'to_check' ? ( $r->{$flag} ? 'to check' : 'not flagged to check' ) : ( $r->{$flag} ? 'checked' : 'not checked' );
        $plan->note( "bank statement line $id (" . ( $r->{ $sf{label} } || 'no label' ) . '): amount ' . sprintf( '%.2f', Odoo::Ops::Documents::Reconcile::numof( $r->{ $sf{amount} } ) )
                . ', partner ' . ( Odoo::Ops::Documents::Reconcile::labelof( $r->{ $sf{partner} } ) // 'none' ) . ", $flag $flagnote" );
        for my $c ( @{ $cp{$id} } ) {
            $plan->note( "  removed: journal item $c->{id}, account " . ( Odoo::Ops::Documents::Reconcile::labelof( $c->{ $f->{account} } ) // '-' )
                    . ', partner ' . ( Odoo::Ops::Documents::Reconcile::labelof( $c->{ $f->{partner} } ) // 'none' ) . ', balance ' . sprintf( '%.2f', Odoo::Ops::Documents::Reconcile::numof( $c->{ $f->{balance} } ) )
                    . ( $c->{ $f->{matching} } ? ", matching number $c->{ $f->{matching} }" : '' ) );
        }
        for my $pid ( @{ $pay{$id} } ) {
            my $pr = $pay_row{$pid} or next;
            $plan->note( "  removed: payment $pid ($pr->{ $n->{p}{name} }), amount " . sprintf( '%.2f', Odoo::Ops::Documents::Reconcile::numof( $pr->{ $n->{p}{amount} } ) ) . ", state $pr->{ $n->{p}{state} }" );
        }
    }
    $plan->note( 'partial reconciles removed: ' . join( ', ', @pids ) ) if @pids;
    $plan->note('this cannot be reverted: Odoo deletes the counterpart lines and the payments, and OOM does not recreate them');
    $plan->add(
        bucket => 'undo', action => 'custom', handler => $self->op_name, kind => 'statement_undo', key => $key, model => $n->{model}{statement_line},
        calls  => [ [ $n->{model}{statement_line}, 'read' ], [ $n->{model}{move_line}, 'search_read' ], [ $n->{model}{statement_line}, 'action_undo_reconciliation' ],
            [ $n->{model}{partial}, 'search_read' ], [ $n->{model}{payment}, 'search_read' ] ],
        vals   => { lines => $ids, names => $n, counterparts => { map { $_ => [ map { $_->{id} } @{ $cp{$_} } ] } @$ids }, payments => { map { $_ => $pay{$_} } @$ids }, partials => \@pids,
            moves => { map { $_ => Odoo::Ops::Documents::Reconcile::idof( $st{$_}{ $sf{move} } ) } @$ids } },
        line   => 'undo the reconciliation of bank statement line' . ( @$ids == 1 ? ' ' : 's ' ) . join( ', ', @$ids ) . ': remove ' . scalar(@all_cp) . ' counterpart line' . ( @all_cp == 1 ? '' : 's' )
            . ( @pay_ids ? ' and ' . scalar(@pay_ids) . ' payment' . ( @pay_ids == 1 ? '' : 's' ) : '' ),
        reason => 'Odoo\'s action_undo_reconciliation() removes the counterpart lines and payments of bank statement line' . ( @$ids == 1 ? ' ' : 's ' ) . join( ', ', @$ids ) . ' and rebuilds the entry as liquidity plus suspense',
    );
    return $plan;
}

sub apply_custom ($class, $client, $c) {
    Odoo::Error->throw( kind => 'usage', message => "$c->{handler} cannot apply kind '" . ( $c->{kind} // '' ) . "'" ) if ( $c->{kind} // '' ) ne 'statement_undo';
    my $v = $c->{vals};
    my $n = $v->{names};
    my $f = $n->{f};
    my @ids = @{ $v->{lines} };
    my @want = map { @{ $v->{counterparts}{$_} } } @ids;
    my $ml = $client->model( $n->{model}{move_line} );
    my $now = @want ? $ml->search_read( [ [ 'id', 'in', \@want ] ], ['id'] ) : [];
    my @gone = grep { my $id = $_; !grep { $_->{id} == $id } @$now } @want;
    Odoo::Error->throw( kind => 'refused', code => 'stale', message => 'account.statement_undo: counterpart line' . ( @gone == 1 ? ' ' : 's ' ) . join( ', ', @gone ) . ' no longer exist(s) since the plan was made',
        fix => 'plan it again: oom-ops run account.statement_undo with the same lines' ) if @gone;
    $client->execute_kw( $n->{model}{statement_line}, 'action_undo_reconciliation', [ \@ids ] );
    my $st = $client->model( $n->{model}{statement_line} )->read( \@ids, [ 'id', $n->{st}{reconciled}, $n->{st}{flag} ] );
    my $left = @want ? $ml->search_read( [ [ 'id', 'in', \@want ] ], ['id'] ) : [];
    my @moves = grep { defined } map { $v->{moves}{$_} } @ids;
    my $remain = @moves ? $ml->search_read( [ [ $f->{move}, 'in', \@moves ] ], [ 'id', $f->{account}, $f->{balance} ], order => 'id' ) : [];
    my @pids = @{ $v->{partials} };
    my $pleft = @pids ? $client->model( $n->{model}{partial} )->search_read( [ [ 'id', 'in', \@pids ] ], ['id'] ) : [];
    my @pay = map { @{ $v->{payments}{$_} } } @ids;
    my $payleft = @pay ? $client->model( $n->{model}{payment} )->search_read( [ [ 'id', 'in', \@pay ] ], ['id'] ) : [];
    my %ret = (
        removed_lines => [ grep { my $id = $_; !grep { $_->{id} == $id } @$left } @want ],
        partials_removed => [ grep { my $id = $_; !grep { $_->{id} == $id } @$pleft } @pids ],
        payments_removed => [ grep { my $id = $_; !grep { $_->{id} == $id } @$payleft } @pay ],
        remaining_lines => [ map { { id => $_->{id}, account => Odoo::Ops::Documents::Reconcile::labelof( $_->{ $f->{account} } ), balance => Odoo::Ops::Documents::Reconcile::numof( $_->{ $f->{balance} } ) } } @$remain ],
        statement_lines => [ map { { id => $_->{id}, is_reconciled => $_->{ $n->{st}{reconciled} } ? JSON::PP::true : JSON::PP::false, $n->{st}{flag} => $_->{ $n->{st}{flag} } ? JSON::PP::true : JSON::PP::false } } @$st ],
    );
    my $ok = !@$left && !@$pleft && !@$payleft && !grep { $_->{ $n->{st}{reconciled} } } @$st;
    return { id => undef, returned => \%ret, after => $ok ? { is_reconciled => JSON::PP::false } : undef };
}

sub undo_custom ($class, $entry) {
    return ( undef, "$entry->{handler} cannot undo kind '" . ( $entry->{kind} // '' ) . "'" ) if ( $entry->{kind} // '' ) ne 'statement_undo';
    my $ret = ref $entry->{returned} eq 'HASH' ? $entry->{returned} : {};
    my @l = @{ $ret->{removed_lines} // [] };
    my @p = @{ $ret->{payments_removed} // [] };
    return ( undef, 'Odoo deleted the counterpart line' . ( @l == 1 ? ' ' : 's ' ) . ( @l ? join( ', ', @l ) : '(none read back)' ) . ( @p ? ' and payment' . ( @p == 1 ? ' ' : 's ' ) . join( ', ', @p ) : '' )
            . ' when it put the statement line back to liquidity plus suspense; OOM does not recreate them (reconcile the items again with account.reconcile)' );
}

1;
