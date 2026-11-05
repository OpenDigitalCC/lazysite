package Odoo::Ops::Core::Make;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();
use Odoo::Error;
use Odoo::JSON ();
use Odoo::Ops::Modules;
use Odoo::Ops::Core::Import;
use Odoo::Ops::Core::OneRecord;
use Odoo::Ops::File;
use Odoo::Ops::Quiet ();

use parent 'Odoo::Ops::Operation';

use constant MAX_LINES => 200;

=head1 NAME

Odoo::Ops::Core::Make - create one record, its fields typed from fields_get

=head1 SYNOPSIS

    oom-ops run core.make --conf ops.conf --set model=crm.lead --set set.name='Expo enquiry' --set set.type=opportunity
    oom-ops run core.make --conf ops.conf --set model=sale.order --set set.partner_id=7 \
        --set 'lines.order_line=[{"product_id":3,"product_uom_qty":2},{"product_id":4,"product_uom_qty":1}]'
    oom-ops apply --conf ops.conf --plan <run>/plan.json

=head1 DESCRIPTION

C<core.make> creates one record. The parameters are C<model> and one
C<set.E<lt>fieldE<gt>> per field, typed as C<core.set> types them (see
L<Odoo::Ops::Core::Set>; a many2many takes ids or names, and C<[]> makes it empty,
which overrides what Odoo would default). The plan holds one C<create> change. A required,
stored field that the pairs do not set, that C<default_get> gives no value and
that Odoo does not fill itself is a usage error at plan naming every such field.
Odoo fills a required field when it has a default, when it computes the stored field at
create (a field with C<depends>), or, for a model that delegates to another
(C<hr.employee> and its C<resource_id>), makes the record the field points at: other
fields of the model are C<related> to it. The plan names those fields in a note
(C<left for Odoo to fill: resource_id (...)>) and does not ask for them.

The apply creates the record once, reads the fields back, journals the
change and names the record (C<created: crm.lead: 41>, and C<made: crm.lead 41>
on the C<oom-ops apply> screen); C<revert> removes it. Nothing about the new
record is guessed: a field the pairs leave out is Odoo's default, and a lead
made this way is judged by no rule of the CRM pack (its
C<probability-manual> invariant judges the pack's own writes).

A pair for a state field of a model whose state Odoo changes through its own
action is held C<state-field>, as C<core.set> holds it.

C<quiet> (default off) sends the quiet context: the shared one of
L<Odoo::Ops::Quiet> (no tracking, no "created" message, no follower, no assignment
mail) joined with the C<suppress: { context: ... }> that the model's behaviour file
records for a create of the fields set. For C<mail.activity> that adds
C<mail_activity_quick_update>, so Odoo does not email the assignee. The plan line
names the keys sent and the effect they silence; when no recorded effect applies
to the fields set it says so, and the shared context is sent all the same (it
does no harm). C<core.set> and C<core.action> take the same option by the same
rule. A create that is not quiet and has a recorded effect says that Odoo mails
and how to stop it.

A binary field takes a file: C<set.E<lt>fieldE<gt>> is a file value (C<< { name,
bytes, mimetype? } >>, see L<Odoo::Ops::File>) in a program, and
C<--file set.E<lt>fieldE<gt>=PATH> on the command line. The plan shows the name,
size, SHA-256 and type; the bytes wait in the run's blob store and are checked
by digest at apply. The create's read-back leaves the file's content out, so the
journal holds none.

C<lines.E<lt>fieldE<gt>> creates the record with the lines of a one2many field
in the same create: a JSON array of flat objects (at most 200 rows), or
--rows lines.order_line=FILE. The field must be a one2many of the model and
every key of a row a field of the comodel (C<fields_get> of both is read at
plan); each value is typed as a C<set.> value of that field is. A usage error
names the row number and the key. The plan line counts the lines; the apply
sends them as one create with Odoo's own (0, 0, vals) commands, reads the
lines' ids back, and C<revert> removes the record, which removes its lines. The
lines' own required fields and rules are Odoo's to refuse, with its words.

=cut

sub op_name ($class) { 'core.make' }
sub summary ($class) { 'Plan creating one record, each set.<field> typed from fields_get; required fields without a default are refused by name' }
sub pack    ($class) { undef }
sub params ($class) {
    {   model         => { type => 'str', required => 1, help => 'physical model, e.g. crm.lead' },
        quiet         => { type => 'bool', default => 0, help => 'send the quiet context (no tracking, no chatter, no assignment mail) and whatever the behaviour file records as silencing this create (mail.activity: mail_activity_quick_update); the plan names the keys and the effect, or says no recorded effect applies' },
        'set.<field>' => { type => 'str', help => 'one per field of the new record: --set set.name=Acme --set set.type=opportunity (the value is typed from fields_get); a binary field takes a file: --file set.image_1920=PATH' },
        'lines.<field>' => { type => 'rows', max => MAX_LINES, row => 'the fields of the one2many\'s comodel', help => 'one per one2many field: --set lines.order_line=\'[{"product_id":3,"product_uom_qty":2}]\' or --rows lines.order_line=FILE; a flat object per line, its keys fields of the comodel, typed from fields_get' },
    };
}
sub check_params ($class, $raw) {
    my $set  = Odoo::Ops::Core::OneRecord->set_params( $class->op_name, $raw );
    my %rest = map { $_ => $raw->{$_} } grep { !/\A(?:set|lines)\./ } keys %$raw;
    my $out  = $class->SUPER::check_params( \%rest );
    $out->{"set.$_"} = $set->{$_} for keys %$set;
    for my $k ( sort grep { /\Alines\./ } keys %$raw ) {
        $out->{$k} = $class->_lines( $k, $raw->{$k} );
    }
    return $out;
}

# lines.<field>: a JSON array of flat objects, checked by the shared rows rule
# (the keys are the comodel's fields, known only at plan, so each row may hold
# any word key here; a JSON true or false is 1 or 0)
sub _lines ($class, $k, $v) {
    my $f = substr $k, 6;
    Odoo::Error->throw( kind => 'usage', message => "core.make: parameter '$k' names no field",
        fix => 'give lines.<field>=<rows>, e.g. --set lines.order_line=\'[{"product_id":3,"product_uom_qty":2}]\'' ) if $f !~ /\A\w+\z/;
    my $rows = ref $v ? $v : eval { Odoo::Ops::json()->decode( $v // '' ) };
    my %keys;
    if ( ref $rows eq 'ARRAY' ) {
        $rows = [ map { my $r = $_; ref $r eq 'HASH' ? { map { $_ => ( Odoo::JSON::is_bool($r->{$_}) ? ( $r->{$_} ? 1 : 0 ) : $r->{$_} ) } keys %$r } : $r } @$rows ];
        for my $r (@$rows) {
            next if ref $r ne 'HASH';
            $keys{$_} = 'str?' for keys %$r;
        }
    }
    %keys = ( _ => 'str?' ) if !%keys;
    my @odd = grep { !/\A\w+\z/ } keys %keys;
    Odoo::Error->throw( kind => 'usage', message => "core.make: parameter '$k': '$odd[0]' is not a field name",
        fix => 'oom-ops describe core.make shows what lines.<field> takes' ) if @odd;
    return $class->check_rows( { type => 'rows', max => MAX_LINES, row => \%keys }, $rows, "core.make: parameter '$k'" );
}

sub buckets ($class) { [ { name => 'make', meaning => 'one record is created' } ] }
sub holds ($class) {
    [ { name => 'state-field', meaning => 'the pair sets the state of a model whose state Odoo changes through its own action; the operation that does it is named' } ];
}
sub read_scope  ($class) { {} }    # built per run from the model
sub write_scope ($class) { {} }
sub writes      ($class) { 1 }

sub scope_for ($self, $phase) {
    my $m = $self->param('model');
    return {} if !defined $m;
    return { $m => $phase eq 'apply' ? [qw(create read search_read)] : [qw(default_get search_read)] };
}

# a name in a many2many value is looked up as core.import looks it up, in the related model
sub _resolver ($self) {
    return sub ( $relation, $name ) {
        return $self->ctx->guard->with_scope( { %{ $self->scope_for('plan') }, $relation => ['search_read'] }, $self->op_name,
            sub { Odoo::Ops::Core::Import::lookup( $self, $relation, 'name', $name ) } );
    };
}

# fields Odoo fills itself, never asked of the caller
my %MAGIC = map { $_ => 1 } qw(id create_uid create_date write_uid write_date display_name __last_update);

sub plan ($self) {
    my $model = $self->param('model');
    Odoo::Error->throw( kind => 'usage', message => "core.make: model must be a model name such as res.partner or website, got '$model'" ) if !$self->is_model_name($model);
    my $all = $self->all_params;
    my $set = { map { substr( $_, 4 ) => $all->{$_} } grep { /\Aset\./ } keys %$all };
    my @line_keys = sort grep { /\Alines\./ } keys %$all;
    Odoo::Error->throw( kind => 'usage', message => 'core.make: no field to set', fix => 'give one or more --set set.<field>=<value>' ) if !%$set && !@line_keys;

    my $m = $self->client->model($model);
    my $f = eval { $m->fields } || Odoo::Ops::Modules->absent_model( $self->ctx, 'core.make', $model, $@ );
    my $vals = Odoo::Ops::Core::OneRecord->typed_values( 'core.make', $model, $f, $set, resolver => $self->_resolver );
    my @lines_shown;
    for my $k (@line_keys) {
        my $field = substr $k, 6;
        my $d = $f->{$field};
        Odoo::Error->throw( kind => 'usage', message => "core.make: $model has no field '$field'",
            fix => "oom-ops run core.skeleton --conf <conf> --set model=$model lists the fields" ) if !$d;
        Odoo::Error->throw( kind => 'usage', message => "core.make: $model.$field is a $d->{type} field, not a one2many; lines.$field does not apply",
            fix => ( $d->{type} =~ /\Amany2many\z/ ? "give it as set.$field, a list of ids or names" : "give it as set.$field" ) ) if $d->{type} ne 'one2many';
        Odoo::Error->throw( kind => 'usage', message => "core.make: $model.$field is given twice (set.$field and $k)", fix => "give it once" ) if exists $vals->{$field} || exists $set->{$field};
        my $relation = $d->{relation} or Odoo::Error->throw( kind => 'usage', message => "core.make: $model.$field names no comodel" );
        my $cf = eval { $self->client->model($relation)->fields } || Odoo::Ops::Modules->absent_model( $self->ctx, 'core.make', $relation, $@ );
        my $n = 0;
        my @cmds;
        for my $row ( @{ $all->{$k} } ) {
            $n++;
            Odoo::Error->throw( kind => 'usage', message => "core.make: $k row $n holds no key", fix => 'give each line at least one field of ' . $relation ) if !%$row;
            my $typed = eval { Odoo::Ops::Core::OneRecord->typed_values( 'core.make', $relation, $cf, $row, resolver => $self->_resolver ) };
            if ( my $e = $@ ) {
                die $e if !ref $e || !$e->isa('Odoo::Error');
                ( my $why = $e->message ) =~ s/\Acore\.make: //;
                Odoo::Error->throw( kind => $e->kind, message => "core.make: $k row $n: $why", fix => $e->fix );
            }
            push @cmds, [ 0, 0, $typed ];
        }
        $vals->{$field} = \@cmds if @cmds;
        push @lines_shown, "$field " . scalar(@cmds) . ' line' . ( @cmds == 1 ? '' : 's' ) . " of $relation" if @cmds;
    }

    my $plan = $self->new_plan( input_count => 1 );
    my $key  = "$model:new";
    if ( my $why = Odoo::Ops::Core::OneRecord->state_hold( $self->ctx, $model, $vals ) ) {
        $plan->add( bucket => 'state-field', action => 'hold', key => $key, model => $model, reason => $why );
        return $plan;
    }
    # a file's bytes are held in the plan's blob store; the plan shows its name, size, digest and type
    my ( @file_fields, %file_shown );
    for my $n ( sort grep { Odoo::Ops::File->is_value( $vals->{$_} ) } keys %$vals ) {
        my $s = Odoo::Ops::File->slim( $vals->{$n} );
        $file_shown{$n} = "$s->{name} ($s->{bytes} bytes, sha256 $s->{sha256}, $s->{mimetype})";
        $vals->{$n} = $plan->blob_value( Odoo::Ops::File->base64( $vals->{$n} ) );
        push @file_fields, $n;
    }
    # a required, stored field that nothing gives a value: Odoo would refuse the create, and says which only one at a time.
    # A required field is not missing when Odoo fills it: a default (default_get), a stored field it computes at create
    # (sale.order's pricelist_id from its partner: it names what it depends on), or the record a delegating model makes
    # with its own (hr.employee's resource_id: other fields of the model are related to it). Those are named in the plan.
    my @required = grep { !$MAGIC{$_} && !exists $vals->{$_} && $f->{$_}{required} && ( $f->{$_}{store} // 1 ) && !$f->{$_}{readonly} } sort keys %$f;
    my %filled;
    if (@required) {
        my $defaults = eval { $m->default_get( \@required ) };
        $defaults = {} if ref $defaults ne 'HASH';
        $filled{$_} = 'its default' for grep { exists $defaults->{$_} } @required;
        @required = grep { !exists $defaults->{$_} } @required;
        if (@required) {
            my $meta = eval { $self->client->execute_kw( $model, 'fields_get', [], { attributes => [ 'depends', 'related' ] } ) };
            $meta = {} if ref $meta ne 'HASH';
            my @rest;
            for my $n (@required) {
                my $dep = $meta->{$n}{depends};
                if ( ref $dep eq 'ARRAY' && @$dep ) { $filled{$n} = 'computed by Odoo when the record is made'; next }
                if ( ( $f->{$n}{type} // '' ) eq 'many2one' && grep { ( $meta->{$_}{related} // '' ) =~ /\A\Q$n\E\./ } keys %$meta ) {
                    $filled{$n} = "the record Odoo makes with this one (fields of $model are read through it)";
                    next;
                }
                push @rest, $n;
            }
            # a required one2many that is the inverse of the record a delegating model makes (hr.employee on 19: version_ids,
            # the versions whose version_id the employee delegates to). Odoo makes that record and points its inverse field
            # back in the same create, so the one2many is filled without being asked for.
            my @still;
            for my $n (@rest) {
                my $d = $f->{$n};
                my $via;
                if ( ( $d->{type} // '' ) eq 'one2many' ) {
                    # the delegate is the candidate most fields are read through
                    my ( $best, $most ) = ( undef, 0 );
                    for my $cand ( sort keys %$f ) {
                        next if ( $f->{$cand}{type} // '' ) ne 'many2one' || ( $f->{$cand}{relation} // '' ) ne ( $d->{relation} // "\0" );
                        my $count = grep { ( $meta->{$_}{related} // '' ) =~ /\A\Q$cand\E\./ } keys %$meta;
                        ( $best, $most ) = ( $cand, $count ) if $count > $most;
                    }
                    $via = $best;
                }
                if ( defined $via ) { $filled{$n} = "the $d->{relation} records Odoo makes with this one, through $via" }
                else { push @still, $n }
            }
            @rest = @still;
            @required = @rest;
        }
    }
    Odoo::Error->throw( kind => 'usage',
        message => "core.make: $model needs " . join( ', ', @required ) . ' (required, and Odoo gives no default)',
        fix => 'add ' . join( ' ', map { "--set set.$_=..." } @required ) ) if @required;
    $plan->note( 'left for Odoo to fill: ' . join( '; ', map { "$_ ($filled{$_})" } sort keys %filled ) ) if %filled;

    # quiet: the shared quiet context plus what the behaviour file records as silencing this create (Odoo::Ops::Quiet)
    my $quiet = $self->param('quiet');
    my $q     = Odoo::Ops::Quiet::quiet_for( $self->ctx->behaviour($model), 'create', [ keys %$vals ] );
    my $qnote = $quiet ? "; $q->{words}"
        : @{ $q->{effects} } ? "; not quiet: $q->{effects}[0] (--set quiet=1 sends " . join( ', ', @{ $q->{keys} } ) . ')' : '';

    my @line = ( ( map { "$_ " . ( $file_shown{$_} // Odoo::Ops::Core::OneRecord->shown( $vals->{$_}, $f->{$_}{type} ) ) } grep { ( $f->{$_}{type} // '' ) ne 'one2many' } sort keys %$vals ), @lines_shown );
    my %is_file = map { $_ => 1 } @file_fields;
    $plan->add(
        bucket => 'make', action => 'create', key => $key, model => $model, vals => $vals,
        ( @file_fields ? ( readback => [ grep { !$is_file{$_} } sort keys %$vals ] ) : () ),
        ( $quiet ? ( context => $q->{context} ) : () ),
        line   => "$model new: " . join( '; ', @line ) . $qnote, reason => "creates one $model" . ( $quiet ? ', quiet' : '' ),
    );
    return $plan;
}

1;
