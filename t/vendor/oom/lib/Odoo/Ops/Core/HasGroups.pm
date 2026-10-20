package Odoo::Ops::Core::HasGroups;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Core::HasGroups - does the signed-in person hold these groups?

=head1 SYNOPSIS

    oom-ops run core.has_groups --conf C --set groups=base.group_user,sales_team.group_sale_salesman

    # a program holding a person's session context
    my $r = Odoo::Ops::Core::HasGroups->new( ctx => $ctx, params => { groups => [ 'base.group_user' ] } )->run;
    # { groups => { 'base.group_user' => 1 } }

=head1 DESCRIPTION

C<core.has_groups> asks Odoo, as the login the context carries (a person's
session or key, never another login), whether that user holds each group in
C<groups>, a list of at most 50 group xml ids (C<module.name>). The answer is
C<< { groups => { XMLID => 1|0 } } >>: C<1> held, C<0> not held. An xml id
Odoo has no group for is answered C<0>, like a group the person does not hold.
Duplicates are asked once. A malformed id (not exactly C<module.name>) or a
list over 50 is a C<usage> error before anything is asked.

It needs no administrator right and reads no C<ir.model.data> row: the
method is Odoo's own C<res.users.has_group>, which answers for the calling user.
A portal user may ask it as well as an internal one.

The method differs by series, and the operation uses each as it stands. On 16
(and 17, from its source) C<has_group(xmlid)> is a model method and answers for
the calling user. From 18 it is a record method, C<has_group(xmlid)> on the
user's own record, and Odoo refuses a portal user the record of anyone else.
C<has_groups> of 18 and 19 takes one spec and answers one boolean for the whole
list (any of, with C<!> to exclude), so it cannot give a per-group answer: the
operation makes one C<has_group> call for each id. Odoo's C<has_group> answers
false for an unknown id and does not raise.

C<base.group_no_one> answers C<0> on 18 and 19 outside debug mode, which an RPC
call never is.

The audit line records the operation and C<groups_asked>, the count, not the
groups.

A read operation; nothing is written.

=cut

sub op_name ($class) { 'core.has_groups' }
sub summary ($class) { 'Whether the signed-in user holds each of a list of groups, by xml id' }
sub pack    ($class) { undef }

sub params ($class) {
    {   groups => { type => 'list', required => 1,
            help => 'group xml ids, module.name, at most 50 (comma separated)' },
    };
}

sub read_scope ($class) { { 'res.users' => ['has_group'] } }

my $MAX = 50;

sub report ($self) {
    my $given = $self->param("groups");
    $given = [ grep { length } split /\s*,\s*/, $given // '' ] if ref $given ne 'ARRAY';
    my ( %seen, @ids );
    for my $id (@$given) {
        $id =~ s/\A\s+|\s+\z//g;
        Odoo::Error->throw( kind => 'usage',
            message => "core.has_groups: '$id' is not a group xml id (module.name)" )
            if $id !~ /\A[A-Za-z_][\w-]*\.[\w-]+\z/;
        push @ids, $id if !$seen{$id}++;
    }
    Odoo::Error->throw( kind => 'usage', message => 'core.has_groups: groups is empty; give at least one xml id' ) if !@ids;
    Odoo::Error->throw( kind => 'usage',
        message => 'core.has_groups: ' . scalar(@ids) . " group xml ids given; at most $MAX are answered at once" )
        if @ids > $MAX;

    my $client = $self->client;
    my $users  = $client->model('res.users');
    my $uid    = $client->uid;
    # 16 and 17: a model method; 18 and later: a method on the user's own record
    my $on_record = $client->server_series >= 18;

    my %held;
    for my $id (@ids) {
        my $r = $users->call( 'has_group', $on_record ? [ [$uid], $id ] : [$id] );
        $held{$id} = $r ? 1 : 0;
    }
    return { groups => \%held };
}

sub audit_detail ($self, $report) {
    return () if ref $report ne 'HASH';
    return ( groups_asked => scalar keys %{ $report->{groups} // {} } );
}

1;
