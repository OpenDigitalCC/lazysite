package Odoo::Ops::Template;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Error;

=head1 NAME

Odoo::Ops::Template - the default user template, and what a write of its groups does to everyone else

=head1 DESCRIPTION

On Odoo 16 and 18 the user C<base.default_user> is the template new internal users copy their groups from.
Its C<groups_id> is special in one more way: C<res.users.write> compares the template's groups before and
after a write and links every group that was added to B<every other internal user>
(C<_apply_groups_to_existing_employees>, source 16.0 and 18.0 C<odoo/addons/base/models/res_users.py>). A write
that removes a group from the template touches no one else, so putting that group back (a revert) hands it to
every internal user. Odoo 19 has no such template (the defaults are the implied groups of
C<base.default_user_group>, which behave as any implied group), and 17 was not probed, so this module acts on 16
and 18 only.

The template is found by its xml id (C<base.default_user>), never by its name or login. The reads are made in
a scope of their own, so no operation has to declare them.

=head2 find($ctx)

C<< { id, field } >> of the template and the name of its groups field, or undef where the series has no such
template (19, 17 unprobed), the xml id does not resolve, or the reads are refused.

=head2 groups($ctx, $info)

The ids of the groups the template holds now.

=head2 internal_users($ctx, $info)

How many users other than the template Odoo links an added group to: the active users of C<base.group_user>.

=head2 annotate($ctx, $change)

For a planned C<write> to the template that adds groups, adds to the change's C<effects> the sentence saying how
many groups Odoo will hand to how many internal users, and returns 1; otherwise returns 0. The plan states it and
does not refuse it: a forward write is the caller's decision.

=head2 revert_refusal($ctx, \@done)

Given the done changes of a journal, throws C<refused/template-groups-propagate> when undoing them would write groups
back onto the template that it does not hold now, naming the groups and the count of internal users who would
receive them, and the fix: add the groups wanted to the users who need them, explicitly.

=cut

my $XMLID = [ [ 'module', '=', 'base' ], [ 'model', '=', 'res.users' ], [ 'name', '=', 'default_user' ] ];

sub _scoped ( $ctx, $scope, $code ) {
    my $guard = $ctx->guard;
    return $guard->with_scope( $scope, $guard->op // 'template', $code );
}

sub find ( $class, $ctx ) {
    return $ctx->{template_info} if exists $ctx->{template_info};
    my $info = eval {
        my $series = $ctx->client->server_series;
        return undef if $series != 16 && $series != 18;
        my $rows = _scoped( $ctx, { 'ir.model.data' => ['search_read'] }, sub { $ctx->client->model('ir.model.data')->search_read( $XMLID, ['res_id'] ) } );
        return undef if @$rows != 1 || !$rows->[0]{res_id};
        my $users = $ctx->client->model('res.users');
        my $field = $users->fields->{groups_id} ? 'groups_id' : $users->fields->{group_ids} ? 'group_ids' : undef;
        return undef if !$field;
        return { id => 0 + $rows->[0]{res_id}, field => $field };
    };
    return $ctx->{template_info} = $info;
}

sub groups ( $class, $ctx, $info ) {
    my $row = _scoped( $ctx, { 'res.users' => ['read'] }, sub { $ctx->client->model('res.users')->read( [ $info->{id} ], [ $info->{field} ] )->[0] } );
    return [ @{ $row->{ $info->{field} } // [] } ];
}

sub internal_users ( $class, $ctx, $info ) {
    my $gid = _scoped( $ctx, { 'ir.model.data' => ['search_read'] }, sub {
        my $r = $ctx->client->model('ir.model.data')->search_read( [ [ 'module', '=', 'base' ], [ 'model', '=', 'res.groups' ], [ 'name', '=', 'group_user' ] ], ['res_id'] );
        return @$r == 1 ? $r->[0]{res_id} : undef;
    } );
    return undef if !$gid;
    my $ids = _scoped( $ctx, { 'res.users' => ['search'] }, sub { $ctx->client->model('res.users')->search( [ [ $info->{field}, 'in', [$gid] ], [ 'id', '!=', $info->{id} ] ] ) } );
    return scalar @$ids;
}

sub _names ( $ctx, @ids ) {
    return {} if !@ids;
    my $rows = _scoped( $ctx, { 'res.groups' => ['read'] }, sub { $ctx->client->model('res.groups')->read( [@ids], ['display_name'] ) } );
    return { map { $_->{id} => $_->{display_name} } @$rows };
}

# the group ids a write value adds: [4, id], [6, 0, ids], or a plain list of ids
sub _added_by ( $value, $held ) {
    my %have = map { $_ => 1 } @$held;
    my @add;
    for my $cmd ( @{ ref $value eq 'ARRAY' ? $value : [] } ) {
        if ( ref $cmd eq 'ARRAY' ) {
            if    ( $cmd->[0] == 4 ) { push @add, $cmd->[1] }
            elsif ( $cmd->[0] == 6 ) { push @add, @{ $cmd->[2] // [] } }
        }
        elsif ( defined $cmd && !ref $cmd ) { push @add, $cmd }
    }
    my %seen;
    return grep { !$have{$_} && !$seen{$_}++ } @add;
}

sub annotate ( $class, $ctx, $c ) {
    return 0 if ( $c->{model} // '' ) ne 'res.users' || ( $c->{action} // '' ) ne 'write' || !defined $c->{id} || ref $c->{vals} ne 'HASH';
    return 0 if !grep { exists $c->{vals}{$_} } qw(groups_id group_ids);
    my $info = $class->find($ctx) or return 0;
    return 0 if $c->{id} != $info->{id} || !exists $c->{vals}{ $info->{field} };
    my @add = _added_by( $c->{vals}{ $info->{field} }, $class->groups( $ctx, $info ) );
    return 0 if !@add;
    my $n   = $class->internal_users( $ctx, $info );
    my $who = defined $n ? "the $n internal user" . ( $n == 1 ? '' : 's' ) . ' who exist' : 'every internal user';
    my $rec = $ctx->behaviour('res.users')->record_effect('default-user-template');
    push @{ $c->{effects} }, {
        effect     => scalar(@add) . ' group' . ( @add == 1 ? '' : 's' ) . " added to the default user template are given by Odoo to $who (res.users write, _apply_groups_to_existing_employees)",
        suppressed => 0,
        evidence   => $rec ? $rec->{evidence} : 'source res_users.write',
    };
    return 1;
}

sub revert_refusal ( $class, $ctx, $done ) {
    my @writes = grep { ( $_->{action} // '' ) eq 'write' && ( $_->{model} // '' ) eq 'res.users' && ref $_->{vals} eq 'HASH' && ref $_->{before} eq 'HASH'
        && ( exists $_->{vals}{groups_id} || exists $_->{vals}{group_ids} ) } @$done;
    return if !@writes;
    my $info = $class->find($ctx) or return;
    @writes = grep { $_->{id} == $info->{id} && exists $_->{before}{ $info->{field} } && exists $_->{vals}{ $info->{field} } } @writes;
    return if !@writes;
    my $held = $class->groups( $ctx, $info );
    my ( %back, @seqs );
    for my $c (@writes) {
        my @add = _added_by( $c->{before}{ $info->{field} }, $held );
        next if !@add;
        $back{$_} = 1 for @add;
        push @seqs, $c->{seq};
    }
    return if !%back;
    my @ids   = sort { $a <=> $b } keys %back;
    my $names = _names( $ctx, @ids );
    my @shown = map { $names->{$_} // "group $_" } @ids[ 0 .. ( @ids > 8 ? 7 : $#ids ) ];
    my $list  = join( ', ', @shown ) . ( @ids > 8 ? ' and ' . ( @ids - 8 ) . ' more' : '' );
    my $n     = $class->internal_users( $ctx, $info );
    my $who   = defined $n ? "$n internal user" . ( $n == 1 ? '' : 's' ) : 'every internal user';
    Odoo::Error->throw(
        kind    => 'refused',
        code    => 'template-groups-propagate',
        message => 'this revert would write ' . scalar(@ids) . ' group' . ( @ids == 1 ? '' : 's' ) . " back onto the default user template (res.users $info->{id}, change"
            . ( @seqs == 1 ? '' : 's' ) . ' ' . join( ', ', sort { $a <=> $b } @seqs ) . "): $list. "
            . "Odoo gives every group added to the template to every internal user, so $who would receive them",
        fix => 'add the groups you actually want to the users who need them, explicitly (a core.user groups row), and leave the template as it is',
    );
}

1;
