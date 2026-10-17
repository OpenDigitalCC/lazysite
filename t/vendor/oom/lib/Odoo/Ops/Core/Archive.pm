package Odoo::Ops::Core::Archive;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Error;
use Odoo::Ops::Modules;
use Odoo::Ops;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Core::Archive - archive records of any model through Odoo's own action

=head1 SYNOPSIS

    oom-ops run core.archive --conf ops.conf --set model=res.partner --set record=ref=C001
    oom-ops run core.archive --conf ops.conf --set model=product.product --set ids=99,100

=head1 DESCRIPTION

C<core.archive> takes records out of the default lists the way Odoo's
Archive button does: it calls C<action_archive> on them. C<active> is
never written (a write skips what the model does on archiving: a partner's
contacts, a product's variants, a template's record rules), and the
apply reads C<active> back and says unverified when it did not become
false. It is the general operation: C<mailing.archive> stays as it is,
with its own holds, for a mailing.

The records are named by C<record> (an id, or C<field=value> such as
C<ref=C001>; a value that matches more than one record is refused, give
C<ids>) or by C<ids> (comma-separated). One change is planned per record,
in bucket C<archive>, a C<custom> change whose undo is C<action_unarchive>
(a revert brings the record back, and C<core.unarchive> does the same by
hand). Records that cannot be archived are holds, each with a reason:

    already           the record is archived already
    unknown-record    no record has that id (or matches that field=value)
    no-active-field   the model has no C<active> field: there is nothing to archive

An archived record keeps its history and its references, which is why it is
the end state for a record a revert holds as C<referenced> (a partner an
order was confirmed for, a product a stock move points at). Odoo counters
and the stock moves a confirm leaves are not undone by archiving.

A write operation: plans only; C<apply> carries it out.

=cut

sub op_name ($class) { 'core.archive' }
sub summary ($class) { 'Plan archiving records of any model through Odoo\'s action_archive (active is never written); the general archive' }
sub pack    ($class) { undef }
sub params ($class) {
    {   model  => { type => 'str',  required => 1, help => 'physical model, e.g. res.partner' },
        record => { type => 'str',  help => 'one record: an id, or field=value such as ref=C001' },
        ids    => { type => 'list', help => 'comma-separated record ids (instead of record)' },
    };
}
sub buckets ($class) {
    [ { name => 'archive', meaning => 'the record is archived through action_archive; undo is action_unarchive' } ];
}
sub holds ($class) {
    [
        { name => 'already',         meaning => 'the record is archived already' },
        { name => 'unknown-record',  meaning => 'no record has that id, or matches that field=value' },
        { name => 'no-active-field', meaning => 'the model has no active field: there is nothing to archive' },
    ];
}
sub read_scope  ($class) { {} }    # built per run from the model
sub write_scope ($class) { {} }
sub writes      ($class) { 1 }

# what this class does: the method, the state it ends in, the opposite operation
sub _mode ($class) { { bucket => 'archive', method => 'action_archive', to => 0, opposite => 'core.unarchive' } }

# Models a revert has asked this process to undo: the revert plans its scope
# from a handler built with no parameters, so the model is not known to it.
our %UNDO_MODELS;

sub scope_for ($self, $phase) {
    my @models = defined $self->param('model') ? ( $self->param('model') ) : sort keys %UNDO_MODELS;
    my %s;
    for my $m (@models) {
        $s{$m}{search_read} = 1;
        if ( $phase eq 'apply' ) {
            $s{$m}{$_} = 1 for qw(read action_archive action_unarchive);    # a revert of either uses the other
        }
    }
    return { map { $_ => [ sort keys %{ $s{$_} } ] } keys %s };
}

sub plan ($self) {
    my $mode  = $self->_mode;
    my $model = $self->param('model');
    my $me    = $self->op_name;
    Odoo::Error->throw( kind => 'usage', message => "$me: model must be a physical model name (with a dot), got '$model'" )
        if $model !~ /\./;
    my ( $rec, $ids ) = ( $self->param('record'), $self->param('ids') );
    my $have_ids = $ids && @$ids;
    Odoo::Error->throw( kind => 'usage', message => "$me: give exactly one of record and ids" )
        if ( defined $rec ? 1 : 0 ) + ( $have_ids ? 1 : 0 ) != 1;
    my @bad = $have_ids ? grep { !/^\d+\z/ } @$ids : ();
    Odoo::Error->throw( kind => 'usage', message => "$me: ids must be whole numbers, got '$bad[0]'" ) if @bad;

    my $m = eval { $self->client->model($model) };
    my $fields = eval { $m->fields } || Odoo::Ops::Modules->absent_model( $self->ctx, $me, $model, $@ );
    my $has_active = $fields->{active} ? 1 : 0;
    my @read       = ( 'id', 'display_name', ( $has_active ? ('active') : () ) );
    my $all        = { active_test => JSON::PP::false };

    my ( @want, $found );    # @want: [key, label] for each record asked for
    if ($have_ids) {
        my %seen;
        my @u = grep { !$seen{$_}++ } map { 0 + $_ } @$ids;
        @want  = map { [ $_ ] } @u;
        $found = $m->search_read( [ [ 'id', 'in', \@u ] ], \@read, context => $all );
    }
    elsif ( $rec =~ /^\s*(\d+)\s*\z/ ) {
        @want  = ( [ 0 + $1 ] );
        $found = $m->search_read( [ [ 'id', '=', 0 + $1 ] ], \@read, context => $all );
    }
    elsif ( my ( $f, $val ) = $rec =~ /^(\w+)=(.*)\z/s ) {
        Odoo::Error->throw( kind => 'usage', message => "$me: $model has no field '$f'",
            fix => "oom-ops run core.skeleton --conf <conf> --set model=$model lists the fields" ) if !$fields->{$f};
        $found = $m->search_read( [ [ $f, '=', $val ] ], \@read, limit => 6, context => $all );
        Odoo::Error->throw( kind => 'usage', message => "$me: $rec matches $model records " . join( ', ', map { $_->{id} } @$found ),
            fix => "pass --set ids=" . join( ',', map { $_->{id} } @$found ) . ' (the ones to ' . ( $mode->{bucket} ) . ')' ) if @$found > 1;
        @want = $found->[0] ? ( [ $found->[0]{id} ] ) : ( [ undef, $rec ] );
    }
    else {
        Odoo::Error->throw( kind => 'usage', message => "$me: record '$rec' is neither an id nor field=value" );
    }
    my %by_id = map { $_->{id} => $_ } @$found;

    my $plan = $self->new_plan( input_count => scalar @want );
    for my $w (@want) {
        my ( $id, $label ) = @$w;
        my $key = "$model:" . ( $id // $label );
        my $row = defined $id ? $by_id{$id} : undef;
        if ( !$row ) {
            $plan->add( bucket => 'unknown-record', action => 'hold', key => $key,
                reason => "$me: no $model " . ( defined $id ? "has id $id" : "matches $label" ) );
            next;
        }
        my $name = defined $row->{display_name} && !ref $row->{display_name} && length $row->{display_name} ? " ($row->{display_name})" : '';
        my $what = "$model $id$name";
        if ( !$has_active ) {
            $plan->add( bucket => 'no-active-field', action => 'hold', key => $key, id => $id, model => $model,
                reason => "$what: $model has no active field, so there is nothing to " . $mode->{bucket} );
            next;
        }
        my $now = $row->{active} ? 1 : 0;
        if ( $now == $mode->{to} ) {
            $plan->add( bucket => 'already', action => 'hold', key => $key, id => $id, model => $model,
                reason => "$what is " . ( $mode->{to} ? 'active' : 'archived' ) . ' already' );
            next;
        }
        $plan->add(
            bucket => $mode->{bucket}, action => 'custom', handler => $me, kind => $mode->{bucket}, key => $key, id => $id, model => $model,
            before => { active => $now },
            vals   => { method => $mode->{method}, to => $mode->{to}, name => ( $row->{display_name} // '' ) },
            line   => "$what: " . ( $now ? 'active' : 'archived' ) . ' -> ' . ( $mode->{to} ? 'active' : 'archived' ),
            reason => "$what goes from " . ( $now ? 'active' : 'archived' ) . ' to ' . ( $mode->{to} ? 'active' : 'archived' )
                . " through $mode->{method} (active is not written)",
        );
    }
    return $plan;
}

=head2 apply_custom($class, $client, $change)

Calls the change's method (C<action_archive> or C<action_unarchive>) on the
record and reads C<active> back; the change is verified when it reads as the
plan said, and unverified (C<after> undef) when it does not.

=cut

sub apply_custom ($class, $client, $c) {
    Odoo::Error->throw( kind => 'usage', message => "$c->{handler} cannot apply kind '" . ( $c->{kind} // '' ) . "'" )
        if ( $c->{kind} // '' ) !~ /\A(?:archive|unarchive)\z/;
    my $v = $c->{vals};
    Odoo::Error->throw( kind => 'usage', message => "$c->{handler}: the change names no method" )
        if ref $v ne 'HASH' || $v->{method} !~ /\A(?:action_archive|action_unarchive)\z/;
    $client->execute_kw( $c->{model}, $v->{method}, [ [ $c->{id} ] ] );
    my $row = $client->model( $c->{model} )->read( [ $c->{id} ], ['active'] )->[0]
        or return { id => $c->{id}, after => undef };
    my $now = $row->{active} ? 1 : 0;
    return { id => $c->{id}, returned => { active => $now, ran => $v->{method} }, after => $now == $v->{to} ? { active => $now } : undef };
}

=head2 undo_custom($class, $entry)

A done change is taken back by the opposite action: C<action_unarchive> for an
archive, C<action_archive> for an unarchive. A change that was not verified
has no state to take back from and is held.

=cut

sub undo_custom ($class, $entry) {
    return ( undef, "$entry->{handler} cannot undo kind '" . ( $entry->{kind} // '' ) . "'" ) if ( $entry->{kind} // '' ) !~ /\A(?:archive|unarchive)\z/;
    my $v   = $entry->{vals} // {};
    my $ret = ref $entry->{returned} eq 'HASH' ? $entry->{returned} : {};
    return ( undef, 'the change was not verified (active did not read back as planned), so there is no state to take back from' )
        if !defined $ret->{active} || $ret->{active} != $v->{to};
    my $back = $class->_opposite;
    $UNDO_MODELS{ $entry->{model} } = 1;
    my $now = $ret->{active};
    my $to  = $back->{to};
    return {
        action => 'custom', handler => $back->{op}, kind => $back->{bucket}, bucket => 'undo-' . $back->{bucket},
        model => $entry->{model}, id => $entry->{id}, key => "undo:$entry->{model} $entry->{id}",
        before => { active => $now },
        vals   => { method => $back->{method}, to => $to, name => $v->{name} // '' },
        line   => "$entry->{model} $entry->{id}" . ( length( $v->{name} // '' ) ? " ($v->{name})" : '' ) . ': ' . ( $now ? 'active' : 'archived' ) . ' -> ' . ( $to ? 'active' : 'archived' ),
        reason => "$entry->{model} $entry->{id} goes from " . ( $now ? 'active' : 'archived' ) . ' to ' . ( $to ? 'active' : 'archived' ) . " through $back->{method}",
    };
}

# the opposite class's mode, with its operation name
sub _opposite ($class) {
    my $op = $class->_mode->{opposite};
    require Odoo::Ops::Core::Unarchive;
    my $o = $op eq 'core.unarchive' ? 'Odoo::Ops::Core::Unarchive' : 'Odoo::Ops::Core::Archive';
    return { %{ $o->_mode }, op => $op };
}

1;
