package Odoo::Ops::Core::Wizard;

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

Odoo::Ops::Core::Wizard - do what a button's wizard does: make the transient record, call its method

=head1 SYNOPSIS

    oom-ops run core.wizard --conf ops.conf --set model=hr.holidays.cancel.leave --set for=hr.leave \
        --set records=100 --set 'values={"reason":"booked in error"}' --set method=action_cancel_leave
    oom-ops describe core.wizard --set for=hr.leave

=head1 DESCRIPTION

Some of Odoo's actions answer with a window: a wizard, a transient model whose
form the user fills in and confirms. C<core.wizard> is the second primitive
beside L<Odoo::Ops::Core::Action>. It does what the button does: creates the
transient record C<model> with C<values> and the context the button gives
(C<active_model>, C<active_id> and C<active_ids> from C<for> and C<records>, the
behaviour file's C<context> keys and its C<context_from_record> keys, then the
caller's C<context>), then calls C<method> on it.

The wizard model and method must be listed under C<wizards:> in the behaviour
file of the target model (C<for>), or the plan is refused with
C<refused/unlisted-wizard>; an entry with C<on: model> is a wizard a menu opens,
with no records: C<records> is refused C<usage> for it, the context carries no
C<active_*> keys, and C<for> only names the model whose file lists it (an entry
without C<on: model> needs C<records>); a listed wizard whose module is not installed is
refused C<refused/not-applicable>. C<records> is a list of ids or a
C<field=value>. The plan shows the values, the context and the records, each with
its state as read now. Apply reports what the method returned as C<core.action>
does, and reads the target records back: state before and after.

What the method made is named. When the behaviour entry lists C<creates:> (the
models the method is known to make records in), apply reads the highest id of each
before the call and, after it, the records above it whose C<create_uid> is the
session's uid: they are reported as made by this login in that model while the
action ran, in C<created> (C<< { model, id, name, state } >>) of the change's
C<returned> block, of the result's C<custom> entry and of the journal. A C<link>
field of the records acted on is read back beside them (C<links>; a record it names
that the search did not find is "linked, not made in this call"). The plan line ends
C<creates: M> or C<creates: not listed>. See L<Odoo::Ops::Core::ActionCommon/creates_after>.

C<revert> is held C<irreversible> unless the behaviour file names an C<undo>
action of the target model for the wizard; the revert then plans that action
(for a wizard that acted on one record).

A write operation: plans only; C<apply> carries it out.

=cut

sub op_name ($class) { 'core.wizard' }
sub summary ($class) { 'Plan what a button\'s wizard does: create the transient record with values and context, call its method; the behaviour file lists the wizards' }
sub pack    ($class) { undef }
sub params ($class) {
    {   model   => { type => 'str',  required => 1, help => 'the wizard: a transient model, e.g. hr.holidays.cancel.leave' },
        for     => { type => 'str',  required => 1, help => 'the model the wizard acts on, whose behaviour file lists it (hr.leave)' },
        records => { type => 'str',  help => 'the records it acts on: comma-separated ids, or field=value such as name=X (not for an on: model entry)' },
        values  => { type => 'json', default => '{}', help => 'the wizard\'s field values, a JSON object' },
        method  => { type => 'str',  required => 1, help => 'the wizard\'s public method, listed under wizards (oom-ops describe core.wizard --set for=M)' },
        context => { type => 'json', help => 'more context for the create and the call, a JSON object' },
    };
}
sub buckets ($class) {
    [ { name => 'wizard', meaning => 'the wizard record is created and its method called; apply reports the target records before and after' } ];
}
sub holds ($class) {
    [ { name => 'unknown-record', meaning => 'no record has that id, or matches that field=value' } ];
}
sub read_scope  ($class) { {} }
sub write_scope ($class) { {} }
sub writes      ($class) { 1 }

# the invariants that matter are those of the records the wizard acts on
sub models_touched ( $class, $change ) { grep { defined } $change->{vals}{for} }

sub describe_key ($class) { 'for' }

sub scope_for ( $self, $phase ) {
    my %s = ( 'ir.module.module' => { search_read => 1 } );
    my ( $model, $for ) = ( $self->param('model'), $self->param('for') );
    $s{$for}{$_} = 1 for defined $for ? qw(search_read read) : ();
    if ( $phase eq 'apply' && defined $model ) {
        $s{$model}{$_} = 1 for 'create', grep { defined } $self->param('method');
    }
    if ( $phase eq 'apply' && defined $for && defined $model && defined $self->param('method') && $self->ctx ) {
        my $entry = eval { $self->ctx->behaviour($for)->wizard( $model, $self->param('method') ) };
        my %c = $AC->creates_scope($entry);
        for my $m ( keys %c ) { $s{$m}{$_} = 1 for @{ $c{$m} } }
    }
    if ( $phase eq 'apply' ) {
        my $u = $AC->undo_scope;
        for my $m ( keys %$u ) { $s{$m}{$_} = 1 for 'read', @{ $u->{$m} } }
    }
    return { map { $_ => [ sort keys %{ $s{$_} } ] } keys %s };
}

sub plan ($self) {
    my $me     = $self->op_name;
    my ( $model, $for, $method ) = map { $self->param($_) } qw(model for method);
    Odoo::Error->throw( kind => 'usage', message => "$me: model and for must be physical model names (with a dot), got '$model' and '$for'" )
        if $model !~ /\./ || $for !~ /\./;
    Odoo::Error->throw( kind => 'usage', message => "$me: method must be a method name, got '$method'" ) if $method !~ /\A\w+\z/;
    my $values = $self->param('values') // {};
    my $extra  = $self->param('context') // {};
    Odoo::Error->throw( kind => 'usage', message => "$me: values must be a JSON object" ) if ref $values ne 'HASH';
    Odoo::Error->throw( kind => 'usage', message => "$me: context must be a JSON object" ) if ref $extra ne 'HASH';

    my $beh = $self->ctx->behaviour($for);
    if ( my $why = Odoo::Ops::Modules->missing( $self->ctx, $beh->module ) ) { Odoo::Ops::Modules->refuse_model( $me, $for, $why ) }
    $AC->refuse_unlisted( $self->ctx, $for, 'wizard', "$me: $model $method is private (a method that starts with _ is never called)" )
        if $method =~ /\A_/;
    my $entry = $beh->wizard( $model, $method )
        or $AC->refuse_unlisted( $self->ctx, $for, 'wizard',
            "$me: wizard $model $method is not listed for $for in its behaviour file" . ( $beh->known ? '' : ' (there is none)' ) );
    $AC->refuse_module( $self->ctx, $me, "wizard $model $method", $entry->{module} // $beh->module );

    my $fm     = eval { $self->client->model($for) };
    my $fields = eval { $fm->fields } || Odoo::Ops::Modules->absent_model( $self->ctx, $me, $for, $@ );
    my @state = grep { $fields->{$_} } $beh->state_fields;
    my @read  = ( 'id', 'display_name', @state );
    my $rec   = $self->param('records');
    if ( $beh->on_model($entry) ) {
        Odoo::Error->throw( kind => 'usage', message => "$me: $model $method is opened from a menu, not from a record: it takes no records, so records is not given",
            fix => "drop --set records; for names the model whose behaviour file lists the wizard (oom-ops describe core.wizard --set for=$for)" )
            if defined $rec && length $rec;
        my $plan = $self->new_plan( input_count => 1 );
        $plan->note("$for $model $method: $entry->{note}") if length( $entry->{note} // '' );
        my %context = ( %{ $entry->{context} // {} }, %$extra );
        my $creates = $AC->creates_specs( $self->ctx, $entry );
        my $json    = JSON::PP->new->canonical;
        $plan->add(
            bucket => 'wizard', action => 'custom', handler => $me, kind => 'wizard', key => "$model:",
            model => $model,
            vals => {
                for => $for, method => $method, values => $values, context => \%context, ids => [], state_fields => [], states_before => {},
                ( @$creates ? ( creates => $creates ) : () ), names => {},
                ( defined $entry->{undo} ? ( undo => $entry->{undo} ) : () ),
            },
            line   => "$model $method; no records; values " . $json->encode($values) . "; context " . $json->encode( \%context ) . '; ' . $AC->creates_words($creates),
            reason => "$model is created with " . $json->encode($values) . " and its $method called, with no records",
        );
        return $plan;
    }
    Odoo::Error->throw( kind => 'usage', message => "$me: $model $method acts on records: records is required",
        fix => 'name the records, as ids or field=value' ) if !defined $rec || !length $rec;
    my ( $one, $ids ) = $rec =~ /\A\s*\d+(?:\s*,\s*\d+)*\s*\z/ ? ( undef, [ split /\s*,\s*/, $rec =~ s/\A\s+|\s+\z//gr ] ) : ( $rec, undef );
    my ( $want, $by_id ) = $AC->resolve_records( $self->client, $me, $for, $fields, $one, $ids, \@read );

    my $plan = $self->new_plan( input_count => scalar @$want );
    my ( @found, %before );
    for my $w (@$want) {
        my ( $id, $label ) = @$w;
        my $row = defined $id ? $by_id->{$id} : undef;
        if ( !$row ) {
            $plan->add( bucket => 'unknown-record', action => 'hold', key => "$for:" . ( $id // $label ),
                reason => "$me: no $for " . ( defined $id ? "has id $id" : "matches $label" ) );
            next;
        }
        push @found, $row;
        $before{ $row->{id} } = { map { $_ => $row->{$_} } @state };
    }
    return $plan if !@found;

    my @rids = map { $_->{id} } @found;
    my @pin  = @{ $entry->{context_from_record} // [] };
    Odoo::Error->throw( kind => 'usage',
        message => "$me: $model sets " . join( ', ', @pin ) . " from the record, so it acts on one record; " . scalar(@rids) . ' were named',
        fix     => 'name one record per call' ) if @pin && @rids > 1;
    my %context = ( active_model => $for, active_id => $rids[0], active_ids => \@rids, %{ $entry->{context} // {} }, ( map { $_ => $rids[0] } @pin ), %$extra );

    $plan->note("$for $model $method: $entry->{note}") if length( $entry->{note} // '' );
    my $creates = $AC->creates_specs( $self->ctx, $entry );
    my $names = join ', ', map { "$for $_->{id}" . $AC->name_of($_) } @found;
    my $json  = JSON::PP->new->canonical;
    my $sline = @state ? '; ' . join( '; ', map { my $r = $_; "$r->{id}: " . join( ', ', map { "$_ " . $AC->state_text( $r->{$_} ) } @state ) } @found ) : '';
    $plan->add(
        bucket => 'wizard', action => 'custom', handler => $me, kind => 'wizard', key => "$model:" . join( ',', @rids ),
        model => $model,
        vals => {
            for => $for, method => $method, values => $values, context => \%context, ids => \@rids, state_fields => \@state,
            states_before => \%before,
            ( @$creates ? ( creates => $creates ) : () ),
            names => { map { $_->{id} => ( $_->{display_name} // '' ) } @found },
            ( defined $entry->{undo} ? ( undo => $entry->{undo} ) : () ),
        },
        line   => "$model $method for $names; values " . $json->encode($values) . "; context " . $json->encode( \%context ) . $sline . '; ' . $AC->creates_words($creates),
        reason => "$model is created with " . $json->encode($values) . " and its $method called, for $names",
    );
    return $plan;
}

sub _states ( $client, $for, $ids, $fields ) {
    my %out;
    return ( \%out, [] ) if !@$ids;
    my $rows = $client->model($for)->read( $ids, [ 'display_name', @$fields ] );
    my %have = map { $_->{id} => $_ } @$rows;
    my @gone = grep { !$have{$_} } @$ids;
    for my $id (@$ids) { $out{$id} = { map { $_ => $have{$id}{$_} } @$fields } if $have{$id} }
    return ( \%out, \@gone );
}

=head2 apply_custom($class, $client, $change)

Creates the wizard record with the change's values and context, calls its method
with the same context, and reads the target records back. C<returned> carries the
wizard's id, the state of each record before and after, and Odoo's answer in
words; C<after> is those states, undef when a record is gone.

=cut

sub apply_custom ( $class, $client, $c ) {
    Odoo::Error->throw( kind => 'usage', message => "$c->{handler} cannot apply kind '" . ( $c->{kind} // '' ) . "'" )
        if ( $c->{kind} // '' ) ne 'wizard';
    my $v = $c->{vals};
    Odoo::Error->throw( kind => 'usage', message => "$c->{handler}: the change names no public method" )
        if ref $v ne 'HASH' || ( $v->{method} // '' ) !~ /\A[A-Za-z]\w*\z/;
    my ( $ctx, $fields, $ids ) = ( $v->{context} // {}, $v->{state_fields} // [], $v->{ids} // [] );
    my ($was) = _states( $client, $v->{for}, $ids, $fields );
    my $specs  = $v->{creates} // [];
    my $before = $AC->creates_before( $client, $specs );
    my $wid = $client->execute_kw( $c->{model}, 'create', [ $v->{values} // {} ], { context => $ctx } );
    $wid = $wid->[0] if ref $wid eq 'ARRAY';
    my $ret = $client->execute_kw( $c->{model}, $v->{method}, [ [$wid] ], { context => $ctx } );
    my ( $now, $gone ) = _states( $client, $v->{for}, $ids, $fields );
    my $ans = $AC->answer($ret);
    my $found = $AC->creates_after( $client, $specs, $before, $v->{for}, $ids );
    my $wnote = $AC->window_note( $ans, $specs, $before );
    $ans->{says} .= "; $wnote" if length $wnote;

    my @moved = map {
        my $id = $_;
        my $name = length( $v->{names}{$id} // '' ) ? " ($v->{names}{$id})" : '';
        "$v->{for} $id$name" . ( ( grep { $_ == $id } @$gone ) ? ' is gone' : @$fields ? ': ' . join( ', ', map { "$_ " . $AC->state_text( $was->{$id}{$_} ) . ' -> ' . $AC->state_text( $now->{$id}{$_} ) } @$fields ) : '' )
    } @$ids;
    my $says = join( '; ', "$c->{model} $wid: $v->{method}", @moved, $ans->{says} );
    if ( !@$ids ) {
        $says .= @$specs
            ? ( @{ $found->{created} } ? '' : '; no record made in ' . join( ', ', map { $_->{model} } @$specs ) . ' by this login while it ran' )
            : '; nothing read back: a wizard opened with no records has none';
    }
    return {
        id       => $wid,
        returned => {
            wizard_id => $wid, method => $v->{method}, says => $says,
            ( @$fields ? ( state_before => $was, state_after => $now ) : () ),
            ( $ans->{window} ? ( window => $ans->{window} ) : () ),
            $AC->found_returned($found),
            ( @$gone ? ( gone => $gone ) : () ),
        },
        after => @$gone ? undef : @$fields ? { records => $now } : { ids => $ids },
        $AC->found_created($found),
    };
}

=head2 undo_custom($class, $entry)

The target model's action the behaviour file names as C<undo> for the wizard, as a
change on the one record the wizard acted on; a wizard with none, or one that
acted on several records, is held.

=cut

sub undo_custom ( $class, $entry ) {
    return ( undef, "$entry->{handler} cannot undo kind '" . ( $entry->{kind} // '' ) . "'" ) if ( $entry->{kind} // '' ) ne 'wizard';
    my $v = $entry->{vals} // {};
    return ( undef, "$entry->{model} $v->{method} has no undo named in the behaviour file of $v->{for}, so OOM does not guess one" )
        if !defined $v->{undo};
    my @ids = @{ $v->{ids} // [] };
    return ( undef, "$entry->{model} $v->{method} acted on " . scalar(@ids) . " $v->{for} records; its undo $v->{undo} is planned for one record, so revert each by core.action" )
        if @ids != 1;
    my $ret = ref $entry->{returned} eq 'HASH' ? $entry->{returned} : {};
    return ( undef, "$v->{for} $ids[0] is gone, so there is nothing to take $v->{method} back from" ) if $ret->{gone};
    my $id   = $ids[0];
    my $now  = ref $ret->{state_after} eq 'HASH' ? $ret->{state_after}{$id} : undef;
    my $name = length( $v->{names}{$id} // '' ) ? " ($v->{names}{$id})" : '';
    $AC->add_undo_scope( $v->{for}, $v->{undo} );
    return {
        action => 'custom', handler => 'core.action', kind => 'action', bucket => 'undo-action',
        model => $v->{for}, id => $id, key => "undo:$v->{for} $id",
        ( ref $now eq 'HASH' && %$now ? ( before => $now ) : () ),
        vals => {
            method => $v->{undo}, args => [], kwargs => {}, context => {},
            state_fields => $v->{state_fields} // [], name => $v->{names}{$id} // '',
        },
        line   => "$v->{for} $id$name: $v->{undo}",
        reason => "$v->{for} $id$name goes back through $v->{undo} (the undo of $entry->{model} $v->{method})",
    };
}

=head2 describe_model($class, $ctx, $for)

What C<oom-ops describe core.wizard --set for=M> prints: the wizards the behaviour
file of C<M> lists, each with its method, button, values, undo and evidence; with a
connection, each says C<applies> or C<not applicable here (module X)>, and a model the server does not have is refused C<not-applicable>.

=cut

sub describe_model ( $class, $ctx, $for ) {
    return $AC->describe_entries( $ctx, $for, 'wizards' );
}

1;
