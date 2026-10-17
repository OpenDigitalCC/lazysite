package Odoo::Ops::Core::ActionCommon;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Cwd ();
use JSON::PP ();
use Scalar::Util qw(blessed);

use Odoo::Error;
use Odoo::Ops::Modules;

=head1 NAME

Odoo::Ops::Core::ActionCommon - what C<core.action> and C<core.wizard> share

=head1 DESCRIPTION

Plain functions, not an operation. The two operations call Odoo's own
methods on records, so they need the same few things: the records a call
names, the state of a record as Odoo holds it, whether the module that adds
a method is installed, how Odoo's answer is put into words, and the
refusals that name the behaviour file to edit.

=head2 refuse_unlisted($ctx, $model, $what, $message)

The C<refused> error for a method or wizard the model's behaviour file does
not list. C<$what> is C<action> or C<wizard>; the C<fix> names the file to add
the entry to, or says that the model has no file yet.

=cut

sub behaviour_file ( $class, $beh, $model, $series ) {
    return $beh->path ? ( Cwd::abs_path( $beh->path ) // $beh->path ) : "behaviours/$model/$series.yaml (the model has no behaviour file yet)";
}

sub refuse_unlisted ( $class, $ctx, $model, $what, $message ) {
    my $beh    = $ctx->behaviour($model);
    my $series = $beh->series || $ctx->config->get('profile_series') || $ctx->client->server_series;
    my $file   = $class->behaviour_file( $beh, $model, $series );
    my $list   = $what eq 'wizard' ? 'wizards' : 'actions';
    my $fix = "add it under '$list:' in $file if Odoo's own method is the one meant; oom-ops describe core.$what --set "
        . ( $what eq 'wizard' ? 'for' : 'model' ) . "=$model lists what is there";
    if ( $what eq 'wizard' ) {
        Odoo::Error->throw( kind => 'refused', code => 'unlisted-wizard', message => $message, fix => $fix );
    }
    Odoo::Error->throw( kind => 'refused', code => 'unlisted-action', message => $message, fix => $fix );
}

=head2 refuse_module($ctx, $op, $subject, $module)

The module check of an entry: C<refused/not-applicable> (via
L<Odoo::Ops::Modules>) when the module is not installed here, naming the
module. Nothing is claimed when the module table cannot be read.
C<$module> is the entry's own module or, when it names none, its model's.

=cut

sub refuse_module ( $class, $ctx, $op, $subject, $module ) {
    my $why = Odoo::Ops::Modules->missing( $ctx, $module ) // return;
    Odoo::Ops::Modules->refuse( $op, $subject, $why );
}

=head2 resolve_records($client, $op, $model, $fields, $record, $ids, \@read)

The records a call names, as C<< ( \@want, \%by_id ) >>: C<@want> holds
C<[ $id ]> for a record asked for by id and C<[ undef, $label ]> for a
C<field=value> that matched nothing; C<%by_id> the rows read (archived ones
included). C<$record> is an id or C<field=value> (a value that matches more
than one record is refused, naming the ids); C<$ids> a list of ids. Exactly
one of the two is given.

=cut

sub resolve_records ( $class, $client, $op, $model, $fields, $record, $ids, $read ) {
    my $have_ids = $ids && @$ids;
    Odoo::Error->throw( kind => 'usage', message => "$op: give exactly one of record and records" )
        if ( defined $record && length $record ? 1 : 0 ) + ( $have_ids ? 1 : 0 ) != 1;
    my @bad = $have_ids ? grep { !/^\d+\z/ } @$ids : ();
    Odoo::Error->throw( kind => 'usage', message => "$op: records must be whole numbers, got '$bad[0]'" ) if @bad;
    my $m   = $client->model($model);
    my $all = { active_test => JSON::PP::false };
    my ( @want, $found );
    if ($have_ids) {
        my %seen;
        my @u = grep { !$seen{$_}++ } map { 0 + $_ } @$ids;
        @want  = map { [$_] } @u;
        $found = $m->search_read( [ [ 'id', 'in', \@u ] ], $read, context => $all );
    }
    elsif ( $record =~ /^\s*(\d+)\s*\z/ ) {
        @want  = ( [ 0 + $1 ] );
        $found = $m->search_read( [ [ 'id', '=', 0 + $1 ] ], $read, context => $all );
    }
    elsif ( my ( $f, $val ) = $record =~ /^(\w+)=(.*)\z/s ) {
        Odoo::Error->throw( kind => 'usage', message => "$op: $model has no field '$f'",
            fix => "oom-ops run core.skeleton --conf <conf> --set model=$model lists the fields" ) if !$fields->{$f};
        $found = $m->search_read( [ [ $f, '=', $val ] ], $read, limit => 6, context => $all );
        Odoo::Error->throw( kind => 'usage', message => "$op: $record matches $model records " . join( ', ', map { $_->{id} } @$found ),
            fix => 'pass --set records=' . join( ',', map { $_->{id} } @$found ) . ' (the ones meant)' ) if @$found > 1;
        @want = $found->[0] ? ( [ $found->[0]{id} ] ) : ( [ undef, $record ] );
    }
    else {
        Odoo::Error->throw( kind => 'usage', message => "$op: record '$record' is neither an id nor field=value" );
    }
    return ( \@want, { map { $_->{id} => $_ } @$found } );
}

=head2 name_of($row)

C<" (display name)"> for a plan line, or an empty string.

=cut

sub name_of ($class, $row) {
    my $n = $row->{display_name};
    return defined $n && !ref $n && length $n ? " ($n)" : '';
}

=head2 state_text($value)

A state as the plan prints it: the value, C<none> for an empty one.

=cut

sub state_text ($class, $v) {
    return 'none' if !defined $v || ( !ref $v && ( $v eq '' || $v eq '0' ) ) || ( blessed($v) && !$v );
    return ref $v eq 'ARRAY' ? ( defined $v->[1] ? $v->[1] : $v->[0] ) : ( ref $v ? JSON::PP->new->canonical->encode($v) : "$v" );
}

=head2 answer($returned, $wizard, $model, $wizard_method)

Odoo's answer to a method, in words, with the parts a caller acts on:

    nothing                                   the method returned nothing
    true / false                              reported as that (the transports read a boolean and the numbers 1 and 0 alike)
    Odoo answered with a window: M (modes)    an ir.actions.act_window: Odoo wants a
                                              wizard or shows a record; OOM does not follow
    Odoo answered with an action: TYPE (tag)  any other action dictionary
    Odoo answered: VALUE                      anything else

When the behaviour file names the wizard for the method, a window answer also
says to use C<core.wizard>. Returns C<< { says => TEXT, window => {...} } >>.

=cut

sub answer ( $class, $ret, $wizard = undef, $model = undef, $wizard_method = undef ) {
    return { says => 'Odoo answered with nothing' } if !defined $ret;
    # the transports read a server boolean as 1 or 0, so those two words are what a boolean arrives as
    if ( ( blessed($ret) && $ret->isa('JSON::PP::Boolean') ) || ( !ref $ret && $ret =~ /\A[01]\z/ ) ) {
        return { says => 'Odoo answered with ' . ( $ret ? 'true' : 'false' ) };
    }
    if ( ref $ret eq 'HASH' && ( $ret->{type} // '' ) eq 'ir.actions.act_window' ) {
        my $mode = $ret->{view_mode} // 'form';
        my $says = "Odoo answered with a window: " . ( $ret->{res_model} // 'unknown model' ) . " ($mode)";
        $says .= "; it is a wizard: use core.wizard --set model=$wizard --set for=$model"
            . ( defined $wizard_method ? " --set method=$wizard_method" : '' )
            if defined $wizard;
        return {
            says   => $says,
            window => { map { $_ => $ret->{$_} } grep { defined $ret->{$_} && !ref $ret->{$_} } qw(res_model view_mode res_id name target) },
        };
    }
    if ( ref $ret eq 'HASH' && defined $ret->{type} ) {
        my $tag = defined $ret->{tag} && !ref $ret->{tag} ? " ($ret->{tag})" : '';
        return { says => "Odoo answered with an action: $ret->{type}$tag" };
    }
    my $text = ref $ret ? JSON::PP->new->canonical->encode($ret) : "$ret";
    $text = substr( $text, 0, 200 ) . '...' if length $text > 200;
    return { says => "Odoo answered: $text" };
}

# models/methods a revert has asked this process to undo: the revert plans its
# scope from a handler built with no parameters, so the call is not known to it
our %UNDO_SCOPE;

sub add_undo_scope ( $class, $model, $method ) { $UNDO_SCOPE{$model}{$method} = 1 }

sub undo_scope ($class) {
    return { map { my $m = $_; ( $m => [ sort keys %{ $UNDO_SCOPE{$m} } ] ) } keys %UNDO_SCOPE };
}

=head2 describe_entries($ctx, $model, $kind)

The document C<oom-ops describe core.action|core.wizard --set model=M> prints.
C<$kind> is C<actions> or C<wizards>. With a context (a connection) the server's
series picks the behaviour file, each entry says C<here: applies> or C<here:
not applicable here (module X)>, and a model the server does not have is
refused C<not-applicable> (L<Odoo::Ops::Modules/absent_model>); without a
context the newest file is read and nothing is claimed about the server.

=cut

sub describe_entries ( $class, $ctx, $model, $kind ) {
    require Odoo::Ops::Behaviour;
    my $beh;
    my $op = "describe core." . ( $kind eq 'wizards' ? 'wizard' : 'action' );
    if ($ctx) {
        $beh = $ctx->behaviour($model);
        # a model of a module this server lacks is not described: it is not applicable here
        if ( my $why = Odoo::Ops::Modules->missing( $ctx, $beh->module ) ) {
            Odoo::Ops::Modules->refuse_model( $op, $model, $why );
        }
        # a model with no file for the module to say: ask the server whether it has the model at all
        if ( !defined $beh->module ) {
            my $f = eval { $ctx->client->model($model)->fields };
            Odoo::Ops::Modules->absent_model( $ctx, $op, $model, $@ ) if !$f;
        }
    }
    else {
        my $latest = Odoo::Ops::Behaviour->latest($model);
        $beh = defined $latest ? Odoo::Ops::Behaviour->load( model => $model, series => $latest ) : Odoo::Ops::Behaviour->load( model => $model, series => 1 );
    }
    my $here = sub ($module) {
        return () if !$ctx;
        return ( here => Odoo::Ops::Modules->missing( $ctx, $module ) ? "not applicable here (module $module)" : 'applies' );
    };
    my %mh      = defined $beh->module ? $here->( $beh->module ) : ();
    my @entries = map { +{ %$_, $here->( $_->{module} // $beh->module ) } } @{ $beh->$kind };
    return {
        model          => $model,
        series         => $beh->series || undef,
        behaviour_file => $beh->path,
        ( defined $beh->module ? ( module => $beh->module, ( $mh{here} ? ( module_here => $mh{here} ) : () ) ) : () ),
        ( $beh->state_info ? ( state => $beh->state_info ) : () ),
        $kind => \@entries,
        ( $beh->known ? () : ( note => "no behaviour file for $model: nothing is listed, so core." . ( $kind eq 'wizards' ? 'wizard' : 'action' ) . ' refuses every call on it' ) ),
    };
}

1;
