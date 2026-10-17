package Odoo::Ops::Mailing::Lists;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Mailing::Common;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Mailing::Lists - the mailing lists, with who is on them

=head1 SYNOPSIS

    oom-ops run mailing.lists --conf ops.conf
    oom-ops run mailing.lists --conf ops.conf --set name=news --set archived=1

=head1 DESCRIPTION

C<mailing.lists>: one row per list - C<id>, C<name>, C<active>,
C<contacts> (the subscriptions, opted-out included), C<subscribed>
(not opted out), C<opted_out>, C<blacklisted> (subscriptions whose
address is on the blacklist), C<reachable> (a valid address, not opted
out, not blacklisted - Odoo's C<contact_count_email>) and C<mailings>
(the mailings that use the list). The counts are Odoo's own, computed
by the list; nothing here is counted again.

C<name> filters on a part of the name, case-insensitively. Archived
lists are left out unless C<archived> is on.

The report is C<< { count, rows, fields } >> like the crm reads.
Series: written for Odoo 16; another series is refused by name until
its profile is probed.

=cut

sub op_name ($class) { 'mailing.lists' }
sub summary ($class) { 'Read the mailing lists and how many are on, opted out and reachable' }
sub pack    ($class) { 'mailing' }
# The keys of the descriptors this read returns in its fields block.
sub fields ($class) {
    return [
        { name => 'id', meaning => 'Id' },
        { name => 'name', meaning => 'Name' },
        { name => 'active', meaning => 'Active' },
        { name => 'contacts', meaning => 'Subscriptions' },
        { name => 'subscribed', meaning => 'Subscribed (not opted out)' },
        { name => 'opted_out', meaning => 'Opted out' },
        { name => 'blacklisted', meaning => 'Blacklisted' },
        { name => 'reachable', meaning => 'Reachable (valid address, subscribed, not blacklisted)' },
        { name => 'mailings', meaning => 'Mailings using the list' },
    ];
}

sub params ($class) {
    {   name     => { type => 'str',  help => 'only lists whose name contains this' },
        archived => { type => 'bool', default => 0, help => 'include archived lists' },
    };
}
sub read_scope ($class) { { list => [qw(search_read read)] } }

sub scope_for ($self, $phase) { Odoo::Ops::Mailing::Common::scope( $self, $phase, $self->SUPER::scope_for($phase) ) }

sub report ($self) {
    my $p = Odoo::Ops::Mailing::Common::ready($self);
    my $f = sub ($lf) { $p->field( list => $lf ) };
    my @dom;
    push @dom, [ $f->('name'), 'ilike', $self->param('name') ] if defined $self->param('name');
    push @dom, [ $f->('active'), 'in', [ JSON::PP::true, JSON::PP::false ] ] if $self->param('archived');
    my @read = map { $f->($_) } qw(name active contacts opted_out blacklisted reachable mailings);
    # the counts are computed: one this user may not run is null with the reason, not a fault (docs/specs/mailing-5.md)
    my ( $rows, $info ) = Odoo::Ops::Mailing::Common::search_read_named( $self, 'list', \@dom, \@read, required => [ $f->('name') ] );
    my %key = map { $f->($_) => $_ } qw(contacts opted_out blacklisted reachable mailings);
    my %unreadable;
    my @out = map {
        my $r = $_;
        my $un = $info->{unreadable}{ $r->{id} } // {};
        my ( $n, $o ) = ( $r->{ $f->('contacts') } // 0, $r->{ $f->('opted_out') } // 0 );
        $r->{ $f->($_) } = undef for grep { $un->{ $f->($_) } } qw(blacklisted reachable mailings);
        +{
            id          => $r->{id},
            name        => $r->{ $f->('name') },
            active      => $r->{ $f->('active') } ? JSON::PP::true : JSON::PP::false,
            contacts    => $un->{ $f->('contacts') } ? undef : $n,
            subscribed  => $un->{ $f->('contacts') } || $un->{ $f->('opted_out') } ? undef : $n - $o,
            opted_out   => $un->{ $f->('opted_out') } ? undef : $o,
            blacklisted => $un->{ $f->('blacklisted') } ? undef : $r->{ $f->('blacklisted') } // 0,
            reachable   => $un->{ $f->('reachable') } ? undef : $r->{ $f->('reachable') } // 0,
            mailings    => $un->{ $f->('mailings') } ? undef : $r->{ $f->('mailings') } // 0,
            ( %$un ? ( unreadable => { map { my $k = $key{$_}; $unreadable{$k} = 1; $k => Odoo::Ops::Mailing::Common::unreadable_note( $k, $un->{$_} ) } keys %$un } ) : () ),
        };
    } sort { lc( $a->{ $f->('name') } ) cmp lc( $b->{ $f->('name') } ) || $a->{id} <=> $b->{id} } @$rows;
    my $int = sub ($s) { { portable_type => 'integer', string => $s } };
    return {
        count  => scalar @out,
        rows   => \@out,
        unreadable_fields => [ sort keys %unreadable ],
        fields => {
            id => { portable_type => 'integer', string => 'Id' },
            name => { portable_type => 'text', string => 'Name' },
            active => { portable_type => 'boolean', string => 'Active' },
            contacts    => $int->('Subscriptions'),
            subscribed  => $int->('Subscribed (not opted out)'),
            opted_out   => $int->('Opted out'),
            blacklisted => $int->('Blacklisted'),
            reachable   => $int->('Reachable (valid address, subscribed, not blacklisted)'),
            mailings    => $int->('Mailings using the list'),
        },
    };
}

1;
