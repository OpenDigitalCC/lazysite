package Odoo::Ops::Modules;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use File::Spec;
use Scalar::Util qw(blessed);

use Odoo::Error;

=head1 NAME

Odoo::Ops::Modules - what the installed modules make applicable here

=head1 SYNOPSIS

    my $installed = Odoo::Ops::Modules->installed($ctx);        # { crm => 1, ... } or undef
    my $why = Odoo::Ops::Modules->missing( $ctx, 'fleet' );     # 'module fleet is not installed' or undef
    Odoo::Ops::Modules->refuse( 'core.action', 'hr.leave action_x', $why ) if $why;

=head1 DESCRIPTION

OOM is the shape of the modules a server has: an operation, a model, a
method or a profile field whose module is not installed is C<not applicable
here>, a stated fact and never a failure, and everything else works. This
module holds the one fact and the sentences built on it.

The installed modules are read once per context, from C<ir.module.module>
with C<state> installed, to upgrade or to remove (the module is on the server in all three), and only when a decision needs them (a profile
with nothing missing never asks). A user who may not read the table, or a
server whose answer is empty (every server has C<base>), gives C<undef>:
nothing is then claimed about any module, and the caller goes on as if every
module were present, Odoo's own answer deciding. The read is made inside its
own guard scope, so no operation has to declare it.

The refusal is C<refused/not-applicable>, the one code for every absent
module.

=head2 installed($ctx)

The installed modules as a hash ref (name to 1), or undef when they cannot be
told. L</read_error> holds Odoo's text when the read was refused.

=cut

sub installed ( $class, $ctx ) {
    return $ctx->{modules}{set} if $ctx->{modules};
    my $guard = $ctx->guard;
    my $rows  = eval {
        $guard->with_scope( { 'ir.module.module' => ['search_read'] }, $guard->op // 'modules',
            sub { $ctx->client->model('ir.module.module')->search_read( [ [ 'state', 'in', [ 'installed', 'to upgrade', 'to remove' ] ] ], ['name'] ) } );
    };
    my $err = $@;
    my %set = map { $_->{name} => 1 } grep { ref $_ eq 'HASH' && defined $_->{name} } @{ $rows // [] };
    $ctx->{modules} = { set => %set ? \%set : undef, error => $rows ? undef : $err };
    return $ctx->{modules}{set};
}

=head2 read_failure($ctx) / read_error($ctx)

What the module table read died with (the error object), else undef; and its text.

=cut

sub read_failure ( $class, $ctx ) {
    $class->installed($ctx);
    my $e = $ctx->{modules}{error};
    return ( defined $e && $e ne '' ) ? $e : undef;
}

sub read_error ( $class, $ctx ) {
    my $e = $class->read_failure($ctx) // return undef;
    ( my $m = blessed($e) && $e->can('message') ? $e->message : "$e" ) =~ s/\s+\z//;
    return $m;
}

=head2 missing($ctx, $module)

C<module X is not installed> when the module table was read and has no such
module, else undef (also for no module, and for a table that cannot be read).

=cut

sub missing ( $class, $ctx, $module ) {
    return undef if !defined $module || !length $module;
    my $set = $class->installed($ctx) or return undef;
    return $set->{$module} ? undef : "module $module is not installed";
}

=head2 refuse($op, $subject, $why)

C<refused/not-applicable>: C<$op: $subject is not applicable here: $why>.

=cut

sub refuse ( $class, $op, $subject, $why ) {
    Odoo::Error->throw(
        kind    => 'refused',
        code    => 'not-applicable',
        message => "$op: $subject is not applicable here: $why",
        fix     => 'install the module on this server, or leave the call to a server that has it',
    );
}

=head2 pack_module($ctx, $pack)

The module a pack needs (C<module:> of its profile), or undef when the
profile cannot be loaded or names none.

=cut

sub pack_module ( $class, $ctx, $pack ) {
    my $p = eval { $ctx->profile($pack) } or return undef;
    return $p->module;
}

=head2 gate_pack($ctx, $op_name, $pack)

Refuses C<not-applicable> an operation of a pack whose module is not
installed. It is the first thing an operation of a pack does, before any
series check, so the module is the first reason named.

=cut

sub gate_pack ( $class, $ctx, $op_name, $pack ) {
    my $module = $class->pack_module( $ctx, $pack ) // return;
    my $why = $class->missing( $ctx, $module ) // return;
    $class->refuse( $op_name, "the $pack pack", $why );
}

=head2 module_of_model($ctx, $model)

The module OOM knows provides a physical model: the C<module:> of the model's
behaviour file, else of a profile model that maps to it. undef when OOM does
not know.

=cut

sub module_of_model ( $class, $ctx, $model ) {
    my $b = $ctx->behaviour($model);
    return $b->module if $b->known && defined $b->module;
    require Odoo::Ops::Profile;
    for my $pack ( $class->packs($ctx) ) {
        my $p = eval { $ctx->profile($pack) } or next;
        for my $lm ( $p->models ) {
            next if $p->model_name($lm) ne $model;
            my $m = $p->model_module($lm);
            return $m if defined $m;
        }
    }
    return undef;
}

=head2 packs($ctx)

The names of the profile packs OOM has, from the profile roots.

=cut

sub packs ( $class, $ctx ) {
    require Odoo::Ops::Profile;
    my %packs;
    for my $root ( Odoo::Ops::Profile->default_dirs( @{ $ctx->{profile_dirs} // [] } ) ) {
        opendir my $dh, $root or next;
        $packs{$_} = 1 for grep { !/^\./ && -d File::Spec->catdir( $root, $_ ) } readdir $dh;
        closedir $dh;
    }
    return sort keys %packs;
}

=head2 absent_model($ctx, $op, $model, $err)

Throws for a model the server could not describe (C<$err> is what
C<fields_get> died with). A refusal for access is Odoo's own and is thrown
again as it came. Anything else is a model this server does not have:
C<refused/not-applicable>, naming the module when OOM knows it
(C<model fleet.vehicle is not on this server: module fleet is not installed>),
and otherwise saying that no installed module provides it or the user may not
read it.

=cut

sub absent_model ( $class, $ctx, $op, $model, $err ) {
    die $err if blessed($err) && $err->isa('Odoo::Error') && $err->is_access_denied;
    my $module = $class->module_of_model( $ctx, $model );
    my $why    = $class->missing( $ctx, $module );
    $class->refuse_model( $op, $model, $why ) if defined $why;
    Odoo::Error->throw(
        kind    => 'refused',
        code    => 'not-applicable',
        message => defined $module
            ? "$op: model $model is not on this server (module $module is installed, or this user may not read it)"
            : "$op: no model '$model' on this server (no installed module provides it, or this user may not read it)",
        fix => 'the model is a physical name such as res.partner; a model of an optional module needs that module installed',
    );
}

=head2 refuse_model($op, $model, $why)

C<refused/not-applicable> for a model whose module is not installed:
C<$op: model M is not on this server: $why>.

=cut

sub refuse_model ( $class, $op, $model, $why ) {
    Odoo::Error->throw(
        kind    => 'refused',
        code    => 'not-applicable',
        message => "$op: model $model is not on this server: $why",
        fix     => 'install the module on this server, or leave the call to a server that has it',
    );
}

=head2 named($ctx)

Every module the behaviour files and profiles name, as C<< { module => [source, ...] } >>:
a behaviour file's model C<module>, an action's or wizard's C<module>, a
C<module:X> probe, and a profile's pack, model and field C<module>. The
sources are model names and C<< <pack> profile >>, sorted. It is what
C<doctor> checks one line per module for.

=cut

sub named ( $class, $ctx ) {
    require Odoo::Ops::Behaviour;
    my %by;
    my $add = sub ( $module, $src ) { $by{$module}{$src} = 1 if defined $module && length $module };
    for my $model ( Odoo::Ops::Behaviour->models( @{ $ctx->{profile_dirs} // [] } ) ) {
        my $b = $ctx->behaviour($model);
        next if !$b->known;
        $add->( $b->module, $model );
        $add->( $_->{module}, $model ) for @{ $b->actions }, @{ $b->wizards };
        $add->( $_, $model ) for map { /\Amodule:(.+)\z/ ? "$1" : () } @{ $b->probes };
    }
    for my $pack ( $class->packs($ctx) ) {
        my $p = eval { $ctx->profile($pack) } or next;
        $add->( $p->module, "$pack profile" );
        for my $lm ( $p->models ) {
            $add->( $p->model_module($lm), "$pack profile" );
            my $f = $p->{models}{$lm}{fields};
            $add->( $p->field_module( $lm, $_ ), "$pack profile" ) for keys %$f;
        }
    }
    return { map { my $m = $_; ( $m => [ sort keys %{ $by{$m} } ] ) } keys %by };
}

=head2 applicability($ctx, $registry)

What this server's modules make of each operation and each C<core.action>
method, for C<oom-ops list --conf>, C<describe --conf> and C<matrix --conf>:

    { operations => { name => { applies => 0|1, module => M, text => 'applies' | 'not applicable here (module M)' } },
      actions    => [ { model, method, module, applies, text } ],
      read_error => TEXT or undef }

An operation needs its pack's module; a C<core.*> operation and a pack with
no module apply. An action needs the module of its entry, else of its
model's file; with no module named it applies.

=cut

sub applicability ( $class, $ctx, $registry ) {
    my %ops = map { $_ => $class->operation_verdict( $ctx, $registry->class_for($_) ) } $registry->names;
    require Odoo::Ops::Behaviour;
    my @actions;
    for my $model ( Odoo::Ops::Behaviour->models( @{ $ctx->{profile_dirs} // [] } ) ) {
        my $b = $ctx->behaviour($model);
        next if !$b->known;
        for my $a ( @{ $b->actions } ) {
            push @actions, { model => $model, method => $a->{method}, %{ $class->_verdict( $ctx, $a->{module} // $b->module ) } };
        }
    }
    return { operations => \%ops, actions => \@actions, read_error => $class->read_error($ctx) };
}

=head2 operation_verdict($ctx, $op_class)

The verdict, C<< { module, applies, text } >>, for one operation class.

=cut

sub operation_verdict ( $class, $ctx, $op_class ) {
    my $pack = $op_class->pack;
    return $class->_verdict( $ctx, defined $pack ? $class->pack_module( $ctx, $pack ) : undef );
}

sub _verdict ( $class, $ctx, $module ) {
    my $gone = $class->missing( $ctx, $module );
    return {
        ( defined $module ? ( module => $module ) : () ),
        applies => $gone ? 0 : 1,
        text    => $gone ? "not applicable here (module $module)" : 'applies',
    };
}

1;
