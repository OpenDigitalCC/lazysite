package Odoo::Ops::Operation;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Error;
use Odoo::JSON ();
use Odoo::Ops::Acting;
use Odoo::Ops;
use Odoo::Ops::Plan;
use Odoo::Ops::Invariant;
use Odoo::Ops::Modules;
use Odoo::Ops::Guard;
use Odoo::Ops::Registry;
use Odoo::Ops::File;
use Odoo::Ops::Rows;

=head1 NAME

Odoo::Ops::Operation - base class for named operations

=head1 SYNOPSIS

    package Odoo::Ops::CRM::Export;
    use parent 'Odoo::Ops::Operation';

    sub op_name    { 'crm.export' }
    sub summary    { 'Snapshot leads as JSON lines' }
    sub pack       { 'crm' }
    sub params     { { domain => { type => 'json', default => '[]' } } }
    sub read_scope { { lead => ['search_read'] } }

    sub report ($self) { ... return \%report }

=head1 DESCRIPTION

An operation declares, as class methods:

    op_name      dotted name, the handle the CLI, MCP and a lazysite
                 app use (SM747 OB2's named operation)
    summary      one line
    pack         the profile pack it speaks (crm, comms, ...), or undef
    invariant_packs  the packs whose invariants judge its writes (default: its pack)
    params       { name => { type, required, default, help } }
                 types: str int bool json list path rows file files (see check_rows,
                 and Odoo::Ops::File for file and files)
    read_scope   { model => [methods] } used while reporting/planning
    write_scope  { model => [methods] } added while applying; declaring
                 one makes the operation a write operation
    routes       [ '/web/path', ... ] the web routes its C<route> changes may call
                 (the guard holds apply to them); declaring one makes the
                 operation a write operation too
    buckets      [ { name, meaning } ] the buckets a plan of this operation
                 sorts rows into that are written or skipped (a write
                 operation declares it)
    holds        [ { name, meaning } ] the buckets whose rows wait for a
                 person, each with the cause in one line
    fields       [ { name, meaning } ] for a read: the keys of the
                 descriptors it returns in its C<fields> block
    immediate    true for an operation applied at once, never planned (it has no
                 plan, run folder or journal; core.credential), else false
    buckets_from 'dynamic' with a reason, for an operation whose bucket
                 names cannot be listed; no shipped operation needs it
    acts_for     true for an operation that acts for a person: its writes are made
                 with a service credential, scoped to the person the request's own
                 credential proves (see Odoo::Ops::Acting); else false

Scope keys are logical profile models (C<lead>) or, where a key
contains a dot, physical Odoo models (C<ir.module.module>). The guard
enforces them: a call outside the declared scope is refused before it
leaves.

A read operation implements C<report> and returns a hashref. A write
operation implements C<plan>, filling C<< $self->new_plan >> - running
it never writes; L<Odoo::Ops::Runner> applies the saved plan later.

=cut

sub op_name     ($class) { Odoo::Error->throw( kind => 'usage', message => "$class has no op_name" ) }
sub summary     ($class) { '' }
sub pack        ($class) { undef }

# The packs whose invariants this operation's writes are judged by: its own
# pack, plus any more an operation names to opt in to them.
sub invariant_packs ($class) { defined $class->pack ? ( $class->pack ) : () }
sub params      ($class) { {} }
sub read_scope  ($class) { {} }
sub write_scope ($class) { {} }
sub routes       ($class) { [] }
sub writes      ($class) { !!( %{ $class->write_scope } || @{ $class->routes } ) }
sub immediate   ($class) { 0 }
sub buckets     ($class) { [] }
sub holds       ($class) { [] }
sub fields      ($class) { [] }
sub buckets_from ($class) { undef }
sub acts_for    ($class) { 0 }

=head2 undo_custom($journal_entry)

Optional class method of an operation that plans C<custom> changes: what
C<oom-ops revert> calls for one done change of its handler. It returns the
opposite change to plan (a C<custom> change of the same handler, or a plain
write, create or unlink), or C<(undef, $reason)> for a change it cannot undo,
which the revert plan then holds as C<irreversible> with that reason. An
operation that defines no C<undo_custom> says so: the plan line of each of its
custom changes ends C<revert: none>, and a revert holds the change as
irreversible, naming the operation.

=head2 models_touched($change)

Class method: the physical models a C<custom> change of this operation
writes, so the invariants of each are checked around the apply. The
default is the change's own model; an operation whose handler writes
more (a transfer moves quants) names them.

=cut

sub models_touched ($class, $change) { grep { defined } $change->{model} }

sub new ($class, %args) {
    my $ctx = $args{ctx} or Odoo::Error->throw( kind => 'usage', message => 'operation needs ctx' );
    my $self = bless { ctx => $ctx, params => $class->check_params( $args{params} // {} ) }, $class;
    return $self;
}

sub ctx    ($self) { $self->{ctx} }
sub client ($self) { $self->{ctx}->client }
sub param  ($self, $name) { $self->{params}{$name} }
sub all_params ($self) { $self->{params} }

=head2 person, service_client, own

For an operation that declares C<acts_for> only (any other dies C<usage>; the pack lint refuses the
words in a file that declares no C<acts_for>). L<Odoo::Ops::Acting> says how each is made.

C<< $self->person >> is the verified identity of the one the request is for, C<< { uid, login, name,
partner_id, commercial_partner_id } >>. It has no source but Odoo's answer to the request's own credential.

C<< $self->service_client >> is the client of the service credential, for the writes and for the reads the
person may not make; C<< $self->client >> stays the person's own.

C<< $self->own( model =E<gt> M, ids =E<gt> [...], field =E<gt> 'partner_id' ) >> returns the ids when every record's
C<field> is the person's partner or commercial partner, else dies C<refused/not-yours> naming the model and
ids (and nothing of another customer). A pack calls it before any write to a record the person names.

=cut

sub _need_acts_for ($self, $what) {
    Odoo::Error->throw( kind => 'usage', message => $self->op_name . " does not declare acts_for, so it has no $what",
        fix => 'an operation that acts for a person declares sub acts_for { 1 }' ) if !$self->acts_for;
    return;
}

sub person ($self) { $self->_need_acts_for('person'); return $self->{ctx}->person }
sub service_client ($self) { $self->_need_acts_for('service client'); return $self->{ctx}->service_context->client }
sub own ($self, %a) { $self->_need_acts_for('own'); return Odoo::Ops::Acting->own( $self, %a ) }

sub profile ($self) {
    my $pack = $self->pack
        or Odoo::Error->throw( kind => 'usage', message => $self->op_name . ' has no profile pack' );
    return $self->{ctx}->profile($pack);
}

# Odoo::Model for a logical (profile) or physical (dotted) model name.
sub model ($self, $name) {
    return $self->client->model( $self->physical_model($name) );
}

=head2 is_model_name($name)

True when C<$name> has the shape of an Odoo model name: lower case letters, digits and C<_>, in segments
joined by dots, the first starting with a letter. A model without a dot (C<website>) is a model; whether
this server has it is Odoo's answer (C<fields_get>, then L<Odoo::Ops::Modules/absent_model>), as for any other.

=cut

sub is_model_name ($class, $name) { return defined $name && !ref $name && $name =~ /\A[a-z][a-z0-9_]*(?:\.[a-z0-9_]+)*\z/ ? 1 : 0 }

# a logical (profile) name has no dot, so for an operation of a pack a name without a dot is a profile's; an
# operation of no pack has no profile, and every name it is given is a physical model
sub physical_model ($self, $name) {
    return $name if $name =~ /\./ || !defined $self->pack;
    return $self->profile->model_name($name);
}

=head2 check_params(\%raw)

Class method: validated, defaulted, typed params. Unknown names and
missing required ones are refused by name.

=cut

sub check_params ($class, $raw) {
    my $spec = $class->params;
    my %out;
    for my $k ( keys %$raw ) {
        Odoo::Error->throw(
            kind    => 'usage',
            message => $class->op_name . ": unknown parameter '$k' (known: "
                . join( ', ', sort keys %$spec ) . ')',
            fix     => 'oom-ops describe ' . $class->op_name . ' lists the parameters',
        ) if !$spec->{$k};
    }
    for my $k ( sort keys %$spec ) {
        my $s = $spec->{$k};
        my $v = exists $raw->{$k} ? $raw->{$k} : $s->{default};
        if ( !defined $v ) {
            Odoo::Error->throw( kind => 'usage', message => $class->op_name . ": parameter '$k' is required",
                fix => "pass it with --set $k=...; oom-ops describe " . $class->op_name . ' says what it takes' )
                if $s->{required};
            next;
        }
        $out{$k} = _typed( $class->op_name, $k, $s->{type} // 'str', $v, $s );
    }
    return \%out;
}

sub _typed ($op, $k, $type, $v, $spec = {}) {
    my $bad = sub { Odoo::Error->throw( kind => 'usage', message => "$op: parameter '$k' must be $type", fix => "oom-ops describe $op shows each parameter's type" ) };
    return Odoo::Ops::Operation->check_rows( $spec, $v, "$op: parameter '$k'" ) if $type eq 'rows';
    return Odoo::Ops::File->check( $op, $k, $v, $spec ) if $type eq 'file';
    return Odoo::Ops::File->check_list( $op, $k, $v, $spec ) if $type eq 'files';
    return $v if ref $v && $type =~ /^(json|list)\z/;
    if ( $type eq 'int' )  { $v =~ /^-?\d+\z/ or $bad->(); return 0 + $v }
    if ( $type eq 'bool' ) { $v =~ /^(1|0|yes|no|true|false)\z/i or $bad->(); return $v =~ /^(1|yes|true)\z/i ? 1 : 0 }
    if ( $type eq 'json' ) { my $d = eval { Odoo::Ops::json()->decode($v) }; defined $d or $bad->(); return $d }
    if ( $type eq 'list' ) { return [ grep { length } split /\s*,\s*/, $v ] }
    if ( $type eq 'path' || $type eq 'str' ) { return "$v" }
    Odoo::Error->throw( kind => 'usage', message => "$op: parameter '$k' has unknown type '$type'" );
}

=head2 check_rows($decl, $value, $label)

Class method: the rule of a C<rows> parameter, kept in L<Odoo::Ops::Rows>
(C<< Odoo::Ops::Rows->check >>), which loads no other part of OOM, so a caller
can run it before it sends without the cost of the registry. See there for the
declaration and the rules.

=cut

sub check_rows ($class, $decl, $value, $label = 'rows') {
    return Odoo::Ops::Rows->check( $decl, $value, $label );
}

=head2 scope_for($phase)

The physical scope for C<read> (reporting/planning) or C<apply> (read
plus write scope, plus C<read> on every written model so the runner
can check before-images and read results back).

=cut

sub scope_for ($self, $phase) {
    my %s;
    my $add = sub ($decl) {
        for my $m ( keys %$decl ) {
            $s{ $self->physical_model($m) }{$_} = 1 for @{ $decl->{$m} };
        }
    };
    $add->( $self->read_scope );
    if ( $phase eq 'apply' ) {
        $add->( $self->write_scope );
        $s{ $self->physical_model($_) }{read} = 1 for keys %{ $self->write_scope };
        $s{'web.route'}{$_} = 1 for @{ $self->routes };
    }
    return { map { $_ => [ sort keys %{ $s{$_} } ] } keys %s };
}

=head2 run

Runs C<report> or C<plan> under the read scope. Returns the report
hashref, or the finalized L<Odoo::Ops::Plan> carrying its apply scope. An
operation of a pack is refused C<refused/not-applicable> first when the pack's
module (C<module:> of its profile) is not installed on the server.

=cut

=head2 fields_for($logical_model, @logical_fields)

The descriptors of the named logical fields (all mapped fields when
none are named), keyed by logical name, with their portable types -
what a display read returns beside its C<rows> so a consumer can draw
them without Odoo knowledge. Validates the profile on first use.

=cut

sub fields_for ($self, $lm, @lf) {
    my $p = $self->profile;
    $p->validate( $self->client ) if !$p->validated;
    my $all = $p->descriptors($lm);
    @lf = sort keys %$all if !@lf;
    return { map { $_ => $all->{$_} } grep { $all->{$_} } @lf };
}

# A usage error an operation raises about its own parameters carries the
# same fix as the registry's: the describe output is the fix, so a caller
# never has to guess. An error that already names its fix keeps it.
sub run ($self) {
    my @r = eval { wantarray ? $self->_run : scalar $self->_run };
    if ( my $e = $@ ) {
        if ( ref $e && eval { $e->isa('Odoo::Error') } && $e->kind eq 'usage' && !defined $e->fix ) {
            $e->{fix} = 'oom-ops describe ' . $self->op_name . ' lists the parameters';
        }
        die $e;
    }
    return wantarray ? @r : $r[0];
}

# A read reported: the models it may read and how many rows came back, counts only
# (the audit trail never holds a value).
sub _audit_read ($self, $scope, $report) {
    my $trail = $self->{ctx}->can('trail') ? $self->{ctx}->trail : undef;
    return if !$trail;
    my $rows = ref $report eq 'HASH' ? $report->{rows} : $report;
    eval {
        $trail->event( read =>
            op => $self->op_name, outcome => 'ok',
            models => [ sort keys %$scope ],
            ( ref $rows eq 'ARRAY' ? ( rows => scalar @$rows ) : () ),
            ( $self->can('audit_detail') ? $self->audit_detail($report) : () ),
            # whether the answer came from the data cache and how old it was, never the data
            ( $self->_cache_says($report) ),
            params => [ sort keys %{ $self->{params} // {} } ],
        );
    };
    return;
}

# cached and age of a read: its own report's, else those of the reads it composed (Odoo::Ops::Pack->read)
sub _cache_says ($self, $report) {
    my $s = ref $report eq 'HASH' && defined $report->{cached} ? $report : $self->{cache_note};
    return () if !$s || !defined $s->{cached};
    return ( cached => $s->{cached} ? 1 : 0, ( $s->{cached} && defined $s->{age} ? ( age => $s->{age} ) : () ) );
}

sub _run ($self) {
    return Odoo::Ops::Acting->around( $self, sub { $self->_run_scoped } ) if $self->acts_for;
    return $self->_run_scoped;
}

sub _run_scoped ($self) {
    my $scope = $self->scope_for('read');
    return $self->{ctx}->guard->with_scope( $scope, $self->op_name, sub {
        # an operation of a pack whose module this server lacks is not applicable here; that is said before anything else
        Odoo::Ops::Modules->gate_pack( $self->{ctx}, $self->op_name, $self->pack ) if defined $self->pack;
        if ( !$self->writes ) {
            my $report = $self->report;
            $self->_audit_read( $scope, $report );
            return $report;
        }
        my $plan = $self->plan;    # unfinalized; sealed here with its scope
        $self->annotate_effects($plan);
        # the invariants of the models the plan writes are read around the apply
        my $scope = $self->scope_for('apply');
        my @inv = Odoo::Ops::Invariant->for_plan( $self->{ctx}, $plan );
        Odoo::Ops::Invariant->add_scope( $scope, @inv );
        $self->check_plan_scope( $plan, $scope );
        $self->mark_irreversible($plan);
        $plan->note( 'invariants checked at apply: ' . join( ', ', map { "$_->{name} ($_->{model})" } @inv ) ) if @inv;
        if ( my $a = $plan->acts_for ) {
            $plan->note( "acts for $a->{login} (uid $a->{uid}); the service login $a->{via} applies it, and only $a->{login} may apply it" );
        }
        $plan->set_scope($scope);
        return $plan->finalize;
    } );
}

=head2 plan_calls($plan)

The (model, method) pairs the plan's changes will call at apply, as
C<< { "model.method" => [seq, ...] } >> with the change numbers that need each,
and the handlers of the C<custom> changes that declare no C<calls>. A create
is C<create> and the C<read> of its read-back (and C<search_read> when it has a
C<unique_by>); a write is C<write> and C<read> (the before-image check and the
read-back); an unlink is C<unlink> and C<read>; a call is its method (and
C<read> when it has a before-image, and on the model a C<verify> reads); a
custom change is what it declares in C<calls> (C<< [[model, method], ...] >>).
A hold or a skip calls nothing.

=cut

sub plan_calls ($class, $plan) {
    my ( %need, %undeclared );
    for my $c ( @{ $plan->changes } ) {
        my $a = $c->{action};
        next if $a eq 'hold' || $a eq 'skip' || !defined $c->{model};
        my @pairs;
        if    ( $a eq 'create' ) { @pairs = ( [ $c->{model}, 'create' ], [ $c->{model}, 'read' ], ( $c->{unique_by} ? [ $c->{model}, 'search_read' ] : () ) ) }
        elsif ( $a eq 'write' )  { @pairs = ( [ $c->{model}, 'write' ], [ $c->{model}, 'read' ] ) }
        elsif ( $a eq 'unlink' ) { @pairs = ( [ $c->{model}, 'unlink' ], [ $c->{model}, 'read' ] ) }
        elsif ( $a eq 'call' ) {
            @pairs = ( [ $c->{model}, $c->{method} ] );
            push @pairs, [ $c->{model}, 'read' ] if ref $c->{before} eq 'HASH' && $c->{id};
            push @pairs, [ $c->{verify}{model}, 'read' ] if ref $c->{verify} eq 'HASH' && defined $c->{verify}{model};
        }
        elsif ( $a eq 'route' ) {
            # the path is held to the declared routes in check_plan_scope; a precondition and a verify are reads
            @pairs = map { [ $_->{model}, 'read' ] } grep { ref $_ eq 'HASH' && defined $_->{model} } @{$c}{qw(precondition verify)};
        }
        elsif ( $a eq 'custom' ) {
            if ( ref $c->{calls} eq 'ARRAY' ) { @pairs = map { [ @$_ ] } @{ $c->{calls} } }
            else                              { $undeclared{ $c->{handler} } = 1 }
        }
        push @{ $need{ "$_->[0].$_->[1]" } }, $c->{seq} for @pairs;
    }
    return ( \%need, [ sort keys %undeclared ] );
}

=head2 check_plan_scope($plan, \%scope)

Refuses at plan time, as C<refused/scope>, a plan whose changes will call a
(model, method) pair outside the scope apply will run under (the operation's
declared scope, the reads of the invariants, and the calls every scope
allows), naming each pair and the changes that need it. A C<custom> change that
declares no C<calls> cannot be checked now; the plan says so in a note and the
guard checks it at apply.

=cut

sub check_plan_scope ($self, $plan, $scope) {
    my ( $need, $undeclared ) = $self->plan_calls($plan);
    my @out;
    for my $c ( grep { $_->{action} eq 'route' } @{ $plan->changes } ) {
        next if grep { $_ eq $c->{path} } @{ $scope->{'web.route'} // [] };
        push @out, "route $c->{path} (change $c->{seq})";
    }
    for my $k ( sort keys %$need ) {
        my ( $model, $method ) = $k =~ /\A(.+)\.([^.]+)\z/;
        next if Odoo::Ops::Guard->base_allows( $model, $method );
        next if grep { $_ eq $method } @{ $scope->{$model} // [] };
        my @seq = @{ $need->{$k} };
        push @out, "$k (change" . ( @seq > 1 ? 's' : '' ) . ' ' . join( ', ', @seq[ 0 .. ( $#seq < 4 ? $#seq : 4 ) ] ) . ( @seq > 5 ? ' and ' . ( @seq - 5 ) . ' more' : '' ) . ')';
    }
    Odoo::Error->throw(
        kind    => 'refused',
        code    => 'scope',
        message => 'the plan of ' . $self->op_name . ' will call ' . join( '; ', @out ) . ', which the operation does not declare',
        fix     => 'declare each call in the operation\'s read_scope or write_scope (a model it writes also gets read); a custom change lists its calls in calls => [[model, method], ...]; a route change\'s path goes in routes => [...]',
    ) if @out;
    $plan->note( 'scope checked at apply for ' . join( ', ', @$undeclared ) . ' (a custom change that declares no calls)' ) if @$undeclared;
    return;
}

=head2 mark_irreversible($plan)

A C<custom> change is undone by what its operation's C<undo_custom> returns.
The plan line of a custom change whose operation has none ends
C<revert: none>, so a person approving the plan knows C<oom-ops revert> will
hold it as C<irreversible>. A change with no line of its own gets one.

=cut

sub mark_irreversible ($self, $plan) {
    my %can;
    for my $c ( @{ $plan->changes } ) {
        next if $c->{action} ne 'custom' || !$c->{handler};
        $can{ $c->{handler} } //= do {
            my $h = eval { Odoo::Ops::Registry->new->class_for_handler( $c->{handler} ) };
            $h && $h->can('undo_custom') ? 1 : 0;
        };
        next if $can{ $c->{handler} };
        $c->{line} = ( defined $c->{line} && length $c->{line} ? "$c->{line}; " : ( $c->{kind} // 'custom' ) . ( defined $c->{key} ? " $c->{key}: " : ': ' ) ) . 'revert: none';
    }
    return;
}

=head2 annotate_effects($plan)

What each planned change will make Odoo do beside the values, from
the model's behaviour file (L<Odoo::Ops::Behaviour>). The effects are
stated once per model on the plan (C<< $plan->effects >>: C<< { model =>
[ { effect, evidence, requires?, changes, suppressed } ] } >>, where
C<changes> counts the planned changes that trigger the effect and
C<suppressed> those whose context suppresses it) and each change carries
only C<< effects_ref => model >>. A plan note counts the effects that
stand, so the person approving sees the consequences without reading
every row. The seal covers what the plan will do, not the commentary on
it: neither C<effects_ref> nor the plan-level block is part of the
fingerprint.

=cut

sub annotate_effects ($self, $plan) {
    my ( $standing, $suppressed, %by_model, %order );
    for my $c ( @{ $plan->changes } ) {
        next if !$c->{model} || $c->{action} eq 'hold' || $c->{action} eq 'skip';
        my $b = $self->{ctx}->behaviour( $c->{model} );
        next if !$b->known;
        $standing += $b->annotate($c);
        for my $e ( @{ delete $c->{effects} // [] } ) {
            $suppressed++ if $e->{suppressed};
            my $line = $by_model{ $c->{model} }{ $e->{effect} } //= do {
                push @{ $order{ $c->{model} } }, $e->{effect};
                { effect => $e->{effect}, ( $e->{requires} ? ( requires => $e->{requires} ) : () ),
                  evidence => $e->{evidence}, changes => 0, suppressed => 0 };
            };
            $line->{changes}++;
            $line->{suppressed}++ if $e->{suppressed};
            $c->{effects_ref} = $c->{model};
        }
    }
    $plan->set_effects( { map { my $m = $_; ( $m => [ map { $by_model{$m}{$_} } @{ $order{$m} } ] ) } keys %by_model } )
        if %by_model;
    $plan->note( 'side effects: ' . ( $standing // 0 ) . ' standing, ' . ( $suppressed // 0 ) . ' suppressed by context (oom-ops show lists them)' )
        if $standing || $suppressed;
    return;
}

sub report ($self) { Odoo::Error->throw( kind => 'usage', message => $self->op_name . ' has no report' ) }
sub plan   ($self) { Odoo::Error->throw( kind => 'usage', message => $self->op_name . ' has no plan' ) }

sub new_plan ($self, %args) {
    my $profile = $self->pack ? $self->profile : undef;
    return Odoo::Ops::Plan->new(
        op       => $self->op_name,
        params   => Odoo::Ops::File->slim_params( $self->{params} ),
        instance => $self->{ctx}->instance,
        profile  => $profile ? { pack => $profile->pack, series => $profile->series } : undef,
        created  => Odoo::Ops::iso_time( $self->{ctx}->now ),
        actor    => $self->{ctx}->actor,
        blob_min => $self->{ctx}->config->blob_min,
        ( $self->acts_for ? ( acts_for => Odoo::Ops::Acting->plan_stamp($self) ) : () ),
        %args,
    );
}

1;
