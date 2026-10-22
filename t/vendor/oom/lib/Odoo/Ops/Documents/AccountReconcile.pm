package Odoo::Ops::Documents::AccountReconcile;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Documents::Reconcile;

use parent 'Odoo::Ops::Operation';


=head1 NAME

Odoo::Ops::Documents::AccountReconcile - reconcile journal items with Odoo's own reconcile()

=head1 SYNOPSIS

    oom-ops run account.reconcile --conf ops.conf --set lines=696,698
    oom-ops run account.reconcile --conf ops.conf --set lines=696,698 --check

=head1 DESCRIPTION

C<account.reconcile> plans one call of Odoo's C<reconcile()> on a list of journal items
(C<account.move.line> ids): an invoice's receivable item with a payment's, a bill with its
payment, an outstanding item with a statement line's counterpart. Odoo matches the items against
each other and makes the partial reconciles; when nothing is left open on any item it makes the
full reconcile.

The plan shows each item (its entry, account, partner and residual) and the outcome the residuals
point to: C<full> (they net to zero) or C<partial> with the amount left open and on which side; items in
different currencies say the outcome follows Odoo's rate and is read back. A plan holds the call, naming
the fact that stops it and using Odoo's words for it, when the items do not exist (C<unknown-line>), are
on different accounts (C<different-account>) or companies (C<different-company>), sit on an account
that does not allow reconciliation (C<not-reconcilable>), belong to an entry that is not posted
(C<not-posted>) or are already reconciled (C<already-reconciled>). Odoo is still the authority at apply;
what it refuses then it refuses in its own words.

Apply compares each item's residual with the plan's (a changed item is refused C<stale>), calls
C<reconcile>, and reads back: each item (C<reconciled>, C<residual>, C<matching_number>), the partial
reconciles made (id, the two items, amount, date), the full reconcile if one was made, and the
C<outcome> (C<full>, C<partial> or C<none>). The call is verified when at least one partial was made and
the outcome is the one the plan expected. Odoo's own answer to the call is not read (16 answers with
record sets, 18 with nothing).

C<matching_number> differs by series: on 16 it is the full reconcile's name (C<A1>) or the literal C<P> for any
partial; on 18 it is the full reconcile's id as text (C<5>) or C<P> and a number for each connected group of
partials. Read the partials and the full reconcile for what is matched with what.

Revert removes the partial reconciles this run made (by C<unlink> on them, which is what Odoo's
C<remove_move_reconcile> does to the items' own); a partial the items held before the run stays. A run that made
none is held C<irreversible>.

A write operation: plans only; C<apply> carries it out. Series: 16 and 18.

=cut

sub op_name ($class) { 'account.reconcile' }
sub summary ($class) { 'Plan reconciling journal items with Odoo\'s own reconcile(): the outcome, the partials made and the matching read back' }
sub pack    ($class) { 'account' }
sub params ($class) {
    {   lines => { type => 'list', required => 1, help => 'the journal items (account.move.line ids), comma-separated, such as 696,698' },
    };
}
sub buckets ($class) {
    [ { name => 'reconcile', meaning => 'the journal items are reconciled with each other through Odoo\'s reconcile(); the plan says the expected outcome' } ];
}
sub holds ($class) {
    [
        { name => 'unknown-line', meaning => 'no journal item has one of the ids' },
        { name => 'not-posted', meaning => 'an item belongs to an entry that is not posted' },
        { name => 'already-reconciled', meaning => 'an item is already reconciled' },
        { name => 'not-reconcilable', meaning => 'an item\'s account does not allow reconciliation' },
        { name => 'different-account', meaning => 'the items are on different accounts' },
        { name => 'different-company', meaning => 'the items belong to different companies' },
    ];
}
sub read_scope ($class) {
    {   'account.move.line' => [qw(read search_read)], 'account.account' => ['search_read'], 'account.partial.reconcile' => ['search_read'], 'account.full.reconcile' => ['search_read'],
    };
}
# the partial reconciles a revert removes are declared here, as the revert of this operation runs under this operation's scope
sub write_scope ($class) { { 'account.move.line' => ['reconcile'], 'account.partial.reconcile' => ['unlink'] } }

sub plan ($self) {
    my $p   = Odoo::Ops::Documents::Reconcile::ready($self);
    my $n   = Odoo::Ops::Documents::Reconcile::names($p);
    my $ids = Odoo::Ops::Documents::Reconcile::ids( $self, $self->param('lines') );
    @$ids = sort { $a <=> $b } @$ids;
    my ( $line, $acct ) = Odoo::Ops::Documents::Reconcile::read_lines( $self, $p, $n, $ids );
    my $plan = $self->new_plan( input_count => 1 );
    my $key  = $self->op_name . ':' . join( ',', @$ids );
    my $f    = $n->{f};
    my @problem;
    my @missing = grep { !$line->{$_} } @$ids;
    push @problem, [ 'unknown-line', 'no journal item has id ' . join( ', ', @missing ) ] if @missing;
    my @rows = map { $line->{$_} } grep { $line->{$_} } @$ids;
    my $id_of = sub ($v) { ref $v eq 'ARRAY' ? $v->[0] : $v };
    my $name_of = sub ($r) { "journal item $r->{id}" . ( ref $r->{ $f->{move} } eq 'ARRAY' ? " ($r->{ $f->{move} }[1])" : '' ) };
    my @unposted = grep { ( $_->{ $f->{state} } // '' ) ne 'posted' } @rows;
    push @problem, [ 'not-posted', join( '; ', map { $name_of->($_) . ': You can only reconcile posted entries. (the entry is ' . ( $_->{ $f->{state} } || 'not posted' ) . ')' } @unposted ) ] if @unposted;
    my @done = grep { $_->{ $f->{reconciled} } } @rows;
    push @problem, [ 'already-reconciled', join( '; ', map { $name_of->($_) } @done ) . ': You are trying to reconcile some entries that are already reconciled.' ] if @done;
    my @closed = grep { my $a = $acct->{ $id_of->( $_->{ $f->{account} } ) // 0 }; $a && !$a->{reconcile} && ( $a->{type} // '' ) !~ /\A(?:asset_cash|liability_credit_card)\z/ } @rows;
    push @problem, [ 'not-reconcilable', join( '; ', map { $name_of->($_) . ': Account ' . $_->{ $f->{account} }[1] . ' does not allow reconciliation. First change the configuration of this account to allow it.' } @closed ) ] if @closed;
    my %acc = map { ( $id_of->( $_->{ $f->{account} } ) // 0 ) => $_->{ $f->{account} } } @rows;
    if ( keys %acc > 1 ) {
        my @names = map { ref $acc{$_} eq 'ARRAY' ? $acc{$_}[1] : $_ } sort { $a <=> $b } keys %acc;
        push @problem, [ 'different-account', 'Entries are not from the same account: ' . join( ' != ', @names ) ];
    }
    my %co = map { ( $id_of->( $_->{ $f->{company} } ) // 0 ) => $_->{ $f->{company} } } @rows;
    if ( keys %co > 1 ) {
        my @names = map { ref $co{$_} eq 'ARRAY' ? $co{$_}[1] : $_ } sort { $a <=> $b } keys %co;
        push @problem, [ 'different-company', "Entries doesn't belong to the same company: " . join( ' != ', @names ) ];
    }
    if (@problem) {
        $plan->add( bucket => $problem[0][0], action => 'hold', key => $key,
            reason => join( "; ", map { $_->[1] } @problem ) );
        return $plan;
    }
    my $exp = Odoo::Ops::Documents::Reconcile::expected( \@rows, $n );
    $plan->note( Odoo::Ops::Documents::Reconcile::line_text( $n, $_ ) ) for @rows;
    $plan->note( 'expected outcome - ' . $exp->{words} );
    $plan->add(
        bucket => 'reconcile', action => 'custom', handler => $self->op_name, kind => 'reconcile', key => $key, model => $n->{model}{move_line},
        calls  => Odoo::Ops::Documents::Reconcile::reconcile_calls($n),
        vals   => { lines => $ids, names => $n, snapshot => Odoo::Ops::Documents::Reconcile::snapshot( $n, $line ), expected => $exp },
        line   => 'reconcile ' . scalar(@rows) . ' journal items (' . join( ', ', @$ids ) . '): ' . $exp->{words},
        reason => 'Odoo\'s reconcile() matches the journal items ' . join( ', ', @$ids ) . ' against each other',
    );
    return $plan;
}

sub apply_custom ($class, $client, $c) {
    Odoo::Error->throw( kind => 'usage', message => "$c->{handler} cannot apply kind '" . ( $c->{kind} // '' ) . "'" ) if ( $c->{kind} // '' ) ne 'reconcile';
    return Odoo::Ops::Documents::Reconcile->apply_reconcile( $client, $c );
}

sub undo_custom ($class, $entry) { return Odoo::Ops::Documents::Reconcile->undo_reconcile($entry) }

1;
