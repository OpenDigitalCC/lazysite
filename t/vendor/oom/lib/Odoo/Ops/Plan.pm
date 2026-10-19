package Odoo::Ops::Plan;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Digest::SHA ();
use JSON::PP ();
use Odoo::JSON ();

use File::Basename ();
use File::Spec ();

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Blob;

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
composer), C<route> (a call of an Odoo web route, below), C<skip> and C<hold>
(nothing is sent; C<hold> means it needs a person's decision).

A C<route> change calls a web route of Odoo as the login, for what Odoo's own
client does over the web because the method behind it is private or its record
rule refuses a plain write. It carries C<path> (starting with C</>), C<params>
(a map, the JSON the route takes), an optional C<< precondition => { model, ids,
fields => { field => value } } >> (a read the apply makes first: the fields of
those records must hold those values, or the change is refused C<stale> and
nothing is sent) and an optional C<< verify => { model, ids, fields => { field =>
value } } >> (read back after the route; the change is verified when they
hold) and an optional C<fault_note>, words that follow Odoo's own message when the route
faults. The operation declares the paths it may call in C<routes>
(L<Odoo::Ops::Operation>), and the guard refuses any other at apply. A C<model>,
when given, names the model the route changes (for its invariants and
behaviours). A route has no inverse: a revert holds it C<irreversible>.

A C<custom> change lists the calls its apply makes as C<< calls => [ [ model,
method ], ... ] >> (physical model names, the C<read> of its read-backs
included), so the operation's scope is checked when the plan is made
(L<Odoo::Ops::Operation/check_plan_scope>); one that lists none is checked by
the guard at apply.

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

C<add> refuses any other C<unique_by> (a list, for one) with a C<usage> error that names
the change's key and the forms allowed; it is not left to fail inside Odoo at apply.

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


=head2 Large values

A value over C<blob_min> (the config key, default 64 KiB) and every C<datas>
and C<raw> value of an C<ir.attachment> are kept once, outside the plan:
C<finalize> replaces each by C<< { blob => 'sha256:HEX', bytes => N, type =>
'base64' } >> in the changes and the params, and holds the value in memory.
C<save> writes the values to C<blobs/HEX> beside the plan (0600), so the seal
covers the digest and a plan stays small. A plan from C<load> reads them from
the folder it came from. See L<Odoo::Ops::Blob>.

=head2 blob_source(@dirs)

A reader of the plan's blobs: the values held in memory, then the C<blobs/>
of the plan's own folder and of each directory given.

=head2 write_blobs($dir)

Writes the blobs the plan holds in memory to C<$dir/blobs> unless they are there.

=head2 blob_refs

Every blob reference in the plan's changes.

=cut

# Every bucket (with the actions it carried) each operation has planned in this
# process. A test hook: t/99-declared-buckets.t checks that an operation
# declares what it produces. Set OOM_PLAN_OBSERVE to a file and every
# process appends what it saw there when it ends.
our %OBSERVED;
# and one hold's reason per bucket, under the key __hold_reasons, for t/99 to print the line as the screens do
our %OBSERVED_REASON;
# and the custom changes that declared no calls, by operation and kind, for t/99-undeclared-calls.t
our %OBSERVED_NOCALLS;
END {
    if ( $ENV{OOM_PLAN_OBSERVE} && %OBSERVED && open my $fh, '>>', $ENV{OOM_PLAN_OBSERVE} ) {
        print {$fh} Odoo::JSON->new( utf8 => 0 )->encode( { %OBSERVED, __hold_reasons => \%OBSERVED_REASON, __no_calls => \%OBSERVED_NOCALLS } ), "\n";
        close $fh;
    }
}

my %ACTION = map { $_ => 1 } qw(create write unlink call custom route skip hold);

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
        blob_min    => $args{blob_min},
        ( $args{acts_for} ? ( acts_for => $args{acts_for} ) : () ),
        blobs       => {},
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

=head2 acts_for

C<< { uid, login, name, partner_id, commercial_partner_id, via } >> for a plan an operation that acts for a person
made (L<Odoo::Ops::Acting>): the person the writes are for and the service login that applies them, or undef.
The seal covers it, so an edited person is an edited plan; the runner applies the plan only for that person.

=cut

sub acts_for ($self) { $self->{acts_for} }

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
    # ids that were Perl hash keys are strings; Odoo takes numbers, and a value that is no id is refused by name
    for my $k (qw(id ids)) {
        next if !defined $c{$k} || $c{action} !~ /^(?:write|unlink|call)\z/;
        my @v = ref $c{$k} eq 'ARRAY' ? @{ $c{$k} } : ( $c{$k} );
        for (@v) {
            Odoo::Error->throw( kind => 'usage', message => "$c{action} of '" . ( $c{key} // $c{model} ) . "': $k must be record ids (whole numbers), got '" . ( ref $_ ? ref($_) . ' reference' : $_ ) . "'" )
                if ref $_ || !defined $_ || !/\A[0-9]+\z/;
            $_ = 0 + $_;
        }
        $c{$k} = ref $c{$k} eq 'ARRAY' ? \@v : $v[0];
    }
    if ( $c{action} eq 'route' ) {
        my $me = 'route change' . ( defined $c{key} ? " '$c{key}'" : '' );
        Odoo::Error->throw( kind => 'usage', message => "$me needs a path starting with /" )
            if !defined $c{path} || ref $c{path} || $c{path} !~ m{\A/\S*\z};
        $c{params} //= {};
        Odoo::Error->throw( kind => 'usage', message => "$me: fault_note must be text" ) if ref $c{fault_note};
        Odoo::Error->throw( kind => 'usage', message => "$me: params must be a map" ) if ref $c{params} ne 'HASH';
        for my $k (qw(precondition verify)) {
            next if !defined $c{$k};
            my $r = $c{$k};
            Odoo::Error->throw( kind => 'usage', message => "$me: $k is { model, ids => [...], fields => { field => value } }" )
                if ref $r ne 'HASH' || !length( $r->{model} // '' ) || ref $r->{ids} ne 'ARRAY' || !@{ $r->{ids} } || ref $r->{fields} ne 'HASH' || !%{ $r->{fields} };
            my @ids = map {
                Odoo::Error->throw( kind => 'usage', message => "$me: $k ids must be record ids (whole numbers), got '" . ( ref $_ ? ref($_) . ' reference' : $_ // 'undef' ) . "'" )
                    if ref $_ || !defined $_ || !/\A[0-9]+\z/;
                0 + $_;
            } @{ $r->{ids} };
            $c{$k} = { %$r, ids => \@ids };
        }
    }
    if ( $c{action} eq 'custom' ) {
        Odoo::Error->throw( kind => 'usage', message => "the calls of the custom change '" . ( $c{key} // $c{handler} ) . "' are not a list of [model, method] pairs",
            fix => 'write calls => [ [ model, method ], ... ], in physical model names, as the apply of the change makes them' )
            if defined $c{calls} && ( ref $c{calls} ne 'ARRAY' || grep { ref $_ ne 'ARRAY' || @$_ != 2 || grep { !defined $_ || ref $_ || !length } @$_ } @{ $c{calls} } );
    }
    Odoo::Error->throw( kind => 'usage', message => 'call needs a method' )
        if $c{action} eq 'call' && !$c{method};
    Odoo::Error->throw( kind => 'usage', message => 'custom needs a handler (the operation name)' )
        if $c{action} eq 'custom' && !$c{handler};
    if ( defined $c{unique_by} && ref $c{unique_by} ne 'HASH' && ref $c{unique_by} ne '' ) {
        Odoo::Error->throw( kind => 'usage',
            message => "unique_by of the change '" . ( $c{key} // $c{ref} // $c{model} // '?' ) . "' is a " . lc( ref $c{unique_by} ) . ' reference; it is a field name, or a hash ({ field => ..., fold => 1 } or { fields => [ ... ] })',
            fix => "write unique_by => 'field', or unique_by => { fields => [ 'a', 'b' ] } for a composite key" );
    }
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
    $OBSERVED_NOCALLS{ $c{handler} }{ $c{kind} // '' } = 1 if $c{action} eq 'custom' && !defined $c{calls};
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
    $self->_externalise;
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
    $self->{frozen}      = Odoo::Ops::seal_json()->encode( $self->_sealed_part );
    $self->{fingerprint} = Digest::SHA::sha256_hex( $self->{frozen} );
    my @refs = map { $_->{effects_ref} } @{ $self->{changes} };
    my $copy = Odoo::Ops::json()->decode( $self->{frozen} );
    $self->{$_} = $copy->{$_} for keys %$copy;
    for my $i ( 0 .. $#refs ) { $self->{changes}[$i]{effects_ref} = $refs[$i] if defined $refs[$i] }
    return $self;
}

# The large values leave the plan before it is sealed: the params and every change carry references,
# the values wait in memory for save. A plan is made once, so nothing here runs twice on one.
sub _externalise ($self) {
    my $min   = $self->{blob_min} // Odoo::Ops::Blob->min_default;
    my $store = $self->{blobs} //= {};
    $self->{params}  = Odoo::Ops::Blob->externalise( $self->{params}, min => $min, store => $store );
    $self->{changes} = [ map { Odoo::Ops::Blob->externalise( $_, min => $min, store => $store ) } @{ $self->{changes} } ];
    return;
}

sub blob_dir ($self) { $self->{blob_dir} }

sub blob_source ($self, @dirs) {
    return Odoo::Ops::Blob->source( dirs => [ @dirs, $self->{blob_dir} ], mem => $self->{blobs} );
}

=head2 blob_value($text)

Holds $text as a blob whatever its size and returns its reference, for a value
that is a file's bytes (see L<Odoo::Ops::File>): the plan carries the reference,
C<plan.json> never the content. The value is written with the plan at save.

=cut

sub blob_value ($self, $text) {
    return Odoo::Ops::Blob->externalise( $text, min => 0, store => ( $self->{blobs} //= {} ) );
}

sub blob_refs ($self) { return Odoo::Ops::Blob->refs( $self->{changes} ) }

sub write_blobs ($self, $dir) { return Odoo::Ops::Blob->write( $dir, $self->{blobs} // {} ) }


sub _sealed_part ($self) {
    my $part = { map { $_ => $self->{$_} } qw(format op params instance profile scope input_count changes) };
    # present only on a plan made for a person, so the seal of every other plan is what it was
    $part->{acts_for} = $self->{acts_for} if $self->{acts_for};
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
    Odoo::Ops::Blob->write( ( File::Spec->splitpath($path) )[1] || '.', $self->{blobs} // {} ) if %{ $self->{blobs} // {} };
    open my $fh, '>', $path
        or Odoo::Error->throw( kind => 'config', message => "cannot write plan $path: $!" );
    print {$fh} Odoo::JSON->new( pretty => 1 )->encode( $self->to_hash );
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
    my $plan = $class->from_hash($h);
    $plan->{blob_dir} = File::Basename::dirname( File::Spec->rel2abs($path) );
    return $plan;
}

sub from_hash ($class, $h) {
    Odoo::Error->throw( kind => 'refused', code => 'not-a-plan', message => 'this is a result, not a plan',
        fix => 'pass the plan.json of the run, not its result.json' )
        if $h->{applied};
    my $self   = bless { %$h, fingerprint => undef }, $class;
    my $frozen = Odoo::Ops::seal_json()->encode( $self->_sealed_part );
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
