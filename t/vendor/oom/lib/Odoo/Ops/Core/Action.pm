package Odoo::Ops::Core::Action;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();
use Scalar::Util qw(blessed);

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Core::ActionCommon;
use Odoo::Ops::Modules;

use parent 'Odoo::Ops::Operation';

my $AC = 'Odoo::Ops::Core::ActionCommon';

=head1 NAME

Odoo::Ops::Core::Action - call one of Odoo's own methods on records of any model

=head1 SYNOPSIS

    oom-ops run core.action --conf ops.conf --set model=hr.leave --set record=17 --set method=action_approve
    oom-ops run core.action --conf ops.conf --set model=hr.payslip --set records=4,5 --set method=compute_sheet
    oom-ops describe core.action --set model=hr.leave

=head1 DESCRIPTION

A state in Odoo is changed by the method behind its button, never by a write.
C<core.action> is the one operation for all of them: it calls a public method of
a model on the records named, and says what Odoo answered and what the record
now reads. Which methods a model has is data, in its behaviour file
(C<actions:>, see L<Odoo::Ops::Behaviour>); the caller decides which to call and
when.

The method must be listed for the model, or the plan is refused with
C<refused/unlisted-action> (the fix names the behaviour file to add it to). A
method whose name starts with C<_> is always refused. A listed method whose
module is not installed here is refused C<refused/not-applicable>.

One change is planned per record, bucket C<call>. The plan shows the record, the
method and the record's state as read now; it does not say what the method will
do (C<from> and C<to> in the behaviour file are for C<describe>, not for the
plan). Apply calls the method on the record with the context and arguments
given, reads the record back and reports the state before and after as a
fact, with Odoo's answer: nothing, C<true>, or a window (C<Odoo answered with a
window: hr.holidays.cancel.leave (form)>). A window means Odoo wants a wizard or
shows a record; OOM does not follow it, and when the behaviour file names the
wizard for the method the line says to use C<core.wizard>. If Odoo refuses, the
change fails with Odoo's words and C<resume> works as for any failed change.

A listed entry with C<on: model> is an C<@api.model> method: Odoo calls it on the
model, not on records. C<record> and C<records> are refused C<usage> (it takes
none); C<args> is a JSON list checked against the entry's C<params> (count and
type, a mismatch is C<usage> naming the parameter). The plan is one change that
shows the model, the method and the arguments, and does not predict the result.
Apply calls C<execute_kw(model, method, args, {context})> with no ids and reports
Odoo's answer as for a record method; a dict or list answer is kept whole in
C<returned.value>. A model-level method has no record to read before and after: when
the entry lists C<creates:> the C<made:> lines are the read-back, otherwise the line
says C<nothing read back: a model-level method has no record>. C<revert> plans the
entry's C<undo> (a model-level entry, the same arguments) or is held
C<irreversible>, naming what was made.

What the method made is named. When the behaviour entry lists C<creates:> (the
models the method is known to make records in), apply reads the highest id of each
before the call and, after it, the records above it whose C<create_uid> is the
session's uid: they are reported as made by this login in that model while the
action ran, in C<created> (C<< { model, id, name, state } >>) of the change's
C<returned> block, of the result's C<custom> entry and of the journal. A C<link>
field of the record acted on is read back beside them (C<links>; a record it names
that the search did not find is "linked, not made in this call"). The plan line ends
C<creates: M> or C<creates: not listed>. See L<Odoo::Ops::Core::ActionCommon/creates_after>.

C<revert> of a change: when the behaviour file names an C<undo> action for the
method, the revert plans that action; otherwise it is held C<irreversible>,
naming the method.

A write operation: plans only; C<apply> carries it out.

=cut

sub op_name ($class) { 'core.action' }
sub summary ($class) { 'Plan calling a listed Odoo method (a button\'s action) on records of any model; the behaviour file lists the methods' }
sub pack    ($class) { undef }
sub params ($class) {
    {   model   => { type => 'str',  required => 1, help => 'physical model, e.g. hr.leave' },
        record  => { type => 'str',  help => 'one record: an id, or field=value such as name=X (not for an on: model entry)' },
        records => { type => 'list', help => 'comma-separated record ids (instead of record)' },
        method  => { type => 'str',  required => 1, help => 'a public method the model\'s behaviour file lists under actions (oom-ops describe core.action --set model=M)' },
        context => { type => 'json', help => 'the context of the call, a JSON object (merged over the config\'s)' },
        args    => { type => 'json', help => 'the arguments after the ids: a JSON list (positional) or object (keyword); for an on: model entry the whole argument list, checked against the entry\'s params' },
    };
}
sub buckets ($class) {
    [ { name => 'call', meaning => 'the method is called on the record; apply reads it back and reports the state before and after' } ];
}
sub holds ($class) {
    [ { name => 'unknown-record', meaning => 'no record has that id, or matches that field=value' } ];
}
sub read_scope  ($class) { {} }    # built per run from the model
sub write_scope ($class) { {} }
sub writes      ($class) { 1 }

sub scope_for ( $self, $phase ) {
    my %s = ( 'ir.module.module' => { search_read => 1 } );
    my $model = $self->param('model');
    if ( defined $model ) {
        $s{$model}{$_} = 1 for qw(search_read read);
        $s{$model}{ $self->param('method') } = 1 if $phase eq 'apply' && defined $self->param('method');
    }
    if ( $phase eq 'apply' && defined $model && defined $self->param('method') && $self->ctx ) {
        my $entry = eval { $self->ctx->behaviour($model)->action( $self->param('method') ) };
        my %c = $AC->creates_scope($entry);
        for my $m ( keys %c ) { $s{$m}{$_} = 1 for @{ $c{$m} } }
    }
    if ( $phase eq 'apply' ) {
        my $u = $AC->undo_scope;
        for my $m ( keys %$u ) { $s{$m}{$_} = 1 for 'read', @{ $u->{$m} } }
    }
    return { map { $_ => [ sort keys %{ $s{$_} } ] } keys %s };
}

sub _call_args ( $me, $args ) {
    return ( [], {} ) if !defined $args;
    return ( $args, {} ) if ref $args eq 'ARRAY';
    return ( [], $args ) if ref $args eq 'HASH';
    Odoo::Error->throw( kind => 'usage', message => "$me: args must be a JSON list or object" );
}

sub plan ($self) {
    my $me     = $self->op_name;
    my $model  = $self->param('model');
    my $method = $self->param('method');
    Odoo::Error->throw( kind => 'usage', message => "$me: model must be a physical model name (with a dot), got '$model'" ) if $model !~ /\./;
    Odoo::Error->throw( kind => 'usage', message => "$me: method must be a method name, got '$method'" ) if $method !~ /\A\w+\z/;
    my $ctx_in = $self->param('context') // {};
    Odoo::Error->throw( kind => 'usage', message => "$me: context must be a JSON object" ) if ref $ctx_in ne 'HASH';
    my ( $args, $kwargs ) = _call_args( $me, $self->param('args') );

    my $beh = $self->ctx->behaviour($model);
    # a model of a module this server lacks is not applicable here, before any question of what is listed
    if ( my $why = Odoo::Ops::Modules->missing( $self->ctx, $beh->module ) ) { Odoo::Ops::Modules->refuse_model( $me, $model, $why ) }
    $AC->refuse_unlisted( $self->ctx, $model, 'action', "$me: $model $method is private (a method that starts with _ is never called)" )
        if $method =~ /\A_/;
    my $entry = $beh->action($method)
        or $AC->refuse_unlisted( $self->ctx, $model, 'action',
            "$me: $model $method is not listed for $model in its behaviour file" . ( $beh->known ? '' : ' (there is none)' ) );
    $AC->refuse_module( $self->ctx, $me, "$model $method", $entry->{module} // $beh->module );

    if ( $beh->on_model($entry) ) {
        Odoo::Error->throw( kind => 'usage', message => "$me: $model $method is a model-level method: it takes no records, so record and records are not given",
            fix => "pass the method's arguments as --set args='[...]' (oom-ops describe core.action --set model=$model lists them)" )
            if ( defined $self->param('record') && length $self->param('record') ) || @{ $self->param('records') // [] };
        my @params = $beh->params($entry);
        my @pass   = $AC->check_args( $me, "$model $method", \@params, $self->param('args') );
        my $m      = eval { $self->client->model($model) };
        eval { $m->fields } || Odoo::Ops::Modules->absent_model( $self->ctx, $me, $model, $@ );
        my $creates = $AC->creates_specs( $self->ctx, $entry );
        my $plan    = $self->new_plan( input_count => 1 );
        $plan->note("$model $method: $entry->{note}") if length( $entry->{note} // '' );
        my $shown = $AC->args_text( \@params, \@pass );
        $plan->add(
            bucket => 'call', action => 'custom', handler => $me, kind => 'action', key => "$model:$method", model => $model,
            calls => [ [ $model, $method ], $AC->creates_calls( $creates, $model ) ],
            vals => {
                on => 'model', method => $method, args => \@pass, kwargs => {}, context => $ctx_in, params => [ map { $_->{name} } @params ],
                ( defined $entry->{undo} ? ( undo => $entry->{undo} ) : () ),
                ( @$creates ? ( creates => $creates ) : () ),
            },
            line   => "$model: $method(" . $shown . '); no records; ' . $AC->creates_words($creates),
            reason => "$model: Odoo's model-level $method is called" . ( length $shown ? " with $shown" : ' with no arguments' ),
        );
        return $plan;
    }

    my $m      = eval { $self->client->model($model) };
    my $fields = eval { $m->fields } || Odoo::Ops::Modules->absent_model( $self->ctx, $me, $model, $@ );
    my @state = grep { $fields->{$_} } $beh->state_fields;
    my @read  = ( 'id', 'display_name', @state );

    my $creates = $AC->creates_specs( $self->ctx, $entry );
    my ( $want, $by_id ) = $AC->resolve_records( $self->client, $me, $model, $fields, $self->param('record'), $self->param('records'), \@read );
    my $plan = $self->new_plan( input_count => scalar @$want );
    $plan->note("$model $method: $entry->{note}") if length( $entry->{note} // '' );
    for my $w (@$want) {
        my ( $id, $label ) = @$w;
        my $key = "$model:" . ( $id // $label );
        my $row = defined $id ? $by_id->{$id} : undef;
        if ( !$row ) {
            $plan->add( bucket => 'unknown-record', action => 'hold', key => $key,
                reason => "$me: no $model " . ( defined $id ? "has id $id" : "matches $label" ) );
            next;
        }
        my $what = "$model $id" . $AC->name_of($row);
        my %before = map { $_ => $row->{$_} } @state;
        my $sline = @state ? '; ' . join( ', ', map { "$_ " . $AC->state_text( $row->{$_} ) } @state ) : '';
        my ($wiz) = defined $entry->{wizard} ? grep { $_->{model} eq $entry->{wizard} } @{ $beh->wizards } : ();
        $plan->add(
            bucket => 'call', action => 'custom', handler => $me, kind => 'action', key => $key, id => $id, model => $model,
            calls => [ [ $model, $method ], [ $model, 'read' ], $AC->creates_calls( $creates, $model ) ],
            ( @state ? ( before => \%before ) : () ),
            vals => {
                method => $method, args => $args, kwargs => $kwargs, context => $ctx_in, state_fields => \@state,
                name => ( $row->{display_name} // '' ),
                ( defined $entry->{undo}   ? ( undo   => $entry->{undo} ) : () ),
                ( @$creates ? ( creates => $creates ) : () ),
                ( defined $entry->{wizard} ? ( wizard => $entry->{wizard}, ( $wiz ? ( wizard_method => $wiz->{method} ) : () ) ) : () ),
            },
            line   => "$what: $method$sline; " . $AC->creates_words($creates),
            reason => "$what: Odoo's $method is called" . ( @state ? '; ' . join( ', ', map { "$_ reads " . $AC->state_text( $row->{$_} ) } @state ) . ' now' : '' ),
        );
    }
    return $plan;
}

# the state fields of a read row, plain
sub _states ( $row, $fields ) { return { map { $_ => $row->{$_} } grep { exists $row->{$_} } @$fields } }

sub _read_back ( $client, $model, $id, $fields ) {
    my $rows = eval { $client->model($model)->read( [$id], [ 'display_name', @$fields ] ) };
    if ( my $err = $@ ) {
        return undef if blessed($err) && $err->isa('Odoo::Error') && ( $err->fault_category // '' ) eq 'missing';
        die $err;
    }
    return $rows->[0];
}

# A model-level method: execute_kw with no ids. There is no record to read, so
# the made records (when the entry lists creates) are the read-back.
sub _apply_model_level ( $class, $client, $c ) {
    my $v      = $c->{vals};
    my $specs  = $v->{creates} // [];
    my $before = $AC->creates_before( $client, $specs );
    my $ret    = $client->execute_kw( $c->{model}, $v->{method}, [ @{ $v->{args} // [] } ],
        { ( %{ $v->{context} // {} } ? ( context => $v->{context} ) : () ) } );
    my $ans    = $AC->answer( $ret, undef, $c->{model}, undef );
    my $found  = $AC->creates_after( $client, $specs, $before, $c->{model}, [] );
    my $wnote  = $AC->window_note( $ans, $specs, $before );
    $ans->{says} .= "; $wnote" if length $wnote;
    my $read = @$specs
        ? ( @{ $found->{created} } ? '' : '; no record made in ' . join( ', ', map { $_->{model} } @$specs ) . ' by this login while it ran' )
        : '; nothing read back: a model-level method has no record';
    my $says = "$c->{model}: $v->{method}; $ans->{says}$read";
    return {
        id       => undef,
        returned => {
            method => $v->{method}, on => 'model', says => $says, args_count => scalar @{ $v->{args} // [] },
            ( $ans->{window} ? ( window => $ans->{window} ) : () ),
            ( defined $ret && ref $ret ? ( value => $ret ) : () ),
            $AC->found_returned($found),
        },
        after => { model => $c->{model}, method => $v->{method} },
        $AC->found_created($found),
    };
}

=head2 apply_custom($class, $client, $change)

Reads the record, calls the method on it with the change's context and arguments,
reads the record back. Returns the state before and after, Odoo's answer in words
and the window it opened, if any, as C<returned>; C<after> is the state fields as
read back (the id when the model names none), undef when the record is gone.

=cut

sub apply_custom ( $class, $client, $c ) {
    Odoo::Error->throw( kind => 'usage', message => "$c->{handler} cannot apply kind '" . ( $c->{kind} // '' ) . "'" )
        if ( $c->{kind} // '' ) ne 'action';
    my $v = $c->{vals};
    Odoo::Error->throw( kind => 'usage', message => "$c->{handler}: the change names no public method" )
        if ref $v ne 'HASH' || ( $v->{method} // '' ) !~ /\A[A-Za-z]\w*\z/;
    return $class->_apply_model_level( $client, $c ) if ( $v->{on} // '' ) eq 'model';
    my $fields = $v->{state_fields} // [];
    my $was    = _read_back( $client, $c->{model}, $c->{id}, $fields );
    my $specs  = $v->{creates} // [];
    my $before = $AC->creates_before( $client, $specs );
    my $ret    = $client->execute_kw( $c->{model}, $v->{method}, [ [ $c->{id} ], @{ $v->{args} // [] } ],
        { %{ $v->{kwargs} // {} }, ( %{ $v->{context} // {} } ? ( context => $v->{context} ) : () ) } );
    my $now = _read_back( $client, $c->{model}, $c->{id}, $fields );
    my $ans = $AC->answer( $ret, $v->{wizard}, $c->{model}, $v->{wizard_method} );
    my $found = $AC->creates_after( $client, $specs, $before, $c->{model}, [ $c->{id} ] );
    my $wnote = $AC->window_note( $ans, $specs, $before );
    $ans->{says} .= "; $wnote" if length $wnote;

    my $swas = $was ? _states( $was, $fields ) : {};
    my $snow = $now ? _states( $now, $fields ) : {};
    my $what = "$c->{model} $c->{id}" . ( length( $v->{name} // '' ) ? " ($v->{name})" : '' );
    my @moved = map { "$_ " . $AC->state_text( $swas->{$_} ) . ' -> ' . $AC->state_text( $snow->{$_} ) } @$fields;
    my $says = "$what: $v->{method}" . ( !$now ? ' - the record is gone' : @moved ? '; ' . join( ', ', @moved ) : '' ) . '; ' . $ans->{says};
    return {
        id       => $c->{id},
        returned => {
            method => $v->{method}, says => $says,
            ( @$fields ? ( state_before => $swas, state_after => $snow ) : () ),
            ( $ans->{window} ? ( window => $ans->{window} ) : () ),
            $AC->found_returned($found),
            ( $now ? () : ( gone => JSON::PP::true ) ),
        },
        after => !$now ? undef : @$fields ? $snow : { id => $c->{id} },
        $AC->found_created($found),
    };
}

=head2 undo_custom($class, $entry)

The action the behaviour file names as C<undo> for the method, as a change on the
same record; a method with none is held, naming the method.

=cut

sub undo_custom ( $class, $entry ) {
    return ( undef, "$entry->{handler} cannot undo kind '" . ( $entry->{kind} // '' ) . "'" ) if ( $entry->{kind} // '' ) ne 'action';
    my $v   = $entry->{vals} // {};
    my $ret = ref $entry->{returned} eq 'HASH' ? $entry->{returned} : {};
    if ( ( $v->{on} // '' ) eq 'model' ) {
        return ( undef, "$entry->{model}: $v->{method} is a model-level method with no undo named in the behaviour file of $entry->{model}, so OOM does not guess one" )
            if !defined $v->{undo};
        $AC->add_undo_scope( $entry->{model}, $v->{undo} );
        return {
            action => 'custom', handler => 'core.action', kind => 'action', bucket => 'undo-action',
            model => $entry->{model}, key => "undo:$entry->{model}:$v->{undo}", calls => [ [ $entry->{model}, $v->{undo} ] ],
            vals => { on => 'model', method => $v->{undo}, args => $v->{args} // [], kwargs => {}, context => $v->{context} // {}, params => $v->{params} // [] },
            line   => "$entry->{model}: $v->{undo}(" . scalar( @{ $v->{args} // [] } ) . ' argument' . ( @{ $v->{args} // [] } == 1 ? '' : 's' ) . ' as for ' . $v->{method} . ')',
            reason => "$entry->{model}: $v->{undo} is called with the arguments of $v->{method} (its undo)",
        };
    }
    return ( undef, "$entry->{model} $entry->{id}: $v->{method} has no undo named in the behaviour file of $entry->{model}, so OOM does not guess one" )
        if !defined $v->{undo};
    return ( undef, "$entry->{model} $entry->{id} is gone, so there is nothing to take $v->{method} back from" ) if $ret->{gone};
    my $now = $ret->{state_after};
    $AC->add_undo_scope( $entry->{model}, $v->{undo} );
    my $name = length( $v->{name} // '' ) ? " ($v->{name})" : '';
    return {
        action => 'custom', handler => 'core.action', kind => 'action', bucket => 'undo-action',
        model => $entry->{model}, id => $entry->{id}, key => "undo:$entry->{model} $entry->{id}", calls => [ [ $entry->{model}, $v->{undo} ], [ $entry->{model}, 'read' ] ],
        ( ref $now eq 'HASH' && %$now ? ( before => $now ) : () ),
        vals => {
            method => $v->{undo}, args => [], kwargs => {}, context => $v->{context} // {},
            state_fields => $v->{state_fields} // [], name => $v->{name} // '',
        },
        line   => "$entry->{model} $entry->{id}$name: $v->{undo}",
        reason => "$entry->{model} $entry->{id}$name goes back through $v->{undo} (the undo of $v->{method})",
    };
}

=head2 describe_model($class, $ctx, $model)

What C<oom-ops describe core.action --set model=M> prints: the behaviour file's
state block and each listed method with its states, undo, wizard, note and
evidence. With a connection the server's series picks the file, each entry says
C<applies> or C<not applicable here (module X)>, and a model the server does not
have is refused C<not-applicable>; without one the newest file is read and
nothing is claimed about the server.

=cut

sub describe_model ( $class, $ctx, $model ) {
    return $AC->describe_entries( $ctx, $model, 'actions' );
}

1;
