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
    invariant_packs  the packs whose invariants judge its writes (default: its pack)
    params       { name => { type, required, default, help } }
                 types: str int bool json list path rows (see check_rows)
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
    immediate    true for an operation applied at once, never planned (it has no
                 plan, run folder or journal; core.credential), else false
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

# The packs whose invariants this operation's writes are judged by: its own
# pack, plus any more an operation names to opt in to them.
sub invariant_packs ($class) { defined $class->pack ? ( $class->pack ) : () }
sub params      ($class) { {} }
sub read_scope  ($class) { {} }
sub write_scope ($class) { {} }
sub writes      ($class) { !!%{ $class->write_scope } }
sub immediate   ($class) { 0 }
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
        $out{$k} = _typed( $class->op_name, $k, $s->{type} // 'str', $v, $s );
    }
    return \%out;
}

sub _typed ($op, $k, $type, $v, $spec = {}) {
    my $bad = sub { Odoo::Error->throw( kind => 'usage', message => "$op: parameter '$k' must be $type", fix => "oom-ops describe $op shows each parameter's type" ) };
    return Odoo::Ops::Operation->check_rows( $spec, $v, "$op: parameter '$k'" ) if $type eq 'rows';
    return $v if ref $v && $type =~ /^(json|list)\z/;
    if ( $type eq 'int' )  { $v =~ /^-?\d+\z/ or $bad->(); return 0 + $v }
    if ( $type eq 'bool' ) { $v =~ /^(1|0|yes|no|true|false)\z/i or $bad->(); return $v =~ /^(1|yes|true)\z/i ? 1 : 0 }
    if ( $type eq 'json' ) { my $d = eval { Odoo::Ops::json()->decode($v) }; defined $d or $bad->(); return $d }
    if ( $type eq 'list' ) { return [ grep { length } split /\s*,\s*/, $v ] }
    if ( $type eq 'path' || $type eq 'str' ) { return "$v" }
    Odoo::Error->throw( kind => 'usage', message => "$op: parameter '$k' has unknown type '$type'" );
}

=head2 check_rows($decl, $value, $label)

Class method: the value of a C<rows> parameter checked against its
declaration, as C<check_params> checks it, so a caller can run the same rule
before it sends. C<$decl> is the parameter's declaration:

    lines => { type => 'rows', max => 50, required => 1,
               row => { product_id => 'int', qty => 'int', discount => 'int?' } }

Each row field is C<str>, C<int> or C<bool>, with C<?> for an optional key;
C<max> is required. C<$value> is an array of hashes, or the text of a JSON
array of flat objects. It must hold at most C<max> rows, each a hash with
only the declared keys, every required key present and each value of its
type with no nesting: an C<int> is a whole number (JSON number or digits), a
C<bool> is true or false (C<1 0 yes no true false>), a C<str> is a plain
value of at most 4096 characters holding no control character. A C<null>
leaves an optional key out. Returns the rows (a new array of new hashes,
values typed). A breach is C<usage>, naming the row number (from 1) and the
key; C<$label> (default C<rows>) leads the message.

=cut

sub check_rows ($class, $decl, $value, $label = 'rows') {
    my $bad = sub ($why, $kind = 'usage') {
        Odoo::Error->throw( kind => $kind, message => "$label$why", fix => 'oom-ops describe <op> shows the rows each parameter takes' );
    };
    ref $decl eq 'HASH' && ( $decl->{type} // '' ) eq 'rows' or $bad->( ' is not declared as rows', 'config' );
    my $max = $decl->{max};
    defined $max && !ref $max && $max =~ /\A[1-9]\d*\z/ or $bad->( ' declares no max (a whole number of at least 1)', 'config' );
    my $row = $decl->{row};
    ref $row eq 'HASH' && %$row or $bad->( ' declares no row fields', 'config' );
    my ( %type, %optional );
    for my $k ( sort keys %$row ) {
        my ( $ty, $q ) = ( $row->{$k} // '' ) =~ /\A(str|int|bool)(\?)?\z/
            or $bad->( " declares row key '$k' as '" . ( $row->{$k} // '' ) . "' (str, int or bool, with ? for optional)", 'config' );
        $type{$k}     = $ty;
        $optional{$k} = 1 if $q;
    }

    my $rows = $value;
    $rows = eval { Odoo::Ops::json()->decode( $value // '' ) } if !ref $rows;
    ref $rows eq 'ARRAY' or $bad->( " must be a list of at most $max rows (a JSON array of objects)" );
    $bad->( ' has ' . scalar(@$rows) . " rows; at most $max are allowed" ) if @$rows > $max;

    my @out;
    my $n = 0;
    for my $r (@$rows) {
        $n++;
        ref $r eq 'HASH' or $bad->( " row $n must be an object of " . join( ', ', sort keys %type ) );
        for my $k ( sort keys %$r ) {
            $bad->( " row $n: key '$k' is not declared (the row takes " . join( ', ', sort keys %type ) . ')' ) if !$type{$k};
        }
        my %o;
        for my $k ( sort keys %type ) {
            my $v = $r->{$k};
            if ( !defined $v ) {
                $bad->( " row $n: key '$k' is required" ) if !$optional{$k};
                next;
            }
            my $ty = $type{$k};
            if ( ref $v ) {
                # a JSON true or false is a bool; any other reference is nesting
                $bad->( " row $n: key '$k' must be a plain $ty, not a nested value" )
                    if $ty ne 'bool' || !eval { $v->isa('JSON::PP::Boolean') };
                $o{$k} = $v ? 1 : 0;
                next;
            }
            if ( $ty eq 'int' ) {
                $v =~ /\A-?\d+\z/ or $bad->( " row $n: key '$k' must be int" );
                $o{$k} = 0 + $v;
            }
            elsif ( $ty eq 'bool' ) {
                $v =~ /\A(?:1|0|yes|no|true|false)\z/i or $bad->( " row $n: key '$k' must be bool" );
                $o{$k} = $v =~ /\A(?:1|yes|true)\z/i ? 1 : 0;
            }
            else {
                $bad->( " row $n: key '$k' must be at most 4096 characters" ) if length $v > 4096;
                $bad->( " row $n: key '$k' must not hold a control character" ) if $v =~ /[\x00-\x1f\x7f]/;
                $o{$k} = "$v";
            }
        }
        push @out, \%o;
    }
    return \@out;
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
            params => [ sort keys %{ $self->{params} // {} } ],
        );
    };
    return;
}

sub _run ($self) {
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
        $plan->note( 'invariants checked at apply: ' . join( ', ', map { "$_->{name} ($_->{model})" } @inv ) ) if @inv;
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
        blob_min => $self->{ctx}->config->blob_min,
        %args,
    );
}

1;
