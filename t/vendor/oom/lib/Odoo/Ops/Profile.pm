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
the source tree's C<profiles/>, C</usr/share/odoo-oom/profiles>.

=cut

sub default_dirs ($class, @extra) {
    my $tree = File::Spec->catdir( dirname( __FILE__ ), ('..') x 3, 'profiles' );
    return grep { defined && -d } @extra, $ENV{ODOO_OOM_PROFILES}, $tree,
        '/usr/share/odoo-oom/profiles';
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
    for my $lm ( keys %{ $data{models} } ) {
        my $m = $data{models}{$lm};
        Odoo::Error->throw( kind => 'config', message => "profile model '$lm' needs model and fields" )
            if ref $m ne 'HASH' || !$m->{model} || ref $m->{fields} ne 'HASH';
        # a field may be written as the physical name, ~ (known-absent),
        # or a map { name: physical, portable_type: text } with options
        for my $lf ( keys %{ $m->{fields} } ) {
            my $v = $m->{fields}{$lf};
            next if ref $v ne 'HASH';
            Odoo::Error->throw( kind => 'config', message => "profile field $lm.$lf: map form needs 'name'" )
                if !defined $v->{name};
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
        series           => 0 + $data{series},
        requested_series => 0 + $data{series},
        models           => $data{models},
        field_opts       => \%opts,
        path             => $data{_path},
        warnings         => [],
    }, $class;
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
    return exists $f->{$lf} && defined $f->{$lf};
}

=head2 field($lm, $lf)

The physical field name; undef if the profile marks it absent on this
series; dies if the logical name is not in the profile at all.

=cut

sub field ($self, $lm, $lf) {
    my $f = $self->_model($lm)->{fields};
    Odoo::Error->throw(
        kind    => 'usage',
        message => "profile model '$lm' has no field '$lf'",
    ) if !exists $f->{$lf};
    return $f->{$lf};
}

sub fields ($self, $lm) {
    my $f = $self->_model($lm)->{fields};
    return { map { defined $f->{$_} ? ( $_ => $f->{$_} ) : () } keys %$f };
}

sub physical_fields ($self, $lm) {
    my $f = $self->fields($lm);
    return [ sort values %$f ];
}

=head2 validate($client)

Checks every model and mapped field against the server. Returns
C<< { ok => 0|1, missing => [..], models => n, fields => n } >>, where
each C<missing> entry names the logical and physical side. A model the
server cannot describe (not installed, or no access) is one entry.

=cut

sub validate ($self, $client) {
    my ( @missing, %desc, $nf );
    for my $lm ( $self->models ) {
        my $pm = $self->model_name($lm);
        my $live = eval { $client->model($pm)->fields };
        if ( !$live ) {
            my $err = $@;
            my $why = blessed($err) && $err->isa('Odoo::Error')
                ? ( $err->fault_category // $err->kind )
                : 'error';
            push @missing, "model $lm -> $pm ($why)";
            next;
        }
        my $f = $self->fields($lm);
        for my $lf ( sort keys %$f ) {
            $nf++;
            if ( my $d = $live->{ $f->{$lf} } ) {
                # the server's metadata, a portable reading of its type,
                # and the profile's per-field override on top
                $desc{$lm}{$lf} = { %$d, Odoo::Portable::describe($d), name => $f->{$lf}, %{ $self->field_opts( $lm, $lf ) } };
            }
            else {
                push @missing, "$lm.$lf -> $pm.$f->{$lf}";
            }
        }
    }
    $self->{descriptors} = \%desc;
    $self->{missing}     = \@missing;
    return {
        ok      => @missing ? 0 : 1,
        missing => \@missing,
        models  => scalar( my @m = $self->models ),
        fields  => $nf // 0,
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
        Odoo::Error->throw(
            kind    => 'usage',
            message => "$lm.$lf is not available on series $self->{series}",
        ) if !defined $pf;
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
