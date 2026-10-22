package Odoo::Ops::Documents::Reconcile;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Documents::Common;

=head1 NAME

Odoo::Ops::Documents::Reconcile - what account.reconcile, account.unreconcile and account.statement_undo share

=head1 DESCRIPTION

Not an operation: the plain functions behind the three. Odoo reconciles journal items
(C<account.move.line>) with C<reconcile()>, takes a reconciliation back with
C<remove_move_reconcile()>, and puts a bank statement line back to its liquidity and suspense
lines with C<action_undo_reconciliation()>. The three operations plan those calls with the facts
Odoo holds about the items (account, partner, residual, what each is matched with) and read the
result back; they add no rule of their own. Where a plan holds a call, the reason is a fact read
from the items, in Odoo's own words where Odoo words it.

Series: 16 and 18 (the account profile names the models and fields of each); any other series is
refused by name (C<series>) until it is probed.

=head2 ready($op)

The account profile for this server, or a refusal: C<series> for a series other than 16 and 18,
C<profile> when the profile does not match the server.

=cut

sub ready ($op) {
    my $series = $op->client->server_series;
    Odoo::Error->throw( kind => 'refused', code => 'series',
        message => $op->op_name . " is not probed on Odoo $series: the reconciliation operations are met on 16 and 18" )
        if $series != 16 && $series != 18;
    return Odoo::Ops::Documents::Common::ready($op);
}

=head2 names($p)

The physical models and fields a change carries, so an apply (which has a client and no profile) reads
and compares the same fields the plan did: C<< { model => { line, partial, full, ... }, f => { ... } } >>.

=cut

sub names ($p) {
    my %m = map { $_ => $p->model_name($_) } qw(move_line partial full);
    my %f;
    for my $lf (qw(account partner state reconciled residual residual_currency balance currency company matching full debits credits move)) { $f{$lf} = $p->field( move_line => $lf ) }
    $f{partial_debit}  = $p->field( partial => 'debit' );
    $f{partial_credit} = $p->field( partial => 'credit' );
    $f{partial_amount} = $p->field( partial => 'amount' );
    $f{partial_date}   = $p->field( partial => 'date' );
    $f{partial_full}   = $p->field( partial => 'full' );
    $f{full_name}      = $p->has_field( full => 'name' ) ? $p->field( full => 'name' ) : undef;
    return { model => \%m, f => \%f };
}

sub _line_fields ($n) { return [ 'id', map { $n->{f}{$_} } qw(move account partner state reconciled residual residual_currency balance currency company matching full debits credits) ] }

# a many2one as read: [id, label], or false
sub idof ($v) { return ref $v eq 'ARRAY' ? $v->[0] : ( defined $v && $v ne '' && $v ne '0' && !ref $v ? $v : undef ) }
sub labelof ($v) { return ref $v eq 'ARRAY' ? $v->[1] : undef }
sub numof ($v) { return defined $v && !ref $v && $v =~ /\A-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?\z/ ? 0 + $v : 0 }
sub money ($v) { my $s = sprintf '%.2f', numof($v); 1 while $s =~ s/^(-?\d+)(\d{3})/$1,$2/; return $s }
sub idlist ($v) { return ref $v eq 'ARRAY' ? [ grep { !ref } @$v ] : [] }
sub is_zero ($v) { return abs( numof($v) ) < 5e-7 }

=head2 ids($op, $raw)

The journal item or statement line ids a call names: whole numbers above 0, each once. Anything else is
C<usage>.

=cut

sub ids ($op, $raw, $what = 'lines') {
    my @in = ref $raw eq 'ARRAY' ? @$raw : ();
    Odoo::Error->throw( kind => 'usage', message => $op->op_name . ": $what is empty: give the ids, such as --set $what=12,13",
        fix => 'oom-ops describe ' . $op->op_name . ' lists the parameters' ) if !@in;
    my %seen;
    my @ids;
    for my $x (@in) {
        Odoo::Error->throw( kind => 'usage', message => $op->op_name . ": $what must be whole numbers above 0 (ids), got '" . ( $x // '' ) . "'",
            fix => 'oom-ops describe ' . $op->op_name . ' lists the parameters' ) if !defined $x || ref $x || $x !~ /\A[1-9]\d*\z/;
        push @ids, 0 + $x if !$seen{ 0 + $x }++;
    }
    return \@ids;
}

=head2 read_lines($op, $p, $n, \@ids)

The journal items among C<@ids> as read now, by id, plus the accounts they sit on (C<reconcile>,
C<code>, C<account_type>): C<< ( \%line_by_id, \%account_by_id ) >>. A missing id is absent from the hash.

=cut

sub read_lines ($op, $p, $n, $ids) {
    my $rows = $op->client->model( $n->{model}{move_line} )->search_read( [ [ 'id', 'in', $ids ] ], _line_fields($n), order => 'id' );
    my %line = map { $_->{id} => $_ } @$rows;
    my @acc  = grep { defined } map { idof( $_->{ $n->{f}{account} } ) } @$rows;
    my %acct;
    if (@acc) {
        my @f = ( 'id', 'code', $p->field( account => 'reconcile' ), $p->field( account => 'type' ) );
        my $a = $op->client->model( $p->model_name('account') )->search_read( [ [ 'id', 'in', [ keys %{ { map { $_ => 1 } @acc } } ] ] ], \@f );
        %acct = map { $_->{id} => { code => $_->{code}, reconcile => $_->{ $p->field( account => 'reconcile' ) } ? 1 : 0, type => $_->{ $p->field( account => 'type' ) } } } @$a;
    }
    return ( \%line, \%acct );
}

=head2 line_text($n, $row)

One item in words: C<< journal item 696 (INV/2026/00006): account 121000 Account Receivable, partner X, residual 100.00 >>.

=cut

sub line_text ($n, $r) {
    my $f = $n->{f};
    my $mv = labelof( $r->{ $f->{move} } );
    return "journal item $r->{id}" . ( defined $mv ? " ($mv)" : '' ) . ': account ' . ( labelof( $r->{ $f->{account} } ) // '-' )
        . ', partner ' . ( labelof( $r->{ $f->{partner} } ) // 'none' ) . ', residual ' . money( $r->{ $f->{residual} } );
}

=head2 expected(\@rows, $n)

What Odoo is expected to do with these items, from their residuals: C<< { kind => 'full' | 'partial' |
'unknown', left => N, side => 'debit' | 'credit', words } >>. The items reconcile against each other, so the
residuals (in the one currency the items share) net off; what does not net is left on the side that has more.
Items in different currencies are C<unknown>: Odoo's rate decides, and the apply reads the outcome.

=cut

sub expected ($rows, $n) {
    my $f = $n->{f};
    my %cur = map { ( idof( $_->{ $f->{currency} } ) // 0 ) => 1 } @$rows;
    return { kind => 'unknown', words => 'items in different currencies: the outcome follows the exchange rate Odoo uses, and is read back after apply' } if keys %cur > 1;
    # one currency: the residual in that currency (the company's own for an item in the company currency)
    my $field = $f->{residual_currency};
    my $sum = 0;
    $sum += numof( $_->{$field} ) for @$rows;
    return { kind => 'full', left => 0, words => 'full: the residuals net to zero, so every item is cleared' } if is_zero($sum);
    my $side = $sum > 0 ? 'debit' : 'credit';
    my $abs  = abs $sum;
    return { kind => 'partial', left => $abs + 0, side => $side, words => 'partial: ' . money($abs) . " is left open on the $side side" };
}

=head2 snapshot($n, \%line_by_id)

The residual and reconciled state of each item, as the plan saw it: apply compares them with the items as
they are when it runs, and refuses C<stale> when another hand changed one.

=cut

sub snapshot ($n, $lines) {
    my $f = $n->{f};
    return { map { $_ => { residual => numof( $lines->{$_}{ $f->{residual} } ), reconciled => $lines->{$_}{ $f->{reconciled} } ? 1 : 0 } } keys %$lines };
}

sub stale ($class, $client, $n, $ids, $snap, $what) {
    my $f = $n->{f};
    my $rows = $client->model( $n->{model}{move_line} )->read( $ids, [ 'id', $f->{residual}, $f->{reconciled} ] );
    my %now = map { $_->{id} => $_ } @$rows;
    my @diff;
    for my $id (@$ids) {
        my $r = $now{$id};
        if ( !$r ) { push @diff, "journal item $id is gone"; next }
        my $s = $snap->{$id} or next;
        my $res = numof( $r->{ $f->{residual} } );
        push @diff, "journal item $id: residual " . money( $s->{residual} ) . ' -> ' . money($res) if abs( $res - $s->{residual} ) > 5e-7;
        push @diff, "journal item $id: reconciled " . ( $s->{reconciled} ? 'yes' : 'no' ) . ' -> ' . ( $r->{ $f->{reconciled} } ? 'yes' : 'no' ) if ( $r->{ $f->{reconciled} } ? 1 : 0 ) != $s->{reconciled};
    }
    Odoo::Error->throw( kind => 'refused', code => 'stale', message => "$what: " . join( '; ', @diff ) . ' since the plan was made',
        fix => 'plan it again: oom-ops run <operation> with the same lines' ) if @diff;
    return;
}

=head2 lines_after($client, $n, \@ids)

The items as they read now, for the answer: C<< [ { id, reconciled, residual, matching_number, full_reconcile_id } ] >>.

=cut

sub lines_after ($client, $n, $ids) {
    my $f = $n->{f};
    my $rows = $client->model( $n->{model}{move_line} )->read( $ids, [ 'id', $f->{reconciled}, $f->{residual}, $f->{matching}, $f->{full} ] );
    return [ map { {
        id => $_->{id}, reconciled => $_->{ $f->{reconciled} } ? JSON::PP::true : JSON::PP::false, residual => numof( $_->{ $f->{residual} } ),
        matching_number => ( $_->{ $f->{matching} } ? "$_->{ $f->{matching} }" : undef ), full_reconcile_id => idof( $_->{ $f->{full} } ),
    } } sort { $a->{id} <=> $b->{id} } @$rows ];
}

=head2 partials_of($client, $n, \@ids)

The partial reconciles that touch these items now, ordered by id: C<< { id, debit, credit, amount, date, full_reconcile_id } >>.

=cut

sub partials_of ($client, $n, $ids, %o) {
    my $f = $n->{f};
    my @dom = ( '|', [ $f->{partial_debit}, 'in', $ids ], [ $f->{partial_credit}, 'in', $ids ] );
    unshift @dom, '&', [ 'id', '>', $o{after} ] if defined $o{after};
    my $dom = \@dom;
    my $rows = $client->model( $n->{model}{partial} )->search_read( $dom, [ 'id', @$f{qw(partial_debit partial_credit partial_amount partial_date partial_full)} ], order => 'id' );
    return [ map { {
        id => $_->{id}, debit => idof( $_->{ $f->{partial_debit} } ), credit => idof( $_->{ $f->{partial_credit} } ),
        amount => numof( $_->{ $f->{partial_amount} } ), date => $_->{ $f->{partial_date} } || undef, full_reconcile_id => idof( $_->{ $f->{partial_full} } ),
    } } @$rows ];
}

sub max_partial ($client, $n) {
    my $r = $client->model( $n->{model}{partial} )->search_read( [], ['id'], order => 'id desc', limit => 1 );
    return @$r ? $r->[0]{id} : 0;
}

sub _full_rows ($client, $n, $ids) {
    return [] if !@$ids;
    my $name = $n->{f}{full_name};
    my $rows = $client->model( $n->{model}{full} )->search_read( [ [ 'id', 'in', $ids ] ], [ 'id', ( $name ? ($name) : () ) ] );
    return [ map { { id => $_->{id}, ( $name && $_->{$name} ? ( name => $_->{$name} ) : () ) } } sort { $a->{id} <=> $b->{id} } @$rows ];
}

=head2 apply_reconcile($class, $client, $change)

Carries out a C<reconcile> change: compares the items with the plan's snapshot (C<stale>), notes the newest
partial reconcile, calls C<reconcile> on the items, and reads back each item (reconciled, residual,
C<matching_number>), the partials made (id, the two items, amount, date) and the full reconcile, if any.
Odoo's answer to the call is not read: Odoo 16 answers with record sets and 18 with nothing, and the items are
the evidence. The change is verified when at least one partial was made and the items read as the plan expected
(every item cleared for a full outcome); otherwise C<after> is empty and C<returned> says what was found.

=cut

sub apply_reconcile ($class, $client, $c) {
    my $v = $c->{vals};
    my $n = $v->{names};
    my $ids = $v->{lines};
    $class->stale( $client, $n, $ids, $v->{snapshot}, 'account.reconcile' );
    my $max = max_partial( $client, $n );
    $client->execute_kw( $n->{model}{move_line}, 'reconcile', [$ids] );
    my $lines    = lines_after( $client, $n, $ids );
    my $partials = partials_of( $client, $n, $ids, after => $max );
    my %full     = map { $_->{full_reconcile_id} => 1 } grep { defined $_->{full_reconcile_id} } @$lines, @$partials;
    my $fulls    = _full_rows( $client, $n, [ sort { $a <=> $b } keys %full ] );
    my $open     = [ grep { !$_->{reconciled} } @$lines ];
    my $left     = 0;
    $left += $_->{residual} for @$lines;
    my $outcome = !@$partials ? 'none' : @$fulls ? 'full' : 'partial';
    my $exp = $v->{expected} // {};
    my $matches = !@$partials ? 0
        : ( $exp->{kind} // '' ) eq 'full'    ? ( $outcome eq 'full' ? 1 : 0 )
        : ( $exp->{kind} // '' ) eq 'partial' ? ( $outcome eq 'partial' ? 1 : 0 )
        : 1;
    my %ret = (
        outcome => $outcome, lines => $lines, partials => $partials, full_reconcile => $fulls,
        residual_left => is_zero($left) ? 0 : abs( $left + 0 ),
    );
    return { id => undef, returned => \%ret, after => $matches ? { outcome => $outcome, partials => [ map { $_->{id} } @$partials ] } : undef };
}

=head2 undo_reconcile($class, $entry)

What a revert does with a done C<reconcile> entry: removes the partial reconciles that run made (and no other
that the items hold), by C<unlink> on them, which is what C<remove_move_reconcile> does to the items' own. Held
C<irreversible> when the run made none.

=cut

sub undo_reconcile ($class, $entry) {
    return ( undef, "$entry->{handler} cannot undo kind '" . ( $entry->{kind} // '' ) . "'" ) if ( $entry->{kind} // '' ) ne 'reconcile';
    my $ret = ref $entry->{returned} eq 'HASH' ? $entry->{returned} : {};
    my @made = map { $_->{id} } @{ $ret->{partials} // [] };
    return ( undef, 'the reconcile made no partial reconcile, so there is nothing to take back' ) if !@made;
    my $v = $entry->{vals};
    my $n = $v->{names};
    return {
        action => 'custom', handler => 'account.unreconcile', kind => 'unreconcile', bucket => 'undo-reconcile',
        model => $n->{model}{move_line}, key => 'undo:' . $n->{model}{move_line} . ' ' . join( ',', @{ $v->{lines} } ),
        calls => unreconcile_calls($n),
        vals  => { via => 'partials', lines => $v->{lines}, partials => \@made, names => $n, snapshot => {} },
        line  => 'take back the reconciliation of journal item' . ( @{ $v->{lines} } == 1 ? '' : 's' ) . ' ' . join( ', ', @{ $v->{lines} } )
            . ': remove partial reconcile' . ( @made == 1 ? '' : 's' ) . ' ' . join( ', ', @made ),
        reason => 'the partial reconciles the run made (' . join( ', ', @made ) . ') are removed, as remove_move_reconcile removes them',
    };
}

=head2 reconcile_calls($n) / unreconcile_calls($n)

The calls a change declares: an apply makes only those.

=cut

sub reconcile_calls ($n) {
    my ( $l, $p, $fu ) = @{ $n->{model} }{qw(move_line partial full)};
    return [ [ $l, 'read' ], [ $p, 'search_read' ], [ $l, 'reconcile' ], [ $fu, 'search_read' ] ];
}

sub unreconcile_calls ($n) {
    my ( $l, $p, $fu ) = @{ $n->{model} }{qw(move_line partial full)};
    return [ [ $l, 'read' ], [ $p, 'search_read' ], [ $l, 'remove_move_reconcile' ], [ $p, 'unlink' ], [ $fu, 'search_read' ] ];
}

=head2 apply_unreconcile($class, $client, $change)

Carries out an C<unreconcile> change: refuses C<stale> when the partials it names are not the ones the items hold
(or, for a revert, are gone), calls C<remove_move_reconcile> on the items (C<via lines>) or C<unlink> on the partials
(C<via partials>), then reads back that the partials are gone and the items as they read now, with the full
reconciles that were dissolved.

=cut

sub apply_unreconcile ($class, $client, $c) {
    my $v   = $c->{vals};
    my $n   = $v->{names};
    my @pids = @{ $v->{partials} };
    my $f   = $n->{f};
    my $now = $client->model( $n->{model}{partial} )->search_read( [ [ 'id', 'in', \@pids ] ], [ 'id', $f->{partial_debit}, $f->{partial_credit}, $f->{partial_full} ], order => 'id' );
    my @gone = grep { my $id = $_; !grep { $_->{id} == $id } @$now } @pids;
    Odoo::Error->throw( kind => 'refused', code => 'stale', message => 'account.unreconcile: partial reconcile' . ( @gone == 1 ? ' ' : 's ' ) . join( ', ', @gone ) . ' no longer exist(s) since the plan was made',
        fix => 'plan it again: oom-ops run account.unreconcile with the same lines' ) if @gone;
    my @involved = sort { $a <=> $b } keys %{ { map { ( $_ => 1 ) } grep { defined } map { ( idof( $_->{ $f->{partial_debit} } ), idof( $_->{ $f->{partial_credit} } ) ) } @$now } };
    my %full = map { $_ => 1 } grep { defined } map { idof( $_->{ $f->{partial_full} } ) } @$now;
    if ( ( $v->{via} // '' ) eq 'lines' ) {
        $client->execute_kw( $n->{model}{move_line}, 'remove_move_reconcile', [ $v->{lines} ] );
    }
    else {
        $client->execute_kw( $n->{model}{partial}, 'unlink', [ \@pids ] );
    }
    my $left = $client->model( $n->{model}{partial} )->search_read( [ [ 'id', 'in', \@pids ] ], ['id'] );
    my $lines = lines_after( $client, $n, \@involved );
    my $fulls_left = @{ _full_rows( $client, $n, [ sort { $a <=> $b } keys %full ] ) };
    my %ret = (
        removed => [ grep { my $id = $_; !grep { $_->{id} == $id } @$left } @pids ], not_removed => [ map { $_->{id} } @$left ],
        full_reconcile_dissolved => [ sort { $a <=> $b } keys %full ], lines => $lines,
    );
    my $ok = !@$left && !$fulls_left;
    return { id => undef, returned => \%ret, after => $ok ? { removed => \@pids } : undef };
}

1;
