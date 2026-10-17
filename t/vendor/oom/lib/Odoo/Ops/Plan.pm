package Odoo::Ops::Plan;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Digest::SHA ();
use JSON::PP ();

use Odoo::Error;
use Odoo::Ops;

=head1 NAME

Odoo::Ops::Plan - what a write operation intends to do

=head1 SYNOPSIS

    my $plan = Odoo::Ops::Plan->new(op => 'crm.import', instance => $ctx->instance,
                                    input_count => 120, ...);
    $plan->add(bucket => 'create', action => 'create', model => 'crm.lead',
               vals => {...}, key => 'email:a@b.example');
    $plan->add(bucket => 'skip-duplicate', action => 'skip', reason => '...');
    $plan->finalize;          # buckets must sum to input_count
    $plan->save("$dir/plan.json");

    my $again = Odoo::Ops::Plan->load("$dir/plan.json");   # fingerprint checked

=head1 DESCRIPTION

A plan is data: the list of changes, each with the bucket it was
sorted into, the action, the physical model, and for writes and
unlinks the before-image the operation saw. It always says
C<< applied => 0 >> - a plan can never be mistaken for a result, which
says C<< applied => 1 >>.

Actions: C<create> (vals), C<write> (id, vals, before), C<unlink> (id,
before), C<call> (a model method on ids: method, ids, args, kwargs),
C<custom> (carried out by the named operation's C<apply_custom> - for a
change that takes several calls, such as sending one email through the
composer), C<skip> and C<hold> (nothing is sent; C<hold> means it needs
a person's decision).

C<finalize> refuses a plan whose bucket counts do not sum to
C<input_count>, when one is given: every input row is accounted for,
in exactly one bucket. Changes marked C<< support => 1 >> - a tag or
source the rows need created first - are outside that sum.

A create may carry C<< unique_by => 'field' >>: at apply the runner
first looks for a record whose field equals the planned value exactly
(C<=>) and, if one exists, reuses it (outcome C<skipped>, its id bound
to the ref) instead of creating a duplicate - so two plans made side by
side cannot both create the same tag. For an email or a login, where
case is not a difference, write C<< unique_by => { field => 'email',
fold => 1 } >>: the look-up is then C<=ilike> with C<_>, C<%> and C<\>
escaped, so it ignores case and nothing else (C<first_last@x.com> does
not match C<firstXlast@x.com>). A composite key (a line of an order: the
order and the product) is C<< unique_by => { fields => [ 'order_id',
'product_id' ] } >>, each part a field name or C<< { field =>, fold => 1 } >>;
the record must match every part.

A create or write may carry C<context> (a hashref sent with the call,
e.g. C<< { mail_auto_subscribe_no_notify => 1 } >>), which is part of
what the fingerprint seals.

A change may carry C<< ref => 'name' >>; once it has created its
record, later changes can use C<< { '$ref' => 'name' } >> anywhere in
their vals (a many2one value, or inside an x2many command) and the
runner substitutes the new id. It then seals the plan with a fingerprint over
its instance, op, params and changes; C<load> refuses a plan whose
fingerprint no longer matches, so an edited plan must be re-planned,
not applied.

The seal covers what the plan will do. Commentary on it is outside the
seal: C<notes>, the plan-level C<effects> (what the models' behaviour
files say each kind of change makes Odoo do, stated once per model by
C<set_effects>) and the C<effects_ref> each change carries to name its
model's entry there.

C<summary> sorts the changes into what a person reviewing a plan asks
about: C<will_write> (create, write, unlink, call, custom), C<skip> and
C<hold>, each with its buckets and counts, the notes, the held rows with
their reasons, and C<nothing_to_apply> when nothing would be written.
C<will_write + skip + hold = input_count + support>, the support rows
(a tag made for the contacts that carry it) being outside the input.

=cut

# Every bucket (with the actions it carried) each operation has planned in this
# process. A test hook: t/99-declared-buckets.t checks that an operation
# declares what it produces. Set OOM_PLAN_OBSERVE to a file and every
# process appends what it saw there when it ends.
our %OBSERVED;
# and one hold's reason per bucket, under the key __hold_reasons, for t/99 to print the line as the screens do
our %OBSERVED_REASON;
END {
    if ( $ENV{OOM_PLAN_OBSERVE} && %OBSERVED && open my $fh, '>>', $ENV{OOM_PLAN_OBSERVE} ) {
        print {$fh} JSON::PP->new->canonical->encode( { %OBSERVED, __hold_reasons => \%OBSERVED_REASON } ), "\n";
        close $fh;
    }
}

my %ACTION = map { $_ => 1 } qw(create write unlink call custom skip hold);

sub new ($class, %args) {
    for my $req (qw(op instance)) {
        Odoo::Error->throw( kind => 'usage', message => "plan needs $req" ) if !$args{$req};
    }
    return bless {
        format      => 1,
        applied     => 0,
        op          => $args{op},
        params      => $args{params} // {},
        instance    => $args{instance},
        profile     => $args{profile},
        scope       => $args{scope} // {},
        input_count => $args{input_count},
        created     => $args{created},
        actor       => $args{actor},
        changes     => [],
        notes       => [],
        effects     => undef,
    }, $class;
}

sub op          ($self) { $self->{op} }
sub instance    ($self) { $self->{instance} }
sub scope       ($self) { $self->{scope} }
sub changes     ($self) { $self->{changes} }
sub fingerprint ($self) { $self->{fingerprint} }
sub applied     ($self) { 0 }
sub effects     ($self) { $self->{effects} // {} }
sub notes       ($self) { $self->{notes} }
sub input_count ($self) { $self->{input_count} }

# not sealed: see the DESCRIPTION
sub set_effects ($self, $effects) {
    $self->{effects} = $effects;
}

sub set_scope ($self, $scope) {
    $self->_unsealed;
    $self->{scope} = $scope;
}

sub set_input_count ($self, $n) {
    $self->_unsealed;
    $self->{input_count} = $n;
}

sub note ($self, $text) {
    $self->_unsealed;
    push @{ $self->{notes} }, $text;
}

sub add ($self, %c) {
    $self->_unsealed;
    Odoo::Error->throw( kind => 'usage', message => "unknown plan action '" . ( $c{action} // '' ) . "'" )
        if !$ACTION{ $c{action} // '' };
    Odoo::Error->throw( kind => 'usage', message => 'plan change needs a bucket' ) if !$c{bucket};
    if ( $c{action} =~ /^(create|write|unlink|call|custom)\z/ ) {
        Odoo::Error->throw( kind => 'usage', message => "$c{action} needs a model" ) if !$c{model};
    }
    if ( $c{action} =~ /^(write|unlink)\z/ ) {
        Odoo::Error->throw( kind => 'usage', message => "$c{action} needs an id" ) if !$c{id};
    }
    Odoo::Error->throw( kind => 'usage', message => 'call needs a method' )
        if $c{action} eq 'call' && !$c{method};
    Odoo::Error->throw( kind => 'usage', message => 'custom needs a handler (the operation name)' )
        if $c{action} eq 'custom' && !$c{handler};
    if ( defined $c{ref} ) {
        Odoo::Error->throw( kind => 'usage', message => 'only a create, or a custom change that makes a record, can carry a ref' )
            if $c{action} !~ /^(?:create|custom)\z/;
        Odoo::Error->throw( kind => 'usage', message => "ref '$c{ref}' used twice" )
            if grep { ( $_->{ref} // '' ) eq $c{ref} } @{ $self->{changes} };
    }
    my %known = map { defined $_->{ref} ? ( $_->{ref} => 1 ) : () } @{ $self->{changes} };
    Odoo::Error->throw( kind => 'usage', message => "id_ref '$c{id_ref}' is not created by an earlier change" )
        if defined $c{id_ref} && !$known{ $c{id_ref} };
    for my $r ( _refs_in( $c{vals} ) ) {
        Odoo::Error->throw( kind => 'usage', message => "\$ref '$r' is not created by an earlier change" )
            if !$known{$r};
    }
    $OBSERVED{ $self->{op} }{ $c{bucket} }{ $c{action} } = 1;
    $OBSERVED_REASON{ $self->{op} }{ $c{bucket} } //= $c{reason} if $c{action} eq 'hold' && defined $c{reason};
    $c{seq} = @{ $self->{changes} } + 1;
    push @{ $self->{changes} }, \%c;
    return $c{seq};
}

sub _refs_in ($v) {
    return () if !ref $v;
    if ( ref $v eq 'HASH' ) {
        return ( $v->{'$ref'} ) if keys %$v == 1 && exists $v->{'$ref'};
        return map { _refs_in($_) } values %$v;
    }
    return map { _refs_in($_) } @$v if ref $v eq 'ARRAY';
    return ();
}

sub buckets ($self) {
    my %b;
    $b{ $_->{bucket} }++ for @{ $self->{changes} };
    return \%b;
}

sub finalize ($self) {
    $self->_unsealed;
    if ( defined $self->{input_count} ) {
        my $sum = grep { !$_->{support} } @{ $self->{changes} };
        Odoo::Error->throw(
            kind    => 'usage',
            message => "plan buckets sum to $sum but input has $self->{input_count} rows",
        ) if $sum != $self->{input_count};
    }
    # Freeze: keep the exact JSON that was fingerprinted, and work from
    # fresh decoded copies from here on. Perl scalars change their JSON
    # type when merely used as strings, so a live structure could
    # otherwise encode differently at save time than at sealing time.
    $self->{frozen}      = Odoo::Ops::json()->encode( $self->_sealed_part );
    $self->{fingerprint} = Digest::SHA::sha256_hex( $self->{frozen} );
    my @refs = map { $_->{effects_ref} } @{ $self->{changes} };
    my $copy = Odoo::Ops::json()->decode( $self->{frozen} );
    $self->{$_} = $copy->{$_} for keys %$copy;
    for my $i ( 0 .. $#refs ) { $self->{changes}[$i]{effects_ref} = $refs[$i] if defined $refs[$i] }
    return $self;
}

sub _sealed_part ($self) {
    my $part = { map { $_ => $self->{$_} } qw(format op params instance profile scope input_count changes) };
    $part->{changes} = [ map { my %c = %$_; delete $c{effects_ref}; \%c } @{ $part->{changes} } ];
    return $part;
}

sub _unsealed ($self) {
    Odoo::Error->throw( kind => 'usage', message => 'plan is finalized' ) if $self->{fingerprint};
}

sub to_hash ($self) {
    Odoo::Error->throw( kind => 'usage', message => 'finalize the plan first' ) if !$self->{fingerprint};
    my $h = Odoo::Ops::json()->decode( $self->{frozen} );
    for my $i ( 0 .. $#{ $self->{changes} } ) {
        $h->{changes}[$i]{effects_ref} = $self->{changes}[$i]{effects_ref} if defined $self->{changes}[$i]{effects_ref};
    }
    return {
        %$h,
        applied     => 0,
        fingerprint => $self->{fingerprint},
        buckets     => $self->buckets,
        created     => $self->{created},
        actor       => $self->{actor},
        notes       => $self->{notes},
        ( $self->{effects} && %{ $self->{effects} } ? ( effects => $self->{effects} ) : () ),
    };
}

=head2 summary

The plan as a person reviewing it reads it, as one hashref:

    op input_count support
    will_write skip hold          counts of changes
    buckets                       { bucket => n } over every change, as ever
    by_group                      { will_write => {bucket => n}, skip => {...}, hold => {...} }
    notes                         the plan's notes, in order
    held                          [ { seq, bucket, key, reason } ] for every hold
    lines                         the line of every change that carries one, in order (a state change
                                  says "sale.order 135 (S00134): draft -> sale"), printed by oom-ops
    nothing_to_apply              1 when will_write is 0, else 0

=cut

sub summary ($self) {
    my %count = ( will_write => 0, skip => 0, hold => 0 );
    my %b     = ( will_write => {}, skip => {}, hold => {} );
    my ( $support, @held, @lines ) = (0);
    for my $c ( @{ $self->{changes} } ) {
        my $g = $c->{action} eq 'hold' ? 'hold' : $c->{action} eq 'skip' ? 'skip' : 'will_write';
        $count{$g}++;
        $b{$g}{ $c->{bucket} }++;
        $support++ if $c->{support};
        push @lines, $c->{line} if defined $c->{line} && length $c->{line} && $g eq 'will_write';
        push @held, { seq => $c->{seq}, bucket => $c->{bucket}, key => $c->{key}, reason => $c->{reason} } if $g eq 'hold';
    }
    return {
        op => $self->{op}, input_count => $self->{input_count}, support => $support,
        %count, buckets => $self->buckets, by_group => \%b, notes => [ @{ $self->{notes} } ], held => \@held, lines => \@lines,
        nothing_to_apply => $count{will_write} ? 0 : 1,
    };
}

sub save ($self, $path) {
    open my $fh, '>', $path
        or Odoo::Error->throw( kind => 'config', message => "cannot write plan $path: $!" );
    print {$fh} JSON::PP->new->utf8->canonical->pretty->encode( $self->to_hash );
    close $fh or Odoo::Error->throw( kind => 'config', message => "cannot write plan $path: $!" );
    return $path;
}

sub load ($class, $path) {
    open my $fh, '<', $path
        or Odoo::Error->throw( kind => 'config', message => "cannot read plan $path: $!" );
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $h = eval { Odoo::Ops::json()->decode($raw) }
        or Odoo::Error->throw( kind => 'config', message => "plan $path is not valid JSON" );
    return $class->from_hash($h);
}

sub from_hash ($class, $h) {
    Odoo::Error->throw( kind => 'refused', code => 'not-a-plan', message => 'this is a result, not a plan',
        fix => 'pass the plan.json of the run, not its result.json' )
        if $h->{applied};
    my $self   = bless { %$h, fingerprint => undef }, $class;
    my $frozen = Odoo::Ops::json()->encode( $self->_sealed_part );
    my $want   = Digest::SHA::sha256_hex($frozen);
    Odoo::Error->throw(
        kind    => 'refused',
        code    => 'fingerprint',
        message => 'plan fingerprint does not match its content; it was edited after planning - re-plan',
        fix     => 'plan again with oom-ops run (a plan is never edited by hand)',
    ) if ( $h->{fingerprint} // '' ) ne $want;
    $self->{frozen}      = $frozen;
    $self->{fingerprint} = $want;
    return $self;
}

1;
