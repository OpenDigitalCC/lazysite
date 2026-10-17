package Odoo::Ops::Documents::Common;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Error;
use Odoo::Ops;

=head1 NAME

Odoo::Ops::Documents::Common - what the state operations of the sale, purchase and account packs share

=head1 DESCRIPTION

Not an operation: the plain functions behind C<sale.confirm>,
C<sale.cancel>, C<purchase.confirm>, C<purchase.cancel>, C<account.post>,
C<account.cancel> and C<account.draft>. A state is changed through Odoo's
own action, never written: each operation plans one C<custom> change of
kind C<state> whose steps are Odoo's methods, read from the pack's profile
(C<actions> for the names, C<states> for what each action works from and
what counts as done), so the code here knows no series and no model.

An operation class supplies C<spec>:

    {   pack => 'sale', model => 'order', param => 'order', verb => 'confirm',
        uses => [qw(confirm cancel draft)],     # the actions its apply or its undo may call
        draft => 1,                             # takes the draft parameter (cancel, then draft)
        hold_for => { posted => 'posted' },     # a state that holds under its own name
        numbered => 1,                          # Odoo assigns a number the apply reads back
        undo => {                               # the steps that take a done change back, by the steps it ran
            confirm => [qw(cancel draft)],      #   a list of verbs,
            draft   => { cancel => ['cancel'] },#   or by the state the run started from,
            'cancel,draft' => 'why not',        #   or the reason there is none
        },
    }

and calls L</plan_state>. The apply (L</apply_state>) and the undo
(L</undo_state>) work from what the plan put in the change, so a journal
reverts the same way on every series.

=head2 ready($op)

The pack's profile for this server, or a refusal: a series with no profile
of its own is refused by name (C<series>), as the mailing pack does, and a
profile that does not match the live C<fields_get> is C<profile>.

=cut

sub ready ($op) {
    my $series = $op->client->server_series;
    my $p      = eval { $op->profile };
    Odoo::Error->throw( kind => 'refused', code => 'series',
        message => $op->op_name . " is not probed on Odoo $series: the " . $op->pack . ' pack has no profile for it (profiles/' . $op->pack . "/$series.yaml), and a series is a profile and a probe away (docs/OPS.md)" )
        if !$p || $p->series != $series;
    my $v = $p->validate( $op->client );
    Odoo::Error->throw( kind => 'refused', code => 'profile',
        message => 'the ' . $op->pack . ' profile does not match this server: ' . join( '; ', @{ $v->{missing} } ) )
        if !$v->{ok};
    return $p;
}

=head2 scope($op, $phase, $scope)

Expands C<&action> entries of a declared scope through the profile.

=cut

sub scope ($op, $phase, $scope) {
    my $p = $op->profile;
    return { map { my $m = $_; $m => [ sort map { /^&(.+)\z/ ? $p->action($1) : $_ } @{ $scope->{$m} } ] } keys %$scope };
}

=head2 scope_decl($spec)

The C<read_scope> and C<write_scope> an operation of this spec declares:
read and search on the model, and the actions in C<uses>.

=cut

sub read_scope  ($spec) { return { $spec->{model} => [qw(read search_read)] } }
sub write_scope ($spec) { return { $spec->{model} => [ 'read', map { "&$_" } @{ $spec->{uses} } ] } }

=head2 plan_state($op, $spec)

The plan: one change in bucket C<transition> (a C<custom> change carrying the
steps) and a C<line> the plan summary prints (C<sale.order 135 (S00134): draft -E<gt> sale>), with the same facts in C<transition>, or one hold: C<already> (the record is in a state the operation
ends in), C<state> (Odoo's action does not work from this state; the
reason names the state and what gets there), C<ambiguous> (C<name=> matches
more than one record), C<unknown-E<lt>modelE<gt>> (no such record), or the
spec's own C<hold_for> bucket.

=cut

sub plan_state ($op, $spec) {
    my $p     = ready($op);
    my $lm    = $spec->{model};
    my $model = $p->model_name($lm);
    my $f     = sub ($lf) { $p->has_field( $lm, $lf ) ? $p->field( $lm, $lf ) : undef };
    my $verb  = $spec->{verb};
    my $rule  = $p->states($verb);
    my $plan  = $op->new_plan( input_count => 1 );
    my $ref   = $op->param( $spec->{param} );
    my $key   = $op->op_name . ":$model $ref";

    my @want = grep { defined } map { $f->($_) } qw(name state locked);
    my $rows = _find( $op, $spec, $model, $ref, $f->('name'), \@want );
    if ( !@$rows ) {
        $plan->add( bucket => "unknown-$model", action => 'hold', key => $key,
            reason => $op->op_name . ": no $model matches '$ref'" );
        return $plan;
    }
    if ( @$rows > 1 ) {
        $plan->add( bucket => 'ambiguous', action => 'hold', key => $key,
            reason => "$model '$ref' matches " . scalar(@$rows) . ' records (' . join( ', ', map { $_->{id} } @$rows ) . '); give the id' );
        return $plan;
    }
    my $row    = $rows->[0];
    my $id     = $row->{id};
    my $sf     = $f->('state');
    my $state  = $row->{$sf};
    my $name   = $f->('name') ? _text( $row->{ $f->('name') } ) : '';
    my $label  = "$model $id" . ( length $name && $name ne '/' ? " ($name)" : '' );
    my $locked = $f->('locked') && $row->{ $f->('locked') } ? 1 : 0;
    $key = $op->op_name . ":$model $id";
    my %at = ( key => $key, id => $id, model => $model );

    my $draft_rule = $spec->{draft} ? $p->states('draft') : undef;
    my $want_draft = $spec->{draft} && $op->param('draft');
    my @to         = @{ $rule->{to} };
    my @steps;

    if ($want_draft) {
        if ( grep { $_ eq $state } @{ $draft_rule->{to} } ) {
            $plan->add( bucket => 'already', action => 'hold', %at, reason => "$label is already in state $state" );
            return $plan;
        }
        @steps = ( _step( $p, 'draft', $draft_rule ) ) if grep { $_ eq $state } @to;    # cancelled: only the way back is left
    }
    elsif ( grep { $_ eq $state } @to ) {
        $plan->add( bucket => 'already', action => 'hold', %at, reason => "$label is already in state $state" );
        return $plan;
    }

    if ( !@steps ) {
        if ( !grep { $_ eq $state } @{ $rule->{from} } ) {
            my $bucket = $spec->{hold_for}{$state} // 'state';
            my $hint   = $rule->{hints}{$state} // '';
            $hint =~ s/\{id\}/$id/g;
            $plan->add( bucket => $bucket, action => 'hold', %at,
                reason => "$label is in state $state; " . $op->op_name . ' works from ' . join( ', ', @{ $rule->{from} } )
                    . ( length $hint ? ": $hint" : '' ) );
            return $plan;
        }
        @steps = ( _step( $p, $verb, $rule ) );
        push @steps, _step( $p, 'draft', $draft_rule ) if $want_draft;
    }
    if ( $locked && grep { $p->states( $_->{verb} )->{refuses_locked} } @steps ) {
        $plan->add( bucket => 'state', action => 'hold', %at,
            reason => "$label is locked and Odoo refuses " . join( ' then ', map { $_->{method} } @steps ) . ' on a locked record: unlock it in Odoo first (OOM has no operation for it)' );
        return $plan;
    }

    my @final = @{ $p->states( $steps[-1]{verb} )->{to} };
    my $undo  = _undo( $p, $spec, $state, [ map { $_->{verb} } @steps ] );
    $plan->add(
        bucket => 'transition', action => 'custom', handler => $op->op_name, kind => 'state', %at,
        before => { $sf => $state },
        vals   => { steps => \@steps, state_field => $sf, to => \@final, name_field => $f->('name'), undo => $undo },
        transition => { from => $state, to => $final[0], model => $model, id => $id, name => $name },
        line   => "$label: $state -> $final[0]",
        reason => "$label goes from $state to $final[0] through " . join( ' then ', map { $_->{method} } @steps ),
    );
    $plan->note('the number Odoo assigns is read back after apply') if $spec->{numbered};
    return $plan;
}

sub _step ($p, $verb, $rule) {
    return { verb => $verb, method => $p->action($verb), ( $rule->{context} ? ( context => { %{ $rule->{context} } } ) : () ) };
}

# the steps that take this change back: { steps, to } or { why }
sub _undo ($p, $spec, $before, $ran) {
    my $u = ( $spec->{undo} // {} )->{ join ',', @$ran };
    $u = $u->{$before} if ref $u eq 'HASH';
    return { why => "$spec->{verb} has no recorded undo for a run that started from $before" } if !defined $u;
    return { why => $u } if !ref $u;
    my @steps = map { _step( $p, $_, $p->states($_) ) } @$u;
    return { steps => \@steps, to => [ @{ $p->states( $u->[-1] )->{to} } ] };
}

sub _text ($v) { defined $v && !ref $v ? "$v" : '' }

# the record a parameter names: an id, or name=<text> (an exact match)
sub _find ($op, $spec, $model, $ref, $name_field, $want) {
    my @domain;
    if    ( $ref =~ /^\s*(\d+)\s*\z/ ) { @domain = ( [ 'id', '=', 0 + $1 ] ) }
    elsif ( $ref =~ /^\s*name=(.+?)\s*\z/ && $name_field ) { @domain = ( [ $name_field, '=', $1 ] ) }
    else {
        Odoo::Error->throw( kind => 'usage', message => $op->op_name . ": '$ref' is neither an id nor name=<text>",
            fix => "pass --set $spec->{param}=12 or --set $spec->{param}=name=<number>" );
    }
    return $op->client->model($model)->search_read( \@domain, [ 'id', @$want ], limit => 5 );
}

=head2 apply_state($class, $client, $change)

Carries a C<state> change out: each step's method on the record (the
step's context beside it), then reads the state back. The change is
verified only when the state is one the operation ends in; a purchase
order that went to C<to approve> (double validation) or a move that did not
post is reported unverified, with the state it reached in C<returned>.

=cut

sub apply_state ($class, $client, $c) {
    Odoo::Error->throw( kind => 'usage', message => "$c->{handler} cannot apply kind '" . ( $c->{kind} // '' ) . "'" )
        if ( $c->{kind} // '' ) ne 'state';
    my $v = $c->{vals};
    my @ran;
    for my $s ( @{ $v->{steps} } ) {
        $client->execute_kw( $c->{model}, $s->{method}, [ [ $c->{id} ] ], $s->{context} ? { context => $s->{context} } : {} );
        push @ran, $s->{method};
    }
    my @read = ( $v->{state_field}, ( $v->{name_field} ? ( $v->{name_field} ) : () ) );
    my $row  = $client->model( $c->{model} )->read( [ $c->{id} ], \@read )->[0] or return { id => $c->{id}, after => undef };
    my $state = $row->{ $v->{state_field} };
    my %ret   = ( state => $state, ran => \@ran, ( $v->{name_field} ? ( name => _text( $row->{ $v->{name_field} } ) ) : () ) );
    my $ok    = grep { $_ eq $state } @{ $v->{to} };
    return { id => $c->{id}, returned => \%ret, after => $ok ? { $v->{state_field} => $state } : undef };
}

=head2 undo_state($class, $entry)

What a revert does with a done C<state> entry: a C<custom> change of the
same handler that takes the record back as far as Odoo's actions can, from
the C<undo> the plan recorded, or C<(undef, $reason)> which the revert
holds as C<irreversible>.

=cut

sub undo_state ($class, $entry) {
    return ( undef, "$entry->{handler} cannot undo kind '" . ( $entry->{kind} // '' ) . "'" ) if ( $entry->{kind} // '' ) ne 'state';
    my $v   = $entry->{vals};
    my $u   = $v->{undo} // {};
    return ( undef, $u->{why} // 'no undo was recorded for this change' ) if !$u->{steps};
    my $sf  = $v->{state_field};
    my $was = $entry->{before}{$sf} // '';
    # a custom change journals what apply_state returned, not an after-image
    my $now = ref $entry->{returned} eq 'HASH' ? $entry->{returned}{state} : undef;
    return ( undef, 'the change was not verified, so there is no state to take back from' )
        if !defined $now || !grep { $_ eq $now } @{ $v->{to} };
    return {
        action => 'custom', handler => $entry->{handler}, kind => 'state', bucket => 'undo-state',
        model => $entry->{model}, id => $entry->{id}, key => "undo:$entry->{model} $entry->{id}",
        before => { $sf => $now },
        vals   => { %$v, steps => $u->{steps}, to => $u->{to}, undo => { why => 'this is the undo; run the operation again to repeat it' } },
        line   => "$entry->{model} $entry->{id}: $now -> $u->{to}[0]",
        reason => "$entry->{model} $entry->{id} goes from $now back through " . join( ' then ', map { $_->{method} } @{ $u->{steps} } )
            . " (it was $was before the run)",
    };
}

1;
