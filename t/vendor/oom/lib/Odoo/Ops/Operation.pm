package Odoo::Ops::Operation;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Plan;
use Odoo::Ops::Invariant;
use Odoo::Ops::Modules;

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
    params       { name => { type, required, default, help } }
                 types: str int bool json list path
    read_scope   { model => [methods] } used while reporting/planning
    write_scope  { model => [methods] } added while applying; declaring
                 one makes the operation a write operation
    buckets      [ { name, meaning } ] the buckets a plan of this operation
                 sorts rows into that are written or skipped (a write
                 operation declares it)
    holds        [ { name, meaning } ] the buckets whose rows wait for a
                 person, each with the cause in one line
    fields       [ { name, meaning } ] for a read: the keys of the
                 descriptors it returns in its C<fields> block
    buckets_from 'dynamic' with a reason, for an operation whose bucket
                 names cannot be listed; no shipped operation needs it

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
sub params      ($class) { {} }
sub read_scope  ($class) { {} }
sub write_scope ($class) { {} }
sub writes      ($class) { !!%{ $class->write_scope } }
sub buckets     ($class) { [] }
sub holds       ($class) { [] }
sub fields      ($class) { [] }
sub buckets_from ($class) { undef }

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

sub profile ($self) {
    my $pack = $self->pack
        or Odoo::Error->throw( kind => 'usage', message => $self->op_name . ' has no profile pack' );
    return $self->{ctx}->profile($pack);
}

# Odoo::Model for a logical (profile) or physical (dotted) model name.
sub model ($self, $name) {
    return $self->client->model( $self->physical_model($name) );
}

sub physical_model ($self, $name) {
    return $name if $name =~ /\./;
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
        $out{$k} = _typed( $class->op_name, $k, $s->{type} // 'str', $v );
    }
    return \%out;
}

sub _typed ($op, $k, $type, $v) {
    my $bad = sub { Odoo::Error->throw( kind => 'usage', message => "$op: parameter '$k' must be $type", fix => "oom-ops describe $op shows each parameter's type" ) };
    return $v if ref $v && $type =~ /^(json|list)\z/;
    if ( $type eq 'int' )  { $v =~ /^-?\d+\z/ or $bad->(); return 0 + $v }
    if ( $type eq 'bool' ) { $v =~ /^(1|0|yes|no|true|false)\z/i or $bad->(); return $v =~ /^(1|yes|true)\z/i ? 1 : 0 }
    if ( $type eq 'json' ) { my $d = eval { Odoo::Ops::json()->decode($v) }; defined $d or $bad->(); return $d }
    if ( $type eq 'list' ) { return [ grep { length } split /\s*,\s*/, $v ] }
    if ( $type eq 'path' || $type eq 'str' ) { return "$v" }
    Odoo::Error->throw( kind => 'usage', message => "$op: parameter '$k' has unknown type '$type'" );
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

sub _run ($self) {
    my $scope = $self->scope_for('read');
    return $self->{ctx}->guard->with_scope( $scope, $self->op_name, sub {
        # an operation of a pack whose module this server lacks is not applicable here; that is said before anything else
        Odoo::Ops::Modules->gate_pack( $self->{ctx}, $self->op_name, $self->pack ) if defined $self->pack;
        return $self->report if !$self->writes;
        my $plan = $self->plan;    # unfinalized; sealed here with its scope
        $self->annotate_effects($plan);
        # the invariants of the models the plan writes are read around the apply
        my $scope = $self->scope_for('apply');
        Odoo::Ops::Invariant->add_scope( $scope, Odoo::Ops::Invariant->for_plan( $self->{ctx}, $plan ) );
        $plan->set_scope($scope);
        return $plan->finalize;
    } );
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
        params   => $self->{params},
        instance => $self->{ctx}->instance,
        profile  => $profile ? { pack => $profile->pack, series => $profile->series } : undef,
        created  => Odoo::Ops::iso_time( $self->{ctx}->now ),
        actor    => $self->{ctx}->actor,
        %args,
    );
}

1;
