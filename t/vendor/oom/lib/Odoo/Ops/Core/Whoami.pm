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
    # { uid, login, name, credential, groups => [ { id, name, xmlid? } ], groups_readable, groups_field,
    #   keys_readable, keys => [ { name, scope, create_date, expiration_date? } ] }

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

C<credential> says which credential the context uses: C<api_key>, C<password>
or C<session> (C<< $ctx->credential_kind >>); never its value.

C<keys> lists the login's own API keys as Odoo holds them: C<name>, C<scope>
(C<undef> for a key that serves any RPC), C<create_date> and, on the series that
give a key a date (18 and later), C<expiration_date> (C<undef> for a key with
none). The key value is held by Odoo as a hash and cannot be read by anyone, and
nothing here carries it. A user may read the rows of their own keys (an
internal or a portal user), an administrator those of everyone; C<keys_readable>
is C<0> and C<keys> empty where Odoo refuses the person that read (a user with no
group at all), which is an answer and not a fault. The list is the keys of this
login only, the key in use being one of them when the credential is an
C<api_key>; the report does not say which.

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
        'res.users.apikeys' => ['search_read'],
    };
}

sub report ($self) {
    my $client = $self->client;
    my $me     = $client->model('res.users')->read_one( $client->uid, [qw(login name)] );
    my $g      = $client->session_groups_report;
    my ( $keys, $readable ) = $self->_own_keys($client);
    return {
        uid             => $client->uid,
        login           => $me->{login},
        name            => $me->{name},
        credential      => ( $self->ctx->can(q(credential_kind)) ? $self->ctx->credential_kind : undef ),
        keys            => $keys,
        keys_readable   => $readable,
        groups          => $g->{groups},
        groups_readable => $g->{groups_readable},
        groups_field    => $g->{field},
    };
}

# The login's own key rows, never a value: the table has no column a caller can read it from.
# Odoo refusing the read is an answer (keys_readable 0); any other fault dies.
sub _own_keys ($self, $client) {
    my $m = $client->model('res.users.apikeys');
    my @f = ( qw(name scope create_date), ( $m->fields->{expiration_date} ? ('expiration_date') : () ) );
    my $rows = eval { $m->search_read( [ [ 'user_id', '=', $client->uid ] ], \@f ) };
    if ( my $e = $@ ) {
        return ( [], 0 ) if ref $e && $e->can('is_access_denied') && $e->is_access_denied;
        die $e;
    }
    my @keys = map { my $r = $_; +{ map { $_ => $r->{$_} } @f } } @$rows;
    @keys = sort { $a->{create_date} cmp $b->{create_date} or $a->{name} cmp $b->{name} } @keys;
    return ( \@keys, 1 );
}

1;
