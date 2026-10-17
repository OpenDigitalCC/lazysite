package Odoo::Ops::Core::Whoami;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Core::Whoami - who the connection is, and the groups that user holds

=head1 SYNOPSIS

    oom-ops run core.whoami --conf C

    # a program holding a person's session context
    my $r = Odoo::Ops::Core::Whoami->new( ctx => $ctx )->run;
    # { uid, login, name, groups => [ { id, name, xmlid? } ], groups_readable, groups_field }

=head1 DESCRIPTION

C<core.whoami> reports the identity of the user the context acts as (for
a session context, the person whose session is carried) and the groups
that user holds, sorted by name. It is L<Odoo::Client/session_groups_report>
under an operation's scope, so a program that has only a person's
session can ask it without reaching into C<res.users> itself.

The field read is C<group_ids> from 19 and C<groups_id> before; the
group names come from C<res.groups> (C<full_name>). A user with no groups
gets an empty list. Where Odoo refuses the person the read of
C<res.groups> (a portal user may be), C<groups> is the empty list and
C<groups_readable> is C<0>: that is an answer, not a fault. C<xmlid> is
present on a group only when the user may read C<ir.model.data> (an
administrator).

A read operation; nothing is written.

=cut

sub op_name ($class) { 'core.whoami' }
sub summary ($class) { 'The user the connection acts as and the groups that user holds' }
sub pack    ($class) { undef }
sub params  ($class) { {} }

# res.users.read is in the Guard's base scope; the names and xml ids are not
sub read_scope ($class) {
    {   'res.groups'    => ['read'],
        'ir.model.data' => ['search_read'],
    };
}

sub report ($self) {
    my $client = $self->client;
    my $me     = $client->model('res.users')->read_one( $client->uid, [qw(login name)] );
    my $g      = $client->session_groups_report;
    return {
        uid             => $client->uid,
        login           => $me->{login},
        name            => $me->{name},
        groups          => $g->{groups},
        groups_readable => $g->{groups_readable},
        groups_field    => $g->{field},
    };
}

1;
