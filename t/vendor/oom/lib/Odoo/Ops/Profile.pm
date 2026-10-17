package Odoo::Ops::Profile;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use File::Basename qw(dirname);
use File::Spec;
use Scalar::Util qw(blessed);
use YAML::PP;
use Odoo::Portable;

use Odoo::Error;

=head1 NAME

Odoo::Ops::Profile - logical schema for a function pack, per Odoo series

=head1 SYNOPSIS

    my $p = Odoo::Ops::Profile->load(pack => 'crm', series => 16);
    my $v = $p->validate($odoo);           # { ok, missing => [...] }
    $p->model_name('lead');                # 'crm.lead'
    $p->field(lead => 'email');            # 'email_from'
    my $vals = $p->to_physical(lead => { email => 'a@b.example' });
    my $row  = $p->to_logical(lead => $search_read_row);

=head1 DESCRIPTION

Operations never name a physical model or field. They speak logical
names (C<lead.email>) and a profile maps them to what a given Odoo
series calls them. A profile is a YAML file,
C<< <root>/<pack>/<series>.yaml >>:

    pack: crm
    series: 16
    models:
      lead:
        model: crm.lead
        fields:
          email: email_from
          mobile: ~          # explicitly absent on this series

Loading picks the file for the server's series, or the nearest lower
one with a warning (a 17 server with only a 16 profile loads 16 and
says so). C<validate> then checks every mapping against the live
C<fields_get>: a mapped field the server lacks is a finding that names
it, never a silent skip. A field mapped to C<~> is known-absent: asking
to write it is refused by name, reading it yields nothing.

After C<validate>, C<descriptor> returns the server's field metadata
(type, string, required, readonly, relation, selection, help) under the
logical name, plus a portable reading of the type for consumers that
know nothing of Odoo: C<portable_type> (one of text integer decimal
boolean date datetime enum, see L<Odoo::Portable>), with C<values> and
C<labels> for an enum and C<places> for a decimal. A type with no
single portable reading carries none; a profile overrides per field
with the map form C<< logical: { name: physical, portable_type: text } >>.

Roots searched, in order: C<dirs> passed in, C<$ENV{ODOO_OOM_PROFILES}>,
the source tree's C<profiles/>, C</usr/share/odoo-oom/profiles>, then the
C<profiles/> of each loaded pack (L<Odoo::Ops::Pack>).

=cut

# core's own roots: what a pack may not replace
sub core_dirs ($class) {
    my $tree = File::Spec->catdir( dirname( __FILE__ ), ('..') x 3, 'profiles' );
    return grep { defined && -d } $ENV{ODOO_OOM_PROFILES}, $tree, '/usr/share/odoo-oom/profiles';
}

sub default_dirs ($class, @extra) {
    require Odoo::Ops::Pack;
    return grep { defined && -d } @extra, $class->core_dirs, Odoo::Ops::Pack->roots('profiles');
}

sub load ($class, %args) {
    my $pack   = $args{pack}   or Odoo::Error->throw( kind => 'usage', message => 'profile needs pack' );
    my $series = $args{series} or Odoo::Error->throw( kind => 'usage', message => 'profile needs series' );
    my @dirs   = $class->default_dirs( @{ $args{dirs} // [] } );

    for my $root (@dirs) {
        my $dir = File::Spec->catdir( $root, $pack );
        next if !-d $dir;
        opendir my $dh, $dir or next;
        my @have = sort { $b <=> $a } map { /^(\d+)\.yaml\z/ ? $1 : () } readdir $dh;
        closedir $dh;
        my ($pick) = grep { $_ <= $series } @have;
        next if !defined $pick;
        my $self = $class->from_file( File::Spec->catfile( $dir, "$pick.yaml" ) );
        $self->{requested_series} = 0 + $series;
        push @{ $self->{warnings} },
            "no $pack profile for series $series; using $pick - validate before trusting it"
            if $pick != $series;
        return $self;
    }
    # no directory for the pack in any root: OOM has no such pack (a model of it is reached
    # through the general operations). A directory whose files are all newer is a series gap.
    Odoo::Error->throw(
        kind    => 'usage',
        message => "no $pack pack: OOM has no profile for $pack; core.read, core.import and core.action reach its models",
        fix     => 'oom-ops describe core.read lists the parameters; the model is a physical name such as res.partner',
    ) if !grep { -d File::Spec->catdir( $_, $pack ) } @dirs;
    Odoo::Error->throw(
        kind    => 'config',
        message => "no $pack profile at or below series $series in: " . join( ', ', @dirs ),
    );
}

sub from_file ($class, $path) {
    my $data = eval { YAML::PP->new( schema => ['Core'] )->load_file($path) }
        or Odoo::Error->throw( kind => 'config', message => "cannot load profile $path: $@" );
    return $class->new( %$data, _path => $path );
}

sub new ($class, %data) {
    for my $req (qw(pack series models)) {
        Odoo::Error->throw( kind => 'config', message => "profile missing '$req'" )
            if !defined $data{$req};
    }
    my %opts;
    my $bad_module = sub ($v) { ref $v || !length( $v // '' ) };
    Odoo::Error->throw( kind => 'config', message => 'profile module must be a module name' )
        if exists $data{module} && $bad_module->( $data{module} );
    for my $lm ( keys %{ $data{models} } ) {
        my $m = $data{models}{$lm};
        Odoo::Error->throw( kind => 'config', message => "profile model '$lm' needs model and fields" )
            if ref $m ne 'HASH' || !$m->{model} || ref $m->{fields} ne 'HASH';
        Odoo::Error->throw( kind => 'config', message => "profile model '$lm': module must be a module name" )
            if exists $m->{module} && $bad_module->( $m->{module} );
        # a field may be written as the physical name, ~ (known-absent),
        # or a map { name: physical, portable_type: text } with options
        for my $lf ( keys %{ $m->{fields} } ) {
            my $v = $m->{fields}{$lf};
            next if ref $v ne 'HASH';
            Odoo::Error->throw( kind => 'config', message => "profile field $lm.$lf: map form needs 'name'" )
                if !defined $v->{name};
            Odoo::Error->throw( kind => 'config', message => "profile field $lm.$lf: module must be a module name" )
                if exists $v->{module} && $bad_module->( $v->{module} );
            Odoo::Error->throw( kind => 'config',
                message => "profile field $lm.$lf: portable_type '$v->{portable_type}' is not one of "
                    . join( ' ', Odoo::Portable::portable_types() ) )
                if defined $v->{portable_type} && !Odoo::Portable::is_portable_type( $v->{portable_type} );
            $opts{$lm}{$lf} = { map { $_ => $v->{$_} } grep { $_ ne 'name' } keys %$v };
            $m->{fields}{$lf} = $v->{name};
        }
    }
    return bless {
        pack             => $data{pack},
        module           => $data{module},
        series           => 0 + $data{series},
        requested_series => 0 + $data{series},
        models           => $data{models},
        actions          => $data{actions} // {},
        states           => $data{states} // {},
        field_opts       => \%opts,
        path             => $data{_path},
        warnings         => [],
    }, $class;
}

=head2 action($name)

The physical name a pack calls for a logical action or xml id (a method
such as C<action_send_mail>, a cron's xml id), from the profile's
C<actions> map. A profile that does not name it is a finding, not a
guess: C<config>, naming the action and the profile. This is where a
series that renames a method is a profile away.

=cut

sub action ($self, $name) {
    my $v = $self->{actions}{$name};
    return $v if defined $v;
    Odoo::Error->throw(
        kind    => 'config',
        message => "profile $self->{pack}/$self->{series} names no action '$name'",
    );
}

=head2 states($verb)

The state rule a pack keeps beside its actions, for a state operation:
C<< { from => [..], to => [..], context => {..}, hints => { state => text } } >>
(C<from> the states Odoo's action works from, C<to> the states that count
as done, C<hints> what to do from a state the action refuses). A profile
that has none for the verb is a finding, not a guess: C<config>.

=cut

sub states ($self, $verb) {
    my $v = $self->{states}{$verb};
    return $v if ref $v eq 'HASH';
    Odoo::Error->throw(
        kind    => 'config',
        message => "profile $self->{pack}/$self->{series} names no state rule '$verb'",
    );
}

=head2 field_opts($lm, $lf)

The options given for a field in its map form (e.g. C<portable_type>),
or an empty hash.

=cut

sub field_opts ($self, $lm, $lf) { $self->{field_opts}{$lm}{$lf} // {} }

sub pack             ($self) { $self->{pack} }
sub series           ($self) { $self->{series} }
sub requested_series ($self) { $self->{requested_series} }
sub path             ($self) { $self->{path} }
sub warnings         ($self) { $self->{warnings} }
sub validated        ($self) { !!$self->{descriptors} }

sub models ($self) { sort keys %{ $self->{models} } }

sub _model ($self, $lm) {
    return $self->{models}{$lm} // Odoo::Error->throw(
        kind    => 'usage',
        message => "profile $self->{pack}/$self->{series} has no model '$lm'",
    );
}

sub model_name ($self, $lm) { $self->_model($lm)->{model} }

sub has_field ($self, $lm, $lf) {
    my $f = $self->_model($lm)->{fields};
    return exists $f->{$lf} && defined $f->{$lf} && !$self->absent_here( $lm, $lf );
}

=head2 module / model_module($lm) / field_module($lm, $lf)

The module a pack, a model or a field needs, when the profile names one
(C<module:> beside C<pack:>, in a model, or in a field's map form), else
undef. The pack's module is the one without which the pack has nothing to
work on (C<mass_mailing> for the mailing pack). A model or field that comes
from an optional module names it, so that a server without the module
reports it as not applicable here and not as a mismatch:

    lot:
      model: stock.lot
      fields:
        expiration: { name: expiration_date, module: product_expiry }

=cut

sub module       ($self) { $self->{module} }
sub model_module ($self, $lm) { $self->_model($lm)->{module} }
sub field_module ($self, $lm, $lf) { $self->field_opts( $lm, $lf )->{module} }

=head2 absent_here($lm, $lf)

After L</validate> on a server whose installed modules were read: the module
whose absence leaves the field out (the field itself, or its model), else
undef. Such a field is read as known-absent: C<field> gives undef,
C<fields> and C<has_field> leave it out.

=cut

sub absent_here ($self, $lm, $lf = undef) {
    my $a = $self->{absent_here} or return undef;
    return $a->{$lm}{''} if defined $a->{$lm}{''};
    return defined $lf ? $a->{$lm}{$lf} : undef;
}

=head2 modules_from($code)

A code ref that answers the installed modules as a hash ref (module name
to true), or undef when they cannot be told. L</validate> calls it only
when something is missing and the profile names a module for it; a profile
with no such provider treats every missing field as a mismatch.

=cut

sub modules_from ($self, $code) { $self->{modules_from} = $code; return $self }

=head2 field($lm, $lf)

The physical field name; undef if the profile marks it absent on this
series or its module is not installed here; dies if the logical name is not
in the profile at all.

=cut

sub field ($self, $lm, $lf) {
    my $f = $self->_model($lm)->{fields};
    Odoo::Error->throw(
        kind    => 'usage',
        message => "profile model '$lm' has no field '$lf'",
    ) if !exists $f->{$lf};
    return undef if $self->absent_here( $lm, $lf );
    return $f->{$lf};
}

sub fields ($self, $lm) {
    my $f = $self->_model($lm)->{fields};
    return { map { defined $f->{$_} && !$self->absent_here( $lm, $_ ) ? ( $_ => $f->{$_} ) : () } keys %$f };
}

sub physical_fields ($self, $lm) {
    my $f = $self->fields($lm);
    return [ sort values %$f ];
}

=head2 validate($client)

Checks every model and mapped field against the server. Returns
C<< { ok => 0|1, missing => [..], not_applicable => [..], models => n, fields => n } >>,
where each C<missing> entry names the logical and physical side. A model the
server cannot describe (not installed, or no access) is one entry.

A missing model or field that the profile ties to a module (C<module:>) which
the server does not have installed is not a mismatch: it is listed in
C<not_applicable> (C<lot.expiration: not applicable here, module product_expiry
is not installed>), left out of C<missing>, and read as known-absent from then
on. A missing one whose module is installed, or that names none, or when the
installed modules cannot be read, stays in C<missing>.

=cut

sub validate ($self, $client) {
    my ( @missing, @na, %desc, %absent, $nf, $installed, $asked );
    my $why_not = sub ($module) {
        if ( !$asked++ ) { $installed = $self->{modules_from} ? $self->{modules_from}->() : undef }
        return $installed && !$installed->{$module} ? $module : undef;
    };
    for my $lm ( $self->models ) {
        my $pm = $self->model_name($lm);
        my $live = eval { $client->model($pm)->fields };
        if ( !$live ) {
            my $err = $@;
            my $mod = $self->model_module($lm);
            if ( defined $mod && $why_not->($mod) ) {
                push @na, "$lm: not applicable here, module $mod is not installed";
                $absent{$lm}{''} = $mod;
                next;
            }
            my $why = blessed($err) && $err->isa('Odoo::Error')
                ? ( $err->fault_category // $err->kind )
                : 'error';
            push @missing, "model $lm -> $pm ($why)";
            next;
        }
        my $f = $self->{models}{$lm}{fields};
        for my $lf ( sort grep { defined $f->{$_} } keys %$f ) {
            $nf++;
            if ( my $d = $live->{ $f->{$lf} } ) {
                # the server's metadata, a portable reading of its type,
                # and the profile's per-field override on top
                $desc{$lm}{$lf} = { %$d, Odoo::Portable::describe($d), name => $f->{$lf}, %{ $self->field_opts( $lm, $lf ) } };
            }
            else {
                my $mod = $self->field_module( $lm, $lf ) // $self->model_module($lm);
                if ( defined $mod && $why_not->($mod) ) {
                    push @na, "$lm.$lf: not applicable here, module $mod is not installed";
                    $absent{$lm}{$lf} = $mod;
                    next;
                }
                push @missing, "$lm.$lf -> $pm.$f->{$lf}";
            }
        }
    }
    $self->{descriptors} = \%desc;
    $self->{missing}     = \@missing;
    $self->{absent_here} = \%absent;
    return {
        ok             => @missing ? 0 : 1,
        missing        => \@missing,
        not_applicable => \@na,
        models         => scalar( my @m = $self->models ),
        fields         => $nf // 0,
    };
}

sub descriptor ($self, $lm, $lf) {
    Odoo::Error->throw( kind => 'usage', message => 'descriptor before validate' )
        if !$self->{descriptors};
    return $self->{descriptors}{$lm}{$lf};
}

sub descriptors ($self, $lm) {
    Odoo::Error->throw( kind => 'usage', message => 'descriptors before validate' )
        if !$self->{descriptors};
    return $self->{descriptors}{$lm} // {};
}

=head2 to_physical($lm, \%logical) / to_logical($lm, \%row)

Rename keys between the two sides. C<to_physical> refuses a logical
field the profile does not know or marks absent; C<to_logical> keeps
C<id> and every mapped field present in the row, and drops the rest.

=cut

sub to_physical ($self, $lm, $vals) {
    my %out;
    for my $lf ( keys %$vals ) {
        my $pf = $self->field( $lm, $lf );
        if ( !defined $pf ) {
            my $mod = $self->absent_here( $lm, $lf );
            Odoo::Error->throw(
                kind    => 'usage',
                message => defined $mod ? "$lm.$lf is not applicable here: module $mod is not installed" : "$lm.$lf is not available on series $self->{series}",
            );
        }
        $out{$pf} = $vals->{$lf};
    }
    return \%out;
}

sub to_logical ($self, $lm, $row) {
    my $f = $self->fields($lm);
    my %out;
    $out{id} = $row->{id} if exists $row->{id};
    for my $lf ( keys %$f ) {
        $out{$lf} = $row->{ $f->{$lf} } if exists $row->{ $f->{$lf} };
    }
    return \%out;
}

1;
