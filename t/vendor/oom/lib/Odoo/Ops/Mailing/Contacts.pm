package Odoo::Ops::Mailing::Contacts;

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

Odoo::Ops::Mailing::Contacts - the mailing contacts and their subscriptions

=head1 SYNOPSIS

    oom-ops run mailing.contacts --conf ops.conf --set list=Newsletter
    oom-ops run mailing.contacts --conf ops.conf --set email=@example.com --set opted_out=1

=head1 DESCRIPTION

C<mailing.contacts>: one row per C<mailing.contact> - C<id>, C<name>,
C<email>, C<company>, C<tags> (names), C<blacklisted> and C<lists>, a
list of C<< { name, opt_out, since } >> (C<since> is when the contact
opted out, absent while subscribed). The filters combine:

    list         a list by name or id: contacts subscribed to it
    email, name  contacts whose email or name contains the text
    opted_out    with list: opted out of it (1) or still subscribed (0);
                 without: opted out of any list
    blacklisted  on the blacklist (1) or not (0)
    limit        rows to return, default 200

The report is C<< { matching, shown, rows, fields } >>: C<matching> is
how many contacts the filters select, C<shown> how many are returned
(at most C<limit>), so a cut-off is never silent. Series: Odoo 16.

=cut

sub op_name ($class) { 'mailing.contacts' }
sub summary ($class) { 'Read the mailing contacts with their lists, opt-outs and blacklisting' }
sub pack    ($class) { 'mailing' }
# The keys of the descriptors this read returns in its fields block.
sub fields ($class) {
    return [
        { name => 'id', meaning => 'Id' },
        { name => 'name', meaning => 'Name' },
        { name => 'email', meaning => 'Email' },
        { name => 'company', meaning => 'Company' },
        { name => 'tags', meaning => 'Tags' },
        { name => 'blacklisted', meaning => 'Blacklisted' },
        { name => 'lists', meaning => 'Lists (name, opt_out, since)' },
    ];
}

sub params ($class) {
    {   list        => { type => 'str',  help => 'a list by name or id' },
        email       => { type => 'str',  help => 'contacts whose email contains this' },
        name        => { type => 'str',  help => 'contacts whose name contains this' },
        opted_out   => { type => 'bool', help => 'opted out (1) or subscribed (0), of the list if given, else of any list' },
        blacklisted => { type => 'bool', help => 'on the blacklist (1) or not (0)' },
        limit       => { type => 'int',  default => 200, help => 'rows to return' },
    };
}
sub read_scope ($class) {
    {   list         => [qw(search_read read)],
        contact      => [qw(search_read search_count read)],
        subscription => ['search_read'],
        tag          => ['read'],
    };
}

sub scope_for ($self, $phase) { Odoo::Ops::Mailing::Common::scope( $self, $phase, $self->SUPER::scope_for($phase) ) }

sub report ($self) {
    my $p = Odoo::Ops::Mailing::Common::ready($self);
    my $f = sub ( $lm, $lf ) { $p->field( $lm => $lf ) };
    Odoo::Error->throw( kind => 'usage', message => 'mailing.contacts: limit must be 1 or more' )
        if $self->param('limit') < 1;

    my @dom;
    my $in_list;
    if ( defined( my $ref = $self->param('list') ) ) {
        my $found = Odoo::Ops::Mailing::Common::lists_by( $self, $ref, archived => 1 );
        Odoo::Error->throw( kind => 'refused', code => 'unknown-list', message => "mailing.contacts: no list '$ref'", fix => 'oom-ops run mailing.lists --conf <conf> lists the mailing lists' ) if !@$found;
        Odoo::Error->throw( kind => 'usage', message => "mailing.contacts: '$ref' names " . scalar(@$found) . ' lists (ids ' . join( ', ', map { $_->{id} } @$found ) . '); give the id' )
            if @$found > 1;
        $in_list = $found->[0]{id};
    }
    # a subscription is where a list and an opt-out meet, so those two filters go through it
    if ( defined $in_list || defined $self->param('opted_out') ) {
        my @sd;
        push @sd, [ $f->( subscription => 'list' ), '=', $in_list ] if defined $in_list;
        push @sd, [ $f->( subscription => 'opt_out' ), '=', $self->param('opted_out') ? JSON::PP::true : JSON::PP::false ]
            if defined $self->param('opted_out');
        my $subs = $self->model('subscription')->all( \@sd, [ $f->( subscription => 'contact' ) ] );
        push @dom, [ 'id', 'in', [ sort { $a <=> $b } keys %{ { map { Odoo::Ops::Mailing::Common::id_of( $_->{ $f->( subscription => 'contact' ) } ) => 1 } @$subs } } ] ];
    }
    push @dom, [ $f->( contact => 'email' ), 'ilike', $self->param('email') ] if defined $self->param('email');
    push @dom, [ $f->( contact => 'name' ),  'ilike', $self->param('name') ]  if defined $self->param('name');
    push @dom, [ $f->( contact => 'blacklisted' ), '=', $self->param('blacklisted') ? JSON::PP::true : JSON::PP::false ]
        if defined $self->param('blacklisted');

    my $contact = $self->model('contact');
    my $matching = $contact->count( \@dom );
    my @cf = map { $f->( contact => $_ ) } qw(name email company tags blacklisted);
    # a computed field this user may not run is null with the reason (docs/specs/mailing-5.md), not a fault
    my ( $rows, $info ) = Odoo::Ops::Mailing::Common::search_read_named( $self, 'contact', \@dom, \@cf, limit => $self->param('limit'), order => 'id asc',
        required => [ map { $f->( contact => $_ ) } qw(name email) ] );

    my @cids = map { $_->{id} } @$rows;
    my $subs = @cids ? $self->model('subscription')->all( [ [ $f->( subscription => 'contact' ), 'in', \@cids ] ],
        [ map { $f->( subscription => $_ ) } qw(contact list opt_out since) ] ) : [];
    my %lname;
    my @lids = keys %{ { map { Odoo::Ops::Mailing::Common::id_of( $_->{ $f->( subscription => 'list' ) } ) => 1 } @$subs } };
    %lname = map { $_->{id} => $_->{ $f->( list => 'name' ) } } @{ $self->model('list')->read( [ sort { $a <=> $b } @lids ], [ $f->( list => 'name' ) ] ) } if @lids;
    my %by;
    for my $s ( sort { $a->{id} <=> $b->{id} } @$subs ) {
        my $lid = Odoo::Ops::Mailing::Common::id_of( $s->{ $f->( subscription => 'list' ) } );
        my $since = Odoo::Ops::Mailing::Common::text( $s->{ $f->( subscription => 'since' ) } );
        push @{ $by{ Odoo::Ops::Mailing::Common::id_of( $s->{ $f->( subscription => 'contact' ) } ) } }, {
            name    => $lname{$lid} // "list $lid",
            opt_out => $s->{ $f->( subscription => 'opt_out' ) } ? JSON::PP::true : JSON::PP::false,
            ( length $since ? ( since => $since ) : () ),
        };
    }
    my %tname;
    my @tids = keys %{ { map { $_ => 1 } map { @{ $_->{ $f->( contact => 'tags' ) } // [] } } @$rows } };
    %tname = map { $_->{id} => $_->{ $f->( tag => 'name' ) } } @{ $self->model('tag')->read( [ sort { $a <=> $b } @tids ], [ $f->( tag => 'name' ) ] ) } if @tids;

    my @out = map {
        my $r = $_;
        my $un = $info->{unreadable}{ $r->{id} } // {};
        +{
            id          => $r->{id},
            name        => Odoo::Ops::Mailing::Common::text( $r->{ $f->( contact => 'name' ) } ),
            email       => Odoo::Ops::Mailing::Common::text( $r->{ $f->( contact => 'email' ) } ),
            company     => Odoo::Ops::Mailing::Common::text( $r->{ $f->( contact => 'company' ) } ),
            tags        => [ map { $tname{$_} // "tag $_" } @{ $r->{ $f->( contact => 'tags' ) } // [] } ],
            blacklisted => $un->{ $f->( contact => 'blacklisted' ) } ? undef : $r->{ $f->( contact => 'blacklisted' ) } ? JSON::PP::true : JSON::PP::false,
            lists       => $by{ $r->{id} } // [],
            ( %$un ? ( unreadable => { blacklisted => Odoo::Ops::Mailing::Common::unreadable_note( blacklisted => $un->{ $f->( contact => 'blacklisted' ) } ) } ) : () ),
        };
    } @$rows;
    return {
        matching => $matching,
        shown    => scalar @out,
        rows     => \@out,
        unreadable_fields => [ scalar @{ $info->{refused} } ? ('blacklisted') : () ],
        fields   => {
            id          => { portable_type => 'integer', string => 'Id' },
            name        => { portable_type => 'text',    string => 'Name' },
            email       => { portable_type => 'text',    string => 'Email' },
            company     => { portable_type => 'text',    string => 'Company' },
            tags        => { portable_type => 'text',    string => 'Tags' },
            blacklisted => { portable_type => 'boolean', string => 'Blacklisted' },
            lists       => { portable_type => 'text',    string => 'Lists (name, opt_out, since)' },
        },
    };
}

1;
