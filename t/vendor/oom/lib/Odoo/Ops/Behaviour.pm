package Odoo::Ops::Behaviour;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use File::Basename qw(dirname);
use File::Spec;
use YAML::PP;

use Odoo::Error;
use Odoo::Ops::Invariant;

=head1 NAME

Odoo::Ops::Behaviour - what an Odoo model does when touched, per series (the "partner object")

=head1 SYNOPSIS

    my $b = Odoo::Ops::Behaviour->load( model => 'crm.lead', series => 16 );
    my @e = $b->effects_for( write => [qw(user_id stage_id)] );   # or ( call => 'action_unarchive' )
    for my $e (@e) {
        $e->{effect};        # "notifies the assignee by email from the acting user"
        $e->{requires};      # { acting_user_email => 1 }        a precondition, by probe name
        $e->{suppress};      # { context => { mail_auto_subscribe_no_notify => 1 } }
        $e->{evidence};      # "live 2026-09-28; source mail_thread._message_auto_subscribe_notify"
    }
    $b->route('log_note');   # { via => 'mail.message.create', why => '...' }

=head1 DESCRIPTION

The schema (C<fields_get>) says what fields a model has. It does not
say that writing C<user_id> on a lead emails the assignee, that
validating a picking posts a message as the acting user and fails
when that user has no address, or that confirming an internal
transfer merges its moves. Each of those was learned once, by doing
real work, and then lived inside the one operation that met it. A
behaviour file is where such a lesson lands once, per model and
series, so every operation on that model inherits it:

    model: crm.lead
    series: 16
    effects:
      - on: write                       # create | write | call | validate
        fields: [user_id]               # for create/write; method: for call
        effect: notifies the assignee by email from the acting user
        requires: { acting_user_email: 1 }
        suppress: { context: { mail_auto_subscribe_no_notify: true } }
        evidence: live 2026-09-28; source mail_thread._message_auto_subscribe_notify
    routes:
      log_note: { via: mail.message.create, why: message_post refuses an author without an email }
    probes: [acting_user_email]        # instance facts core.check reports for this model
    state:                             # a state Odoo changes through its own actions
      field: state
      written_by: actions
      also: [approval_state]            # other fields that carry the state, held the same way
      operations: [sale.confirm, sale.cancel]
    module: hr_holidays                # the module that provides the model
    actions:                           # public methods core.action may call
      - { method: action_approve, undo: action_refuse, evidence: "source 18.0 ..." }
      - method: create_employee_from_applicant   # on hr.applicant: the models it makes records in
        creates: [ { model: hr.employee, link: employee_id } ]
        evidence: "..."
    wizards:                           # transient models core.wizard may drive for this model
      - { model: hr.holidays.cancel.leave, method: action_cancel_leave, evidence: "..." }
    volatile: [customer_rank, supplier_rank]   # Odoo bumps these itself; not a change of the record
    unlink_requires:                   # Odoo deletes a record only from these states
      state: [cancel]
      noun: order
    # a line has no state of its own: Odoo deletes it by its parent's state
    unlink_requires:
      parent: order_id                 # the many2one to the parent; its state is the one that counts
      state: [draft, sent, cancel]
      noun: order                      # what the parent is called

    invariants:                        # checked around an apply that writes the model, see L<Odoo::Ops::Invariant>
      - name: probability-manual
        pack: crm                      # optional: only an operation of this pack is judged by it
        model: crm.lead
        domain: [["active","=",true],["probability","=",{"field":"automated_probability"}]]
        expect: 0

Three layers stay apart: model behaviour (here, the same for every
database of a series), instance facts (probes, read live by
C<core.check>), team practice (owner rulings in the data home,
applied through parameters). A rule carries its evidence grade and
series; a series without a file inherits the nearest lower one and
says so in C<warnings>, as profiles do.

At run time L<Odoo::Ops::Operation> annotates every planned change
with the effects its model declares for that action and those
fields: C<effects> on the change, each marked C<suppressed> when the
change's context carries the suppressing key, so the person approving
sees the consequences beside the values.

Roots searched: C<$ENV{ODOO_OOM_BEHAVIOURS}>, the source tree's
C<behaviours/>, C</usr/share/odoo-oom/behaviours> (C<$ENV{ODOO_OOM_SHARE}/behaviours> when that is set; none when it is empty), then the C<behaviours/> of
each loaded pack (L<Odoo::Ops::Pack>), so a pack adds models and never
shadows core's.

=cut

# the installed share root: ODOO_OOM_SHARE names another, and empty names none (a caller's tests that must not read the host)
sub _share ($class, $leaf) { my $s = $ENV{ODOO_OOM_SHARE} // '/usr/share/odoo-oom'; return length $s ? "$s/$leaf" : undef }

# core's own roots: what a pack may not replace
sub core_dirs ($class) {
    my $tree = File::Spec->catdir( dirname(__FILE__), ('..') x 3, 'behaviours' );
    return grep { defined && -d } $ENV{ODOO_OOM_BEHAVIOURS}, $tree, $class->_share('behaviours');
}

sub default_dirs ($class, @extra) {
    require Odoo::Ops::Pack;
    return grep { defined && -d } @extra, $class->core_dirs, Odoo::Ops::Pack->roots('behaviours');
}

# a model with no file: an empty behaviour (nothing known, nothing claimed)
sub load ($class, %args) {
    my $model  = $args{model}  or Odoo::Error->throw( kind => 'usage', message => 'behaviour needs model' );
    my $series = $args{series} or Odoo::Error->throw( kind => 'usage', message => 'behaviour needs series' );
    for my $root ( $class->default_dirs( @{ $args{dirs} // [] } ) ) {
        my $dir = File::Spec->catdir( $root, $model );
        next if !-d $dir;
        opendir my $dh, $dir or next;
        my @have = sort { $b <=> $a } map { /^(\d+)\.yaml\z/ ? $1 : () } readdir $dh;
        closedir $dh;
        my ($pick) = grep { $_ <= $series } @have;
        next if !defined $pick;
        my $self = $class->from_file( File::Spec->catfile( $dir, "$pick.yaml" ) );
        push @{ $self->{warnings} }, "no $model behaviour for series $series; using $pick - rules may not hold" if $pick != $series;
        return $self;
    }
    return bless { model => $model, series => 0 + $series, effects => [], routes => {}, probes => [], warnings => [], path => undef }, $class;
}

# the models that have a behaviour file in any root, sorted
sub models ($class, @dirs) {
    my %m;
    for my $root ( $class->default_dirs(@dirs) ) {
        opendir my $dh, $root or next;
        $m{$_} = 1 for grep { !/^\./ && -d File::Spec->catdir( $root, $_ ) } readdir $dh;
        closedir $dh;
    }
    return sort keys %m;
}

# the newest series a model has a file for (undef when none): what describe
# reads when no server says which series is meant
sub latest ($class, $model, @dirs) {
    my $best;
    for my $root ( $class->default_dirs(@dirs) ) {
        my $dir = File::Spec->catdir( $root, $model );
        next if !-d $dir;
        opendir my $dh, $dir or next;
        for ( map { /^(\d+)\.yaml\z/ ? $1 : () } readdir $dh ) { $best = $_ if !defined $best || $_ > $best }
        closedir $dh;
    }
    return $best;
}

sub from_file ($class, $path) {

    my $d = eval { YAML::PP->new( schema => ['Core'], boolean => 'JSON::PP' )->load_file($path) }
        or Odoo::Error->throw( kind => 'config', message => "cannot load behaviour $path: $@" );
    Odoo::Error->throw( kind => 'config', message => "behaviour $path needs model and series" ) if !$d->{model} || !$d->{series};
    my @effects;
    for my $e ( @{ $d->{effects} // [] } ) {
        Odoo::Error->throw( kind => 'config', message => "behaviour $path: an effect needs on and effect" ) if !$e->{on} || !$e->{effect};
        Odoo::Error->throw( kind => 'config', message => "behaviour $path: effect on '$e->{on}' is not create, write, call or validate" )
            if $e->{on} !~ /^(create|write|call|validate)\z/;
        Odoo::Error->throw( kind => 'config', message => "behaviour $path: an effect needs evidence" ) if !$e->{evidence};
        push @effects, { %$e, fields => $e->{fields} // [] };
    }
    Odoo::Ops::Invariant->check_definition( $path, $_ ) for @{ $d->{invariants} // [] };
    if ( my $st = $d->{state} ) {
        Odoo::Error->throw( kind => 'config', message => "behaviour $path: state needs a field and written_by (actions or write)" )
            if ref $st ne 'HASH' || !$st->{field} || ( $st->{written_by} // '' ) !~ /\A(?:actions|write)\z/;
        Odoo::Error->throw( kind => 'config', message => "behaviour $path: state also must be a list of field names" )
            if exists $st->{also} && ( ref $st->{also} ne 'ARRAY' || grep { ref || !length } @{ $st->{also} } );
    }
    my ( $actions, $wizards ) = _check_actions( $path, $d );
    if ( my $u = $d->{unlink_requires} ) {
        Odoo::Error->throw( kind => 'config', message => "behaviour $path: unlink_requires needs a state list" )
            if ref $u ne 'HASH' || ref $u->{state} ne 'ARRAY' || !@{ $u->{state} };
        Odoo::Error->throw( kind => 'config', message => "behaviour $path: unlink_requires parent must be a field name" )
            if exists $u->{parent} && ( ref $u->{parent} || !length( $u->{parent} // '' ) );
    }
    return bless {
        model => $d->{model}, series => 0 + $d->{series}, effects => \@effects,
        routes => $d->{routes} // {}, probes => $d->{probes} // [], invariants => $d->{invariants} // [],
        state => $d->{state}, unlink_requires => $d->{unlink_requires}, volatile => $d->{volatile} // [],
        module => $d->{module}, actions => $actions, wizards => $wizards,
        warnings => [], path => $path,
    }, $class;
}

sub model    ($self) { $self->{model} }
sub series   ($self) { $self->{series} }
sub path     ($self) { $self->{path} }
sub warnings ($self) { $self->{warnings} }
sub effects  ($self) { $self->{effects} }
sub probes   ($self) { $self->{probes} }
sub routes   ($self) { $self->{routes} }
sub route    ($self, $name) { $self->{routes}{$name} }
sub invariants ($self) { $self->{invariants} // [] }
sub known    ($self) { defined $self->{path} }

=head2 state_rule / action_driven / unlink_requires

C<state_rule> is the file's C<state> block when C<written_by> is C<actions>
(Odoo changes the state through its own methods and a write of it is not how
a state is changed), with the state C<field>, any C<also> fields Odoo computes
from it, and C<operations>, the OOM operations that change it; undef when the
file has no block or says C<written_by: write> (a status bar that is a plain
write). C<state_info> returns the block either way. C<action_driven> is true
when C<state_rule> is. C<unlink_requires> is C<< { state => [..], noun => '...' } >>, the
states from which Odoo deletes a record and what the record is called in a
sentence (C<noun>); undef when the file says nothing. A revert plan states
it as a note when a record is in another state. The parent form
(C<parent>: the many2one field to the parent record) is for a line model
whose rule reads the parent's state: C<state> then lists the parent's states
from which Odoo deletes a line and C<noun> names the parent.
C<parent_field> returns the field, or undef.

=cut

sub state_rule      ($self) { $self->{state} && $self->{state}{written_by} eq 'actions' ? $self->{state} : undef }
sub action_driven   ($self) { $self->state_rule ? 1 : 0 }
sub unlink_requires ($self) { $self->{unlink_requires} }
sub volatile        ($self) { @{ $self->{volatile} // [] } }
sub parent_field    ($self) { $self->{unlink_requires} && $self->{unlink_requires}{parent} }

=head2 state_fields

The fields the file names as the record's state: C<state.field> and each of
C<state.also> (a field Odoo computes from it, read beside it). The list is
there whether the state is changed by an action (C<written_by: actions>) or by a
plain write (C<written_by: write>, a status bar such as a contract's); only the
first makes L<Odoo::Ops::Core::Import> hold a row that sets it.

=head2 module / actions / wizards

C<module> is the module that provides the model. C<actions> lists the public
methods a caller may call on the model through C<core.action>, and
C<wizards> the transient models and methods C<core.wizard> may drive for it:

    module: hr_holidays
    actions:
    - method: action_approve
      module: hr_holidays            # the module that adds the method, when not the model's own
      from: [confirm]                # documentation: the states Odoo allows it from
      to: [validate1, validate]      # documentation: the states it ends in
      undo: action_refuse            # another listed action that takes it back
      wizard: hr.holidays.cancel.leave   # a window answer means this wizard
      note: needs the acting user to be an employee
      evidence: source 18.0 hr_leave.action_approve; live 2026-10-16 t/97
    wizards:
    - model: hr.holidays.cancel.leave
      method: action_cancel_leave
      button: action_cancel          # the action method whose button opens it
      values: [reason]               # what the wizard asks for
      context_from_record: [default_leave_id]   # context keys the button sets to the record's id
      context: { default_x: 1 }      # context keys the button always sets
      undo: action_reset_confirm     # a listed action of the target model
      evidence: ...

A method never starts with C<_>, a method is listed once per model, C<undo>
names a listed action, C<from> and C<to> are for the reader and for
C<describe> (Odoo decides), and each entry carries its C<evidence>.
C<action($method)> and C<wizard($model, $method)> return the entry or undef.

An action entry is called on records (C<on: records>, the default: the ids are its
first argument) or on the model (C<on: model>: an C<@api.model> method, called
with no ids). A model-level entry names the positional arguments it takes, in
order, as C<params> (C<name> and C<type>: C<str>, C<int>, C<bool> or C<json>);
without C<params> it takes none. Its C<undo> is a model-level entry too, called
with the same arguments. C<on_model($entry)> and C<params($entry)> read them.

    - method: register_attendance
      on: model
      params: [ { name: card_code, type: str } ]

A wizard entry may say C<on: model> too: a wizard a menu opens, with no records
(C<core.wizard> then takes no C<records>, and sets no C<active_*> context). It has
no C<context_from_record> and no C<undo>.

C<creates> on an action or wizard entry lists the models the method is known to
make records in (C<model>, and C<link>, the field of the record acted on that
names what was made). The entry's C<creates_evidence> says how each was shown (source and the live run).
C<core.action> and C<core.wizard> look in those models for what the call made
and say so; an entry with no C<creates> says C<creates: not listed> in its plan
line. C<creates($entry)> returns the list.

=cut

sub module  ($self) { $self->{module} }
sub actions ($self) { $self->{actions} // [] }
sub wizards ($self) { $self->{wizards} // [] }
sub action  ($self, $method) { ( grep { $_->{method} eq $method } @{ $self->{actions} // [] } )[0] }
sub wizard  ($self, $model, $method) { ( grep { $_->{model} eq $model && $_->{method} eq $method } @{ $self->{wizards} // [] } )[0] }
sub creates ($self, $entry) { return @{ $entry->{creates} // [] } }
sub on_model ($self, $entry) { return ( $entry->{on} // 'records' ) eq 'model' ? 1 : 0 }
sub params   ($self, $entry) { return @{ $entry->{params} // [] } }
sub state_info ($self) { $self->{state} }
sub state_fields ($self) {
    my $st = $self->{state} or return ();
    return ( $st->{field}, @{ $st->{also} // [] } );
}

sub _check_actions ( $path, $d ) {
    my $bad = sub ($m) { Odoo::Error->throw( kind => 'config', message => "behaviour $path: $m" ) };
    my $check_creates = sub ($what, $e) {
        return if !exists $e->{creates};
        $bad->("$what: creates must be a list of { model, link }") if ref $e->{creates} ne 'ARRAY' || !@{ $e->{creates} };
        my %m;
        for my $c ( @{ $e->{creates} } ) {
            $bad->("$what: creates needs a model on each entry (physical, with a dot)")
                if ref $c ne 'HASH' || ref $c->{model} || ( $c->{model} // '' ) !~ /\A\w+(?:\.\w+)+\z/;
            $bad->("$what: creates lists $c->{model} twice") if $m{ $c->{model} }++;
            $bad->("$what: creates link must be a field name")
                if exists $c->{link} && ( ref $c->{link} || ( $c->{link} // '' ) !~ /\A\w+\z/ );
        }
        $bad->("$what: creates needs creates_evidence (what showed the records being made)") if !length( $e->{creates_evidence} // '' );
    };
    my $check_on = sub ($a) {
        my $what = "action $a->{method}";
        $bad->("$what: on must be records or model") if exists $a->{on} && ( ref $a->{on} || ( $a->{on} // '' ) !~ /\A(?:records|model)\z/ );
        my $model_level = ( $a->{on} // 'records' ) eq 'model';
        $bad->("$what: params belong to an on: model entry (a records entry takes its arguments after the ids, unnamed)") if exists $a->{params} && !$model_level;
        return if !exists $a->{params};
        $bad->("$what: params must be a list of { name, type }") if ref $a->{params} ne 'ARRAY';
        my %n;
        for my $p ( @{ $a->{params} } ) {
            $bad->("$what: a param needs a name") if ref $p ne 'HASH' || ref $p->{name} || ( $p->{name} // '' ) !~ /\A[A-Za-z_]\w*\z/;
            $bad->("$what: param $p->{name} is listed twice") if $n{ $p->{name} }++;
            $bad->("$what: param $p->{name} needs a type of str, int, bool or json") if ref $p->{type} || ( $p->{type} // '' ) !~ /\A(?:str|int|bool|json)\z/;
        }
    };
    $bad->('module must be a module name') if exists $d->{module} && ( ref $d->{module} || !length( $d->{module} // '' ) );
    my ( %seen, @actions, @wizards );
    for my $a ( @{ $d->{actions} // [] } ) {
        $bad->('an action needs a method') if ref $a ne 'HASH' || !length( $a->{method} // '' ) || ref $a->{method};
        $bad->("action $a->{method} is private: only public methods are listed") if $a->{method} =~ /\A_/;
        $bad->("action $a->{method} is listed twice") if $seen{ $a->{method} }++;
        $bad->("action $a->{method} needs evidence") if !length( $a->{evidence} // '' );
        for my $k (qw(from to)) {
            $bad->("action $a->{method}: $k must be a list of states") if exists $a->{$k} && ref $a->{$k} ne 'ARRAY';
        }
        $check_on->( $a );
        $check_creates->( "action $a->{method}", $a );
        push @actions, {%$a};
    }
    my %level = map { $_->{method} => ( $_->{on} // 'records' ) } @actions;
    for my $a (@actions) {
        $bad->("action $a->{method}: undo $a->{undo} is on: $level{ $a->{undo} } and the action is on: $level{ $a->{method} }; an undo is called the same way") if defined $a->{undo} && $seen{ $a->{undo} } && $level{ $a->{undo} } ne $level{ $a->{method} };
        $bad->("action $a->{method}: undo $a->{undo} is not a listed action") if defined $a->{undo} && !$seen{ $a->{undo} };
    }
    my %wseen;
    for my $w ( @{ $d->{wizards} // [] } ) {
        $bad->('a wizard needs a model and a method') if ref $w ne 'HASH' || !length( $w->{model} // '' ) || !length( $w->{method} // '' );
        $bad->("wizard $w->{model} $w->{method} is private: only public methods are listed") if $w->{method} =~ /\A_/;
        $bad->("wizard $w->{model} $w->{method} is listed twice") if $wseen{"$w->{model}\0$w->{method}"}++;
        $bad->("wizard $w->{model} $w->{method} needs evidence") if !length( $w->{evidence} // '' );
        $bad->("wizard $w->{model} $w->{method}: undo $w->{undo} is not a listed action") if defined $w->{undo} && !$seen{ $w->{undo} };
        for my $k (qw(values context_from_record)) {
            $bad->("wizard $w->{model} $w->{method}: $k must be a list") if exists $w->{$k} && ref $w->{$k} ne 'ARRAY';
        }
        $bad->("wizard $w->{model} $w->{method}: context must be a map of context keys") if exists $w->{context} && ref $w->{context} ne 'HASH';
        $bad->("wizard $w->{model} $w->{method}: on must be records or model") if exists $w->{on} && ( ref $w->{on} || ( $w->{on} // '' ) !~ /\A(?:records|model)\z/ );
        $bad->("wizard $w->{model} $w->{method}: context_from_record names a record, and an on: model wizard has none") if ( $w->{on} // '' ) eq 'model' && exists $w->{context_from_record};
        $bad->("wizard $w->{model} $w->{method}: undo names an action of the record, and an on: model wizard has none") if ( $w->{on} // '' ) eq 'model' && defined $w->{undo};
        $check_creates->( "wizard $w->{model} $w->{method}", $w );
        push @wizards, {%$w};
    }
    my %wm = map { $_->{model} => 1 } @wizards;
    for my $a (@actions) {
        $bad->("action $a->{method}: wizard $a->{wizard} is not a listed wizard") if defined $a->{wizard} && !$wm{ $a->{wizard} };
    }
    return ( \@actions, \@wizards );
}

=head2 volatile

The fields Odoo maintains itself on this model (C<volatile: [customer_rank,
...]> in the file): counters and message bookkeeping that move when a document
is confirmed or posted, not when somebody edits the record. L<Odoo::Ops::Runner>
leaves them out when it asks whether a record changed since a run, so a
partner's rank does not hold the revert of its creation.

=head2 effects_for($on, $what)

The effects an action triggers: for C<create> and C<write>, C<$what>
is the list of fields written (an effect with no fields applies to
any write); for C<call>, the method name; for C<validate>, nothing.

=cut

sub effects_for ($self, $on, $what = undef) {
    my @out;
    for my $e ( @{ $self->{effects} } ) {
        next if $e->{on} ne $on;
        if ( $on eq 'call' ) {
            next if ( $e->{method} // '' ) ne ( $what // '' );
        }
        elsif ( $on eq 'create' || $on eq 'write' ) {
            my @f = @{ $e->{fields} };
            if (@f) {
                my %w = map { $_ => 1 } @{ $what // [] };
                next if !grep { $w{$_} } @f;
            }
        }
        push @out, $e;
    }
    return @out;
}

=head2 annotate(\%change)

Adds C<effects> to a plan change from its action, model, fields and
context: each entry C<{ effect, suppressed, requires, evidence }>.
Returns the number of effects that stand (not suppressed).

=cut

sub annotate ($self, $c) {
    my ( $on, $what );
    if    ( $c->{action} eq 'create' ) { ( $on, $what ) = ( create => [ keys %{ $c->{vals} // {} } ] ) }
    elsif ( $c->{action} eq 'write' )  { ( $on, $what ) = ( write  => [ keys %{ $c->{vals} // {} } ] ) }
    elsif ( $c->{action} eq 'call' )   { ( $on, $what ) = ( call   => $c->{method} ) }
    elsif ( $c->{action} eq 'custom' && ( $c->{kind} // '' ) eq 'transfer' ) { $on = 'validate' }
    # a state change is a run of Odoo's own methods; each method's effects stand
    elsif ( $c->{action} eq 'custom' && ( $c->{kind} // '' ) eq 'state' ) { ( $on, $what ) = ( call => [ map { $_->{method} } @{ $c->{vals}{steps} // [] } ] ) }
    # an operation that deletes by a custom change (so a revert can recreate the record) is an unlink to the model
    elsif ( $c->{action} eq 'custom' && ( $c->{kind} // '' ) =~ /^delete-/ ) { ( $on, $what ) = ( call => 'unlink' ) }
    # core.action: Odoo's method on the record; the effects the file declares for that method stand
    elsif ( $c->{action} eq 'custom' && ( $c->{kind} // '' ) eq 'action' ) { ( $on, $what ) = ( call => $c->{vals}{method} ) }
    else { return 0 }
    # effects the operation worked out for this very change (the traces that point at it) come first
    my @own = $on eq 'call' && ( $c->{kind} // '' ) =~ /^delete-/ ? @{ $c->{effects} // [] } : ();
    my @effects = ref $what eq 'ARRAY' && $on eq 'call' ? ( map { $self->effects_for( call => $_ ) } @$what ) : $self->effects_for( $on, $what );
    if ( !@effects ) {
        return scalar grep { !$_->{suppressed} } @own if @own;
        return 0;
    }
    my $standing = 0;
    my @ann;
    for my $e (@effects) {
        my $suppressed = 0;
        if ( my $ctx = $e->{suppress}{context} ) {
            $suppressed = 1 if grep { exists $c->{context}{$_} && $c->{context}{$_} } keys %$ctx;
        }
        $standing++ if !$suppressed;
        push @ann, { effect => $e->{effect}, suppressed => $suppressed, ( $e->{requires} ? ( requires => $e->{requires} ) : () ), evidence => $e->{evidence} };
    }
    $c->{effects} = [ @own, @ann ];
    return $standing + scalar( grep { !$_->{suppressed} } @own );
}

1;
