package Odoo::Ops::Pack;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use File::Spec;
use Time::HiRes ();
use YAML::PP ();

use Odoo::Error;

=head1 NAME

Odoo::Ops::Pack - the contract a pack stands on, and the loading of packs

=head1 SYNOPSIS

    package Odoo::Pack::CrmPage::Lead;
    use parent 'Odoo::Ops::Operation';
    use Odoo::Error;
    use Odoo::Ops::Pack;

    sub op_name ($class) { 'crm-page.lead' }
    sub report  ($self)  {
        return Odoo::Ops::Pack->read( $self, 'core.get', model => 'crm.lead', id => $self->param('id'), fields => 'name' );
    }

=head1 DESCRIPTION

A pack is a directory of operations for a kind of app or a customer, released
on its own and loaded at run time from C<pack_dirs> (see F<packs/README.md>
and the Packs section of F<docs/OPS.md>). It composes OOM's primitives. It
never changes core behaviour, and core never imports a pack.

=head1 THE CONTRACT

A pack may use only this interface, and a core release that keeps it cannot
break a pack. The pack's C<oom_min> names the contract's version.

=over 4

=item * L<Odoo::Ops::Operation> and the methods its POD documents: the class
methods C<op_name>, C<summary>, C<pack>, C<invariant_packs>, C<params>,
C<read_scope>, C<write_scope>, C<buckets>, C<holds>, C<fields>,
C<models_touched>, and on an instance C<ctx>, C<client>, C<param>,
C<all_params>, C<model>, C<new_plan>, C<fields_for>, C<report> and C<plan>.

=item * The change kinds of L<Odoo::Ops::Plan>: C<create>, C<write>,
C<unlink>, C<call>, C<custom>, C<skip> and C<hold>, with the keys the
operation contract names (C<bucket>, C<key>, C<model>, C<id>, C<vals>,
C<before>, C<method>, C<ids>, C<kwargs>, C<verify>, C<unique_by>,
C<readback>, C<reason>). A pack builds plans with C<< $self->new_plan >> and
C<< $plan->add >> and C<< $plan->note >>.

=item * L<Odoo::Error>, to throw C<usage>, C<config>, C<fault> and
C<refused> errors.

=item * The helpers of L<Odoo::Ops>: C<json> and C<iso_time>.

=item * This module's C<read>, the composition helper below: a pack calls a
core read operation through it, never by loading the core module.

=item * Its own namespace, C<Odoo::Pack::E<lt>NameE<gt>>.

=back

Everything else under C<Odoo::> is core's. A C<use>, C<require> or fully
qualified name of any other C<Odoo::> module, and any call into a core
C<_private> sub, fails the lint (C<t/66-packs.t>, L</lint_pack>).

=head1 METHODS

=head2 read($op, $name, %params)

Runs the read operation C<$name> (C<core.get>, C<core.read>, C<core.report>) for the
operation C<$op>, on its context and inside its scope, and answers its
report. The operation C<$op> declares in its C<read_scope> the models the
composed read touches. A write operation is refused: a pack's writes are its
own plans, applied by the runner like any other.

A read that names its own audit detail (C<core.report> says the report and the
bytes, never the content) is written to the audit trail as a read of its own.
C<core.report> with C<inline =E<gt> 1> returns each document as C<content_base64>
in its rows, so a pack hands a rendered pdf on without a render of its own. The
calling operation declares in its C<read_scope> the models the report reads
(C<ir.actions.report>, C<ir.model.data>, C<ir.attachment> and the model it prints).

=cut

sub read ($class, $op, $name, %params) {
    require Odoo::Ops::Registry;
    my $cls = Odoo::Ops::Registry->new->class_for($name);
    Odoo::Error->throw( kind => 'usage', message => "pack operation " . $op->op_name . " composes $name, which is not a read" )
        if $cls->writes || $cls->immediate;
    my $inner  = $cls->new( ctx => $op->ctx, params => \%params );
    my $report = $inner->report;
    $inner->_audit_read( $inner->scope_for('read'), $report ) if $inner->can('audit_detail');
    return $report;
}

=head2 version_cmp($a, $b)

C<-1>, C<0> or C<1> comparing two dotted versions component by component
(C<0.9> is older than C<0.30>).

=cut

sub version_cmp ($class, $a, $b) {
    my @a = split /\./, $a;
    my @b = split /\./, $b;
    for my $i ( 0 .. ( @a > @b ? $#a : $#b ) ) {
        my $c = ( $a[$i] // 0 ) <=> ( $b[$i] // 0 );
        return $c if $c;
    }
    return 0;
}

sub _running () {
    require Odoo::Ops;
    return $Odoo::Ops::VERSION;
}

=head2 manifest($dir)

The checked C<pack.yaml> of the pack directory C<$dir>, as a hash with
C<name version oom_min namespace series summary dir lib>. A config error
names the pack and the line that is wrong: the name is the directory's, the
version dotted numbers, C<oom_min> not newer than the running OOM
(C<pack crm-page needs OOM 0.31, this is 0.30>), the namespace
C<Odoo::Pack::E<lt>NameE<gt>> and the series a list.

=cut

sub manifest ($class, $dir) {
    ( my $name = $dir ) =~ s{/+\z}{};
    $name =~ s{.*/}{};
    my $path = File::Spec->catfile( $dir, 'pack.yaml' );
    my $bad  = sub ($why) { Odoo::Error->throw( kind => 'config', message => "pack $name: $why", fix => 'packs/README.md says what pack.yaml holds' ) };
    -f $path or $bad->("$path is missing");
    my $m = eval { YAML::PP->new( schema => ['Core'] )->load_file($path) };
    ref $m eq 'HASH' or $bad->( 'pack.yaml cannot be read: ' . ( $@ ? ( $@ =~ s/\s+at \S+ line \d+.*//sr ) : 'not a mapping' ) );
    for my $k (qw(name version oom_min namespace series summary)) {
        $bad->("pack.yaml has no $k") if !defined $m->{$k} || ( ref $m->{$k} eq '' && !length $m->{$k} );
    }
    $bad->("pack.yaml name '$m->{name}' is not the directory name '$name'") if $m->{name} ne $name;
    $bad->( "the name must be lower-case letters, digits and hyphens, starting with a letter" ) if $name !~ /\A[a-z][a-z0-9-]*\z/;
    for my $k (qw(version oom_min)) {
        $bad->("pack.yaml $k '$m->{$k}' is not dotted numbers (such as 0.30)") if $m->{$k} !~ /\A\d+(?:\.\d+)*\z/;
    }
    ( my $camel = join '', map { ucfirst } split /-/, $name );
    $bad->("pack.yaml namespace must be Odoo::Pack::$camel, not '$m->{namespace}'") if $m->{namespace} ne "Odoo::Pack::$camel";
    $bad->('pack.yaml series must be a list') if ref $m->{series} ne 'ARRAY' || !@{ $m->{series} };
    my $running = _running();
    Odoo::Error->throw( kind => 'config', message => "pack $name needs OOM $m->{oom_min}, this is $running",
        fix => "install OOM $m->{oom_min} or newer, or use an older release of the pack" )
        if $class->version_cmp( $m->{oom_min}, $running ) > 0;
    return { %$m, dir => $dir, lib => File::Spec->catdir( $dir, 'lib' ) };
}

=head2 discover(\@dirs, only =E<gt> \@names)

Reads every C<pack.yaml> under the pack directories (each entry holds pack
directories). Answers C<< { packs => { name => manifest }, refused => [ { name,
dir, reason } ] } >>. A pack that fails its checks is refused with the
reason, not thrown, so the other packs and core still load; the refusal is
said by name when an operation of that pack is asked for and by C<doctor>. A
name two directories share refuses both, naming both. A pack whose
C<behaviours/> or C<profiles/> hold a model or pack core already has is
refused (C<core lists hr.leave; a pack may not replace it>). C<only>, the
config's C<pack>, limits which packs load; a name in it that no directory
holds is refused as not found.

=cut

my %MEMO;

sub discover ($class, $dirs, %args) {
    my %only = map { $_ => 1 } @{ $args{only} // [] };
    my ( %seen, @refused );
    for my $root ( grep { defined && length } @$dirs ) {
        next if !-d $root;
        opendir my $dh, $root or next;
        for my $n ( sort grep { !/^\./ } readdir $dh ) {
            my $dir = File::Spec->catdir( $root, $n );
            next if !-d $dir || !-f File::Spec->catfile( $dir, 'pack.yaml' );
            next if %only && !$only{$n};
            push @{ $seen{$n} }, $dir;
        }
        closedir $dh;
    }
    # a registry is made often in one process (every custom change of a plan asks for one): the answer is
    # kept while the manifests it came from are unchanged
    my $memo_key = join "\0", @$dirs, '--', sort keys %only;
    my $sig = join ';', map { my @st = Time::HiRes::stat( File::Spec->catfile( $_, 'pack.yaml' ) ); join ':', $_, $st[7] // 0, $st[9] // 0 } map { @{ $seen{$_} } } sort keys %seen;
    return $MEMO{$memo_key}{result} if $MEMO{$memo_key} && $MEMO{$memo_key}{sig} eq $sig;
    my %packs;
    for my $n ( sort keys %seen ) {
        my @at = @{ $seen{$n} };
        if ( @at > 1 ) {
            push @refused, { name => $n, dir => $_, reason => "pack $n is in both $at[0] and $at[1]; a pack name is loaded once" } for @at;
            next;
        }
        my $m = eval { my $x = $class->manifest( $at[0] ); $class->_not_core( $x ); $x };
        if ($m) { $packs{$n} = $m }
        else    { push @refused, { name => $n, dir => $at[0], reason => _msg($@) } }
    }
    for my $n ( sort grep { !$seen{$_} } keys %only ) {
        push @refused, { name => $n, dir => undef, reason => "pack $n is named in pack but no pack_dirs entry holds it" };
    }
    my $result = { packs => \%packs, refused => \@refused };
    $MEMO{$memo_key} = { sig => $sig, result => $result };
    return $result;
}

sub _msg ($e) { ref $e && $e->can('message') ? $e->message : "$e" =~ s/\s+\z//r }

# a pack adds models and actions; it does not replace what core lists
sub _not_core ($class, $m) {
    require Odoo::Ops::Behaviour;
    require Odoo::Ops::Profile;
    my $bdir = File::Spec->catdir( $m->{dir}, 'behaviours' );
    if ( -d $bdir ) {
        my %core;
        for my $root ( Odoo::Ops::Behaviour->core_dirs ) {
            opendir my $ch, $root or next;
            $core{$_} = 1 for grep { !/^\./ && -d File::Spec->catdir( $root, $_ ) } readdir $ch;
            closedir $ch;
        }
        opendir my $dh, $bdir or return;
        for my $model ( sort grep { !/^\./ && -d File::Spec->catdir( $bdir, $_ ) } readdir $dh ) {
            Odoo::Error->throw( kind => 'config', message => "pack $m->{name}: core lists $model; a pack may not replace it",
                fix => 'a pack adds behaviour files for models core does not list' ) if $core{$model};
        }
    }
    my $pdir = File::Spec->catdir( $m->{dir}, 'profiles' );
    if ( -d $pdir ) {
        my @core = Odoo::Ops::Profile->core_dirs;
        opendir my $dh, $pdir or return;
        for my $p ( sort grep { !/^\./ && -d File::Spec->catdir( $pdir, $_ ) } readdir $dh ) {
            Odoo::Error->throw( kind => 'config', message => "pack $m->{name}: core has a $p profile; a pack may not replace it",
                fix => 'a pack adds profiles under its own name' ) if grep { -d File::Spec->catdir( $_, $p ) } @core;
        }
    }
    return;
}

my %ROOTS = ( behaviours => [], profiles => [] );

=head2 set_roots(@manifests)

Adds the C<behaviours/> and C<profiles/> of the loaded packs to the search
roots, after core's (L<Odoo::Ops::Behaviour> and L<Odoo::Ops::Profile> read
them through C<roots>). A pack's roots replace the previous set.

=cut

sub set_roots ($class, @packs) {
    for my $kind (qw(behaviours profiles)) {
        $ROOTS{$kind} = [ grep { -d } map { File::Spec->catdir( $_->{dir}, $kind ) } @packs ];
    }
    return;
}

sub roots ($class, $kind) { @{ $ROOTS{$kind} // [] } }

=head2 lint_pack($dir)

The contract's lint: every C<.pm> under the pack's C<lib/> is read (comments
and POD left out) and each violation is answered as C<file:line: text>. A
violation is an C<Odoo::> module outside the contract and the pack's own
namespace, named by C<use>, C<require>, C<parent>, C<base> or fully qualified
in code, and a call into a C<_private> sub of any other package
(C<Odoo::Ops::Runner::_x(...)>, C<< Odoo::Ops::Runner-E<gt>_x >>,
C<SUPER::_x>).

=cut

my @ALLOWED = qw(Odoo::Ops::Operation Odoo::Ops::Plan Odoo::Error Odoo::Ops Odoo::Ops::Pack);

sub lint_pack ($class, $dir) {
    my $m   = $class->manifest($dir);
    my $own = $m->{namespace};
    my @bad;
    my $walk;
    $walk = sub ($d) {
        opendir my $dh, $d or return;
        for my $e ( sort grep { !/^\./ } readdir $dh ) {
            my $p = File::Spec->catfile( $d, $e );
            if    ( -d $p )        { $walk->($p) }
            elsif ( $e =~ /\.pm\z/ ) { push @bad, $class->lint_file( $p, $own ) }
        }
        closedir $dh;
    };
    $walk->( $m->{lib} );
    return @bad;
}

=head2 lint_file($path, $namespace)

The violations (see L</lint_pack>) of one file.

=cut

sub lint_file ($class, $path, $own) {
    open my $fh, '<', $path or return ("$path:0: cannot read");
    my ( @bad, $pod );
    while ( my $line = <$fh> ) {
        if ( $line =~ /\A=(\w+)/ ) { $pod = $1 ne 'cut'; next }
        next if $pod;
        last if $line =~ /\A__(?:END|DATA)__\b/;
        ( my $code = $line ) =~ s/(?:\A|\s)#.*//;
        for my $name ( $code =~ /\b(Odoo::\w+(?:::\w+)*)/g ) {
            ( my $mod = $name ) =~ s/::_\w+\z//;    # a _private sub is judged below
            $mod =~ s/::[a-z]\w*\z//;                # a helper sub of an allowed module (Odoo::Ops::json)
            next if grep { $mod eq $_ } @ALLOWED;
            next if $mod eq $own || index( $mod, "$own\::" ) == 0;
            push @bad, "$path:$.: uses $mod, which is not in the pack contract (Odoo::Ops::Pack)";
        }
        while ( $code =~ /\b(Odoo::\w+(?:::\w+)*)(?:::|->)(_\w+)/g ) {
            my ( $mod, $sub ) = ( $1, $2 );
            next if $mod eq $own || index( $mod, "$own\::" ) == 0;
            push @bad, "$path:$.: calls $mod\::$sub, a private sub of core";
        }
        push @bad, "$path:$.: calls SUPER::$1, a private sub of core" if $code =~ /\bSUPER::(_\w+)/;
    }
    close $fh;
    my %seen;
    return grep { !$seen{$_}++ } @bad;
}

1;
