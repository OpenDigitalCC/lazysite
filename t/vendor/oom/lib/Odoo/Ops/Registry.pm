package Odoo::Ops::Registry;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use File::Basename ();
use File::Spec;
use JSON::PP ();
use Time::HiRes ();

use Odoo::Cache;
use Odoo::Error;
use Odoo::Ops::Pack;

=head1 NAME

Odoo::Ops::Registry - discover named operations by namespace

=head1 SYNOPSIS

    my $reg = Odoo::Ops::Registry->new;              # default namespaces
    say for $reg->names;                             # crm.export, ... (loads nothing)
    my $class = $reg->class_for('crm.export');       # loads that one module

=head1 DESCRIPTION

Knows the operations of each namespace (the C<.pm> files directly under its
directory on C<@INC> that are L<Odoo::Ops::Operation> subclasses, keyed by
C<op_name>) from an index, and loads a module only when its operation is
asked for, so a process that runs one operation pays for one module. A new
function pack is a new namespace - pass C<namespaces>, or add it to
C<$ENV{ODOO_OPS_NAMESPACES}> (comma-separated). Two operations claiming one
name is an error, not a last-one-wins.

The index of the shipped namespaces is C<registry-index.json> beside this
module, written by C<scripts/build-registry-index.pl> when the package is
built. A namespace the shipped index does not cover is scanned once and its
index kept in C<registry-index.json> in the cache directory
(L<Odoo::Cache>), checked against the module files' names and times on every
start, so an added or changed module is seen. A namespace whose directory
holds modules the shipped index does not list is treated the same way.

The operations of packs (L<Odoo::Ops::Pack>) come from the directories a config
names in C<pack_dirs> (or C<$ENV{ODOO_OOM_PACK_DIRS}>, else the installed
C</usr/share/odoo-oom/packs>), limited by C<pack>. Each pack's operations are
named C<E<lt>packE<gt>.E<lt>opE<gt>>; the scan of a pack is kept in
C<pack-index.json> in the cache directory, checked on every start against the
pack's version and its files' names, sizes, times and content digests, and the pack's C<lib/>
joins C<@INC> only when one of its operations loads. A pack that fails its
checks is refused (L</refused>) and its operations are absent; asking for one
says why. C<< Odoo::Ops::Registry->use_config($config) >> makes the registries
a process makes without arguments read that config's packs (a context does so
when it is made).

C<names> needs no module loaded. C<list>, C<describe> and C<matrix> load every
operation by asking C<class_for> for each name. A name the index does not hold
is looked for by scanning every namespace, and that is said once on standard
error.

=cut

my @DEFAULT = qw(Odoo::Ops::Core Odoo::Ops::CRM Odoo::Ops::Comms Odoo::Ops::Stock Odoo::Ops::Mailing Odoo::Ops::Documents Odoo::Ops::Discuss);

my $SAID;       # the full scan has been announced in this process
my $SHIPPED;    # the shipped index, read once per process (a plan's changes each ask for a registry)
my %CHECKED;    # shipped namespaces whose file names agreed with the index, once per process

my $CONFIG;     # the config whose packs a registry made without arguments reads

sub default_namespaces ($class) { @DEFAULT }

=head2 use_config($config)

Makes registries made without arguments in this process read the packs
C<$config> names (C<pack_dirs>, C<pack>). C<undef> goes back to the
environment and the installed packs.

=cut

sub use_config ($class, $config) { $CONFIG = $config; return }

sub new ($class, %args) {
    my @ns = @{ $args{namespaces} // [
        @DEFAULT, grep { length } split /\s*,\s*/, $ENV{ODOO_OPS_NAMESPACES} // ''
    ] };
    my $self = bless {
        ops    => {},
        ns     => \@ns,
        cache  => $args{cache_dir} ? Odoo::Cache->new( dir => $args{cache_dir} ) : Odoo::Cache->new,
        loaded => {},
        packs   => {},
        refused => [],
        pack_of => {},
    }, $class;
    my $shipped = $class->_shipped_index;
    for my $ns (@ns) {
        my $ops = $self->_known( $ns, $shipped );
        $self->_merge($ops);
    }
    # a registry of an explicit namespace list (the index builder, a test of core) has no packs unless asked
    $self->_add_packs( $args{config} // $CONFIG, %args ) if !$args{namespaces} || $args{packs};
    return $self;
}

# the packs of the configured directories: discovered, checked, their operations indexed
sub _add_packs ($self, $config, %args) {
    my @dirs = $args{pack_dirs} ? @{ $args{pack_dirs} }
        : $config ? $config->pack_dirs
        : do { my $v = $ENV{ODOO_OOM_PACK_DIRS}; defined $v && length $v ? ( grep { length } split /:/, $v ) : ( grep { -d } '/usr/share/odoo-oom/packs' ) };
    my @only = $args{pack} ? @{ $args{pack} } : $config ? $config->pack_only : ();
    my $d = Odoo::Ops::Pack->discover( \@dirs, only => \@only );
    $self->{refused} = [ @{ $d->{refused} } ];
    my %keep;
    for my $name ( sort keys %{ $d->{packs} } ) {
        my $m   = $d->{packs}{$name};
        my $ops = eval { $self->_pack_ops($m) };
        if ( !$ops ) {
            push @{ $self->{refused} }, { name => $name, dir => $m->{dir}, reason => Odoo::Ops::Pack::_msg($@) };
            next;
        }
        if ( my ($bad) = grep { index( $_, "$name." ) != 0 } sort keys %$ops ) {
            push @{ $self->{refused} }, { name => $name, dir => $m->{dir}, reason => "pack $name: operation '$bad' is not named $name.<op>" };
            next;
        }
        $keep{$name} = $m;
        $self->{pack_of}{$_} = $name for keys %$ops;
        $self->_merge($ops);
    }
    $self->{packs} = \%keep;
    Odoo::Ops::Pack->set_roots( map { $keep{$_} } sort keys %keep );
    return;
}

=head2 packs

The loaded packs: name => manifest (C<name version oom_min namespace series summary dir>).

=head2 refused

The packs that were refused: a list of C<< { name, dir, reason } >>.

=head2 pack_of($op)

The pack an operation belongs to, or undef for a core operation.

=cut

sub packs   ($self) { %{ $self->{packs} } }
sub refused ($self) { @{ $self->{refused} } }
sub pack_of ($self, $op) { $self->{pack_of}{$op} }

# name => package of a pack's operations: from the kept index while the pack's version and files agree, else a scan
sub _pack_ops ($self, $m) {
    my $sig  = $self->_pack_signature($m);
    my $kept = $self->{cache}->recall('pack-index.json');
    my $key  = File::Spec->rel2abs( $m->{dir} );
    return $kept->{$key}{ops} if ref $kept eq 'HASH' && ref $kept->{$key} eq 'HASH' && ( $kept->{$key}{signature} // '' ) eq $sig;
    my $ops = do {
        local @INC = ( $m->{lib}, @INC );
        $self->scan_namespace( $m->{namespace} );
    };
    $kept = {} if ref $kept ne 'HASH';
    $kept->{$key} = { signature => $sig, ops => $ops };
    $self->{cache}->keep( 'pack-index.json', $kept );
    return $ops;
}

# what a kept pack index is checked against: the version, pack.yaml and the pack's module files, by name, size and time
sub _pack_signature ($self, $m) {
    my @parts = ( $m->{version} );
    my $dir   = File::Spec->catdir( $m->{lib}, split /::/, $m->{namespace} );
    for my $f ( File::Spec->catfile( $m->{dir}, 'pack.yaml' ), $self->_pack_modules($dir) ) {
        push @parts, join ':', File::Spec->abs2rel( $f, $m->{dir} ), Odoo::Ops::Pack->file_stamp($f);
    }
    return join ';', @parts;
}

sub _pack_modules ($self, $dir) {
    opendir my $dh, $dir or return ();
    my @f = map { File::Spec->catfile( $dir, $_ ) } sort grep { /\A\w+\.pm\z/ } readdir $dh;
    closedir $dh;
    return @f;
}

sub _merge ($self, $ops) {
    for my $name ( sort keys %$ops ) {
        my $pkg = $ops->{$name};
        Odoo::Error->throw(
            kind    => 'config',
            message => "operation '$name' claimed by both $self->{ops}{$name} and $pkg",
        ) if $self->{ops}{$name} && $self->{ops}{$name} ne $pkg;
        $self->{ops}{$name} = $pkg;
    }
}

sub _shipped_path ($class) {
    return File::Spec->catfile( File::Basename::dirname( $INC{'Odoo/Ops/Registry.pm'} // __FILE__ ), 'registry-index.json' );
}

sub _shipped_index ($class) {
    return $SHIPPED //= do {
        my $path = $class->_shipped_path;
        my $raw  = do { open my $fh, '<:raw', $path or return {}; local $/; <$fh> };
        my $idx  = eval { JSON::PP->new->utf8->decode($raw) };
        ref $idx eq 'HASH' && ref $idx->{namespaces} eq 'HASH' ? $idx->{namespaces} : {};
    };
}

# the .pm files of a namespace across @INC: [ dir, file ] pairs in a stable order
sub _files ($class, $ns) {
    my $rel = File::Spec->catdir( split /::/, $ns );
    my ( %seen, @out );
    for my $inc ( grep { !ref } @INC ) {
        my $dir = File::Spec->catdir( $inc, $rel );
        next if !-d $dir;
        opendir my $dh, $dir or next;
        for my $f ( sort grep { /^\w+\.pm\z/ } readdir $dh ) {
            next if $seen{$f}++;
            push @out, [ $dir, $f ];
        }
        closedir $dh;
    }
    return @out;
}

sub _names_of ($class, $ns) { join ',', sort map { $_->[1] } $class->_files($ns) }

# the file names and times of a namespace: what a kept index is checked against
sub _signature ($class, $ns) {
    return join ';', map {
        my @st = stat File::Spec->catfile(@$_);
        "$_->[1]:" . ( $st[9] // 0 ) . ':' . ( $st[7] // 0 )
    } $class->_files($ns);
}

# name => package for one namespace, without loading anything when an index answers
sub _known ($self, $ns, $shipped) {
    my $s = $shipped->{$ns};
    return $s->{ops} if $s && ( $CHECKED{$ns} ||= ( $s->{files} // '' ) eq $self->_names_of($ns) );

    my $kept = $self->{cache}->recall('registry-index.json');
    my $sig  = $self->_signature($ns);
    return $kept->{$ns}{ops} if ref $kept eq 'HASH' && ref $kept->{$ns} eq 'HASH' && ( $kept->{$ns}{signature} // '' ) eq $sig;

    my $ops = $self->scan_namespace($ns);
    $kept = {} if ref $kept ne 'HASH';
    # the signature is taken after the scan loaded the modules: nothing else changes the files
    $kept->{$ns} = { signature => $self->_signature($ns), ops => $ops };
    $self->{cache}->keep( 'registry-index.json', $kept );
    return $ops;
}

=head2 scan_namespace($ns)

Loads every module of the namespace and answers name => package for the
operations in it. The index builder and the fallback use it.

=cut

sub scan_namespace ($class, $ns) {
    my $rel = File::Spec->catdir( split /::/, $ns );
    my %ops;
    for my $pair ( $class->_files($ns) ) {
        my $f   = $pair->[1];
        my $pkg = $ns . '::' . ( $f =~ s/\.pm\z//r );
        require( File::Spec->catfile( $rel, $f ) );
        next if !$pkg->isa('Odoo::Ops::Operation');
        my $name = $pkg->op_name;
        Odoo::Error->throw(
            kind    => 'config',
            message => "operation '$name' claimed by both $ops{$name} and $pkg",
        ) if $ops{$name} && $ops{$name} ne $pkg;
        $ops{$name} = $pkg;
    }
    return \%ops;
}

sub names ($self) { sort keys %{ $self->{ops} } }

sub _load ($self, $name) {
    my $pkg = $self->{ops}{$name} or return undef;
    return $pkg if $self->{loaded}{$pkg};
    # a pack's modules are found only once one of its operations is asked for
    if ( my $pk = $self->{pack_of}{$name} ) {
        my $lib = $self->{packs}{$pk}{lib};
        unshift @INC, $lib if !grep { !ref && $_ eq $lib } @INC;
    }
    ( my $file = "$pkg.pm" ) =~ s{::}{/}g;
    my $ok = eval { require $file; 1 };
    # an index that names a module that is gone, or one that no longer holds the operation, is stale
    return undef if !$ok || !$pkg->isa('Odoo::Ops::Operation') || $pkg->op_name ne $name;
    return $self->{loaded}{$pkg} = $pkg;
}

# every namespace scanned: the way back from an index that does not know the name
sub _scan_all ($self) {
    if ( !$SAID++ ) {
        print {*STDERR} "oom: operation index does not hold the name asked for; scanning every namespace (slow once)\n";
    }
    my %pack_ops = map { $_ => $self->{ops}{$_} } keys %{ $self->{pack_of} };
    $self->{ops} = {};
    $self->{loaded} = {};
    $self->_merge( $self->scan_namespace($_) ) for @{ $self->{ns} };
    $self->_merge( \%pack_ops );
}

sub class_for ($self, $name) {
    my $pkg = $self->_load($name);
    # an operation of a pack that was refused says why, by the pack's name, before any scan
    if ( !$pkg && $name =~ /\A([a-z][a-z0-9-]*)\./ ) {
        my $n = $1;
        my ($r) = grep { $_->{name} eq $n } $self->refused;
        Odoo::Error->throw( kind => 'config', message => $r->{reason}, fix => 'oom-ops doctor --conf <conf> lists the packs and why one was refused' ) if $r;
    }
    if ( !$pkg ) {
        $self->_scan_all;
        $pkg = $self->_load($name);
    }
    return $pkg // Odoo::Error->throw(
        kind    => 'usage',
        message => "no operation '$name' (known: " . join( ', ', $self->names ) . ')',
        fix     => 'oom-ops list names the operations',
    );
}

1;
