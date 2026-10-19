package Odoo::Ops::Matrix;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use File::Basename qw(dirname);
use File::Spec;
use YAML::PP;

use Odoo::Error;

=head1 NAME

Odoo::Ops::Matrix - what OOM offers on which Odoo series, and how that is known

=head1 SYNOPSIS

    my $m = Odoo::Ops::Matrix->load;
    my $cell = $m->cell( 'mailing.send', 16 );     # { grade, evidence }
    say $m->format_text( rows => [ $m->select( kind => 'operation' ) ] );
    my $s = Odoo::Ops::Matrix->instance_series('site.conf');   # { series, db }

=head1 DESCRIPTION

Reads F<matrix.yaml>: one row per operation, transport, tool or feature,
one cell per series, each cell a grade and the evidence for it. The file
is the record; this module only reads and renders it. Nothing here
touches an Odoo instance except C<instance_series>, which asks one for
its version, as C<oom-ops doctor> does.

Grades, strongest claim first: C<live> (proved on that series by a named
live test or run, on a date), C<source> (written from that series'
source, not run against it), C<refused> (the operation refuses the
series by name), C<n/a> (the series has no such feature), C<not-probed>
(nothing known; it does not refuse, it has not been tried). A series a
row leaves out is C<not-probed>: an unknown is never written as known.

The rows come out in the file's order, which is the order a person meets
the operations: grouped by family (core, comms, crm, stock, mailing, sale,
purchase, account, then the transports, the C<accounts> tool, the
C<mailshot> tool), the core family by name, and the features last. The
file carries the order; nothing here sorts. t/43-matrix.t keeps it.

The file is found like profiles are: C<dirs> passed in, then
C<$ENV{ODOO_OOM_MATRIX}> (a file), the source tree, then
F</usr/share/odoo-oom/matrix.yaml>.

=cut

our @KINDS  = qw(operation transport tool feature);
our @GRADES = qw(live source not-probed refused n/a);

# the short forms the table prints
my %SHORT = ( 'live' => 'live', 'source' => 'src', 'refused' => 'ref', 'n/a' => 'n/a', 'not-probed' => '-' );

sub default_files ($class, @extra) {
    my $tree = File::Spec->catfile( dirname(__FILE__), ('..') x 3, 'matrix.yaml' );
    return grep { defined && -f } ( map { -d $_ ? File::Spec->catfile( $_, 'matrix.yaml' ) : $_ } @extra ),
        $ENV{ODOO_OOM_MATRIX}, $tree, '/usr/share/odoo-oom/matrix.yaml';
}

sub load ($class, %args) {
    my ($file) = $class->default_files( @{ $args{dirs} // [] } );
    Odoo::Error->throw( kind => 'config', message => 'matrix.yaml not found (looked beside the source tree and in /usr/share/odoo-oom)' )
        if !$file;
    return $class->from_file($file);
}

sub from_file ($class, $path) {
    my $data = eval { YAML::PP->new( schema => ['Core'] )->load_file($path) }
        or Odoo::Error->throw( kind => 'config', message => "cannot load matrix $path: " . ( $@ || 'empty file' ) );
    return $class->new( %$data, _path => $path );
}

sub new ($class, %data) {
    my $where = $data{_path} // 'matrix';
    my @series = @{ $data{series} // [] };
    Odoo::Error->throw( kind => 'config', message => "$where: 'series' must be a list of series numbers" )
        if !@series || grep { !defined || !/\A\d+\z/ } @series;
    my %known = map { $_ => 1 } @GRADES;
    my ( @rows, %seen );
    for my $r ( @{ $data{rows} // [] } ) {
        my $name = $r->{name} // Odoo::Error->throw( kind => 'config', message => "$where: a row has no name" );
        Odoo::Error->throw( kind => 'config', message => "$where: row '$name' appears twice" ) if $seen{$name}++;
        Odoo::Error->throw( kind => 'config', message => "$where: row '$name' has kind '" . ( $r->{kind} // '' ) . "', not one of @KINDS" )
            if !grep { $_ eq ( $r->{kind} // '' ) } @KINDS;
        my %cells;
        for my $s (@series) {
            my $c = $r->{$s} // { grade => 'not-probed' };
            Odoo::Error->throw( kind => 'config', message => "$where: row '$name' series $s: cell must be a map with a grade" )
                if ref $c ne 'HASH';
            my $g = $c->{grade} // '';
            Odoo::Error->throw( kind => 'config', message => "$where: row '$name' series $s: grade '$g' is not one of @GRADES" )
                if !$known{$g};
            $cells{$s} = { grade => $g, ( defined $c->{evidence} ? ( evidence => "$c->{evidence}" ) : () ) };
        }
        push @rows, { name => $name, kind => $r->{kind}, cells => \%cells };
    }
    return bless { series => [ map { 0 + $_ } @series ], grades => $data{grades} // {}, rows => \@rows, path => $data{_path} }, $class;
}

sub series ($self) { @{ $self->{series} } }
sub rows   ($self) { @{ $self->{rows} } }
sub path   ($self) { $self->{path} }

sub row ($self, $name) {
    my ($r) = grep { $_->{name} eq $name } $self->rows;
    return $r // Odoo::Error->throw( kind => 'usage', message => "no matrix row '$name'" );
}

# A series the file does not list is still a fair question (an instance
# newer than the file): the answer is not-probed, and says why.
sub cell ($self, $name, $series) {
    my $c = $self->row($name)->{cells}{ 0 + $series };
    return $c // { grade => 'not-probed', evidence => "series $series is not in matrix.yaml" };
}

=head2 select(kind =E<gt> K, pack =E<gt> P, name =E<gt> N)

The rows that match every filter given. C<pack> matches an operation's
declared pack (from the registry), so a pack's rows come out together;
other kinds have no pack.

=cut

sub select ($self, %f) {
    my @rows = $self->rows;
    if ( defined $f{kind} ) {
        Odoo::Error->throw( kind => 'usage', message => "unknown kind '$f{kind}' (" . join( ', ', @KINDS ) . ')' )
            if !grep { $_ eq $f{kind} } @KINDS;
        @rows = grep { $_->{kind} eq $f{kind} } @rows;
    }
    if ( defined $f{pack} ) {
        my %pack = $self->_packs;
        @rows = grep { ( $pack{ $_->{name} } // '' ) eq $f{pack} } @rows;
    }
    @rows = $self->row( $f{name} ) if defined $f{name};
    return @rows;
}

# operation name => pack, from the registry; loaded only when asked
sub _packs ($self) {
    # a pack's operations carry the pack's name
    require Odoo::Ops::Registry;
    my $reg = Odoo::Ops::Registry->new;
    return ( ( map { $_ => ( $reg->class_for($_)->pack // $reg->pack_of($_) // '' ) } $reg->names ), %{ $self->{pack_names} // {} } );
}

=head2 with_packs($reg)

Adds a row for each operation of the packs the registry loaded (L<Odoo::Ops::Pack>).
The matrix file grades what OOM proved; a pack's operations are not in it, so
each row is C<not-probed> on every series, its evidence on the series the pack
declares saying so and naming the pack and its version. The row's pack is the
pack's name, so C<select(pack =E<gt> 'crm_page')> finds them.

=cut

sub with_packs ($self, $reg) {
    my %packs = $reg->packs;
    for my $op ( grep { defined $reg->pack_of($_) } $reg->names ) {
        my $p = $packs{ $reg->pack_of($op) };
        $self->{pack_names}{$op} = $p->{name};
        my %declared = map { $_ => 1 } @{ $p->{series} };
        push @{ $self->{rows} }, {
            name => $op, kind => 'operation',
            cells => { map { $_ => { grade => 'not-probed',
                ( $declared{$_} ? ( evidence => "pack $p->{name} $p->{version} declares series $_; its own tests hold the evidence" ) : () ) } } $self->series },
        };
    }
    return $self;
}

=head2 to_data(rows =E<gt> [...], series =E<gt> N)

The rows as plain data, the shape C<--json> prints: a list of
C<< { name, kind, cells => { SERIES => { grade, evidence } } } >>. With
C<series> only that series' cell is kept. C<here> (operation name to C<< { text } >>,
from L<Odoo::Ops::Modules/applicability>) adds a C<here> text to the rows it names.

=cut

sub to_data ($self, %o) {
    my @s = defined $o{series} ? ( 0 + $o{series} ) : $self->series;
    return [ map {
        my $r = $_;
        +{ name => $r->{name}, kind => $r->{kind}, cells => { map { $_ => $self->cell( $r->{name}, $_ ) } @s },
            ( $o{here}{ $r->{name} } ? ( here => $o{here}{ $r->{name} }{text} ) : () ) }
    } @{ $o{rows} // [ $self->rows ] } ];
}

=head2 format_text(rows, series, verbose, heading)

The table: a row per name, a column per series (C<live>, C<src>,
C<ref>, C<n/a>, C<->), then the legend. With C<series> one column and
the kind; with C<verbose> each cell's evidence under its row; with C<here>
(see L</to_data>) a last column says whether the instance's modules make the
operation C<applies> or C<not applicable here (module X)>.

=cut

sub format_text ($self, %o) {
    my @rows = @{ $o{rows} // [ $self->rows ] };
    my @s    = defined $o{series} ? ( 0 + $o{series} ) : $self->series;
    my $w    = 4;
    for ( map { $_->{name} } @rows ) { $w = length if length > $w }
    $w += 2;
    my $out = defined $o{heading} ? "$o{heading}\n" : '';
    my $here = $o{here};
    $out .= sprintf( "%-${w}s", 'operation' ) . join( '', map { sprintf( '%-6s', $_ ) } @s ) . ( @s == 1 ? ( $here ? sprintf( '%-11s', 'kind' ) . 'here' : 'kind' ) : '' ) . "\n";
    for my $r (@rows) {
        $out .= sprintf( "%-${w}s", $r->{name} )
            . join( '', map { sprintf( '%-6s', $SHORT{ $self->cell( $r->{name}, $_ )->{grade} } ) } @s )
            . ( @s == 1 ? ( $here ? sprintf( '%-11s', $r->{kind} ) . ( $here->{ $r->{name} } ? $here->{ $r->{name} }{text} : '' ) : $r->{kind} ) : '' ) . "\n";
        if ( $o{verbose} ) {
            for my $x (@s) {
                my $c = $self->cell( $r->{name}, $x );
                $out .= "    $x  $c->{grade}: $c->{evidence}\n" if defined $c->{evidence};
            }
        }
    }
    $out .= "\nlive = proved by a named live test or run; src = written from source, not run; ref = refused by name;\n"
        . "n/a = the series lacks the feature; - = not probed (it does not refuse, it has not been tried)\n";
    return $out;
}

=head2 format_row($row)

One row with the evidence of every cell, as C<--name> prints it.

=cut

sub format_row ($self, $r) {
    my $out = "$r->{name} ($r->{kind})\n";
    for my $s ( $self->series ) {
        my $c = $self->cell( $r->{name}, $s );
        $out .= sprintf( "  %-3s %-10s %s\n", $s, $c->{grade}, $c->{evidence} // '' );
    }
    return $out;
}

=head2 instance_series($conf_path, transport =E<gt> $t)

C<< { series, db, ctx } >> of the instance a config names, asked the way
C<oom-ops doctor> asks: C<common.version> through the config's own
connection (C<ctx> is that connection). C<transport> is for tests. Reads
nothing else.

=cut

sub instance_series ($class, $path, %o) {
    require Odoo::Ops::Config;
    require Odoo::Ops::Context;
    my $config = Odoo::Ops::Config->load($path);
    my @test;
    if ( !$o{transport} && ( my $pkg = $ENV{OOM_OPS_TEST_TRANSPORT} ) ) {    # as bin/oom-ops does, so the command can be driven offline
        require( $pkg =~ s{::}{/}gr . '.pm' );
        @test = $pkg->context_args;
    }
    my $ctx    = Odoo::Ops::Context->new( config => $config, @test, ( $o{transport} ? ( transport => $o{transport} ) : () ) );
    return { series => $ctx->client->server_series, db => $config->get('db'), ctx => $ctx };
}

1;

=head1 SEE ALSO

C<oom-ops matrix>, F<matrix.yaml>, F<docs/OPS.md> (What runs where).

=cut
