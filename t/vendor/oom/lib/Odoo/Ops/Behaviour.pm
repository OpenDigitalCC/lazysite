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

    invariants:                        # checked around every apply, see L<Odoo::Ops::Invariant>
      - name: probability-manual
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
C<behaviours/>, C</usr/share/odoo-oom/behaviours>.

=cut

sub default_dirs ($class, @extra) {
    my $tree = File::Spec->catdir( dirname(__FILE__), ('..') x 3, 'behaviours' );
    return grep { defined && -d } @extra, $ENV{ODOO_OOM_BEHAVIOURS}, $tree, '/usr/share/odoo-oom/behaviours';
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
    return bless {
        model => $d->{model}, series => 0 + $d->{series}, effects => \@effects,
        routes => $d->{routes} // {}, probes => $d->{probes} // [], invariants => $d->{invariants} // [],
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
    else { return 0 }
    my @effects = $self->effects_for( $on, $what );
    return 0 if !@effects;
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
    $c->{effects} = \@ann;
    return $standing;
}

1;
