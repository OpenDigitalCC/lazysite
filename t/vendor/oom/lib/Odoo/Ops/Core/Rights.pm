package Odoo::Ops::Core::Rights;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Scalar::Util qw(blessed);

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Core::Rights - where the configured user's rights come from

=head1 DESCRIPTION

C<core.rights>: reads the configured user's groups and explains them.
Odoo stores a user's groups with every implied group already expanded,
so the report separates:

    roots    groups no other group of the user implies - what an admin
             actually ticked (or a module assigned)
    chains   for each group of interest, the implication path from a
             root to it (Sales / Administrator -> ... -> Settings)

Groups of interest: the admin groups (Settings, Access Rights) plus any
named in C<groups> (xml ids). With C<model>, it also lists the access
rows (ir.model.access) granting that model and which of them apply to
this user. Anything the user may not read is reported as unreadable,
never guessed - and being able to read the access rows or xml ids is
itself a finding, since Odoo reserves both for administrators.

=cut

my @ADMIN = qw(base.group_system base.group_erp_manager);

sub op_name ($class) { 'core.rights' }
sub summary ($class) { 'Explain the configured user\'s groups and what grants a model' }
sub params ($class) {
    {   model  => { type => 'str',  help => 'a model to explain access to (e.g. ir.module.module)' },
        groups => { type => 'list', help => 'extra group xml ids to trace' },
        modules => { type => 'list', help => 'module names whose install state to report (if readable)' },
    };
}
sub read_scope ($class) {
    {   'ir.module.module' => ['search_read'],
        'res.groups'      => [qw(read search_read)],
        'ir.model.data'   => ['search_read'],
        'ir.model.access' => ['search_read'],
    };
}

sub report ($self) {
    my $c   = $self->client;
    # group_ids from 19, groups_id before
    my $gf  = $c->model('res.users')->fields->{group_ids} ? 'group_ids' : 'groups_id';
    my $me  = $c->execute_kw( 'res.users', 'read', [ [ $c->uid ] ], { fields => [ 'login', 'name', $gf, 'share' ] } )->[0];
    my %r   = ( login => $me->{login}, share => $me->{share} ? 1 : 0 );
    my $gids = $me->{$gf} // [];

    my $groups = $self->_try( sub { $c->model('res.groups')->read( $gids, [qw(full_name implied_ids)] ) } );
    if ( !ref $groups ) { $r{groups} = { unreadable => $groups }; return \%r }
    my %g = map { $_->{id} => $_ } @$groups;

    my $xml = $self->_try( sub {
        $c->model('ir.model.data')->search_read( [ [ 'model', '=', 'res.groups' ], [ 'res_id', 'in', $gids ] ],
            [qw(module name res_id)] );
    } );
    my %xid;
    if ( ref $xml ) { $xid{ $_->{res_id} } = "$_->{module}.$_->{name}" for @$xml }
    $r{can_read_xml_ids} = ref $xml ? 1 : "no ($xml)";
    my $label = sub ($id) { ( $g{$id}{full_name} // "#$id" ) . ( $xid{$id} ? " [$xid{$id}]" : '' ) };

    my %parents;
    for my $p (@$groups) { push @{ $parents{$_} }, $p->{id} for grep { $g{$_} } @{ $p->{implied_ids} // [] } }
    my @roots = sort { $label->($a) cmp $label->($b) } grep { !$parents{$_} } keys %g;
    $r{group_count} = scalar @$groups;
    $r{roots}       = [ map { $label->($_) } @roots ];

    my %want_x = map { $_ => 1 } @ADMIN, @{ $self->param('groups') // [] };
    my %by_x   = reverse %xid;
    for my $x ( sort keys %want_x ) {
        my $id = $by_x{$x};
        if ( !$id ) {
            $r{traced}{$x} = ref $xml ? 'not held' : 'unknown (xml ids unreadable)';
            next;
        }
        $r{traced}{$x} = [ map { join ' -> ', map { $label->($_) } @$_ } $self->_paths( $id, \%parents ) ];
    }
    # Without xml ids, name-match the admin groups so the question is still answered.
    if ( !ref $xml ) {
        $r{admin_like} = [ map { $label->($_) } grep {
            ( $g{$_}{full_name} // '' ) =~ /^(Administration|Settings)\b|\/ (Settings|Access Rights)$/
        } keys %g ];
        $r{admin_like_chains} = { map { my $id = $_; ( $label->($id) =>
            [ map { join ' -> ', map { $label->($_) } @$_ } $self->_paths( $id, \%parents ) ] ) }
            grep { ( $g{$_}{full_name} // '' ) =~ /Settings|Access Rights/ } keys %g };
    }

    if ( my $mods = $self->param('modules') ) {
        my $rows = $self->_try( sub {
            $c->model('ir.module.module')->search_read( [ [ 'name', 'in', $mods ] ], [qw(name state)] );
        } );
        $r{modules} = ref $rows
            ? { map( { $_ => 'not present' } @$mods ), map { $_->{name} => $_->{state} } @$rows }
            : { unreadable => $rows };
    }

    if ( my $model = $self->param('model') ) {
        my $acl = $self->_try( sub {
            $c->model('ir.model.access')->search_read( [ [ 'model_id.model', '=', $model ] ],
                [qw(name group_id perm_read perm_write perm_create perm_unlink)] );
        } );
        $r{can_read_access_rows} = ref $acl ? 1 : "no ($acl)";
        if ( ref $acl ) {
            for my $a (@$acl) {
                my $gid = ref $a->{group_id} ? $a->{group_id}[0] : undef;
                push @{ $r{model_access}{$model} }, {
                    rule    => $a->{name},
                    group   => $gid ? $a->{group_id}[1] : '(everyone)',
                    perms   => join( '', map { $a->{"perm_$_"} ? substr( $_, 0, 1 ) : '-' } qw(read write create unlink) ),
                    applies => ( !$gid || $g{$gid} ) ? 1 : 0,
                    ( $gid && $g{$gid} ? ( via => [ map { join ' -> ', map { $label->($_) } @$_ } $self->_paths( $gid, \%parents ) ] ) : () ),
                };
            }
        }
    }
    return \%r;
}

# Every root-to-target path through the user's own implication graph.
sub _paths ($self, $target, $parents, $seen = {}) {
    return [$target] if !$parents->{$target};
    my @out;
    for my $p ( @{ $parents->{$target} } ) {
        next if $seen->{$p};
        push @out, map { [ @$_, $target ] } $self->_paths( $p, $parents, { %$seen, $target => 1 } );
    }
    return @out ? @out : [$target];
}

sub _try ($self, $code) {
    my $v = eval { $code->() };
    return $v if defined $v;
    my $e = $@;
    return blessed($e) && $e->isa('Odoo::Error') ? ( $e->fault_category // $e->kind ) : 'error';
}

1;
