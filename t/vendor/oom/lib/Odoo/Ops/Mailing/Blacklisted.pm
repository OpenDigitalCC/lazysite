package Odoo::Ops::Mailing::Blacklisted;

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

Odoo::Ops::Mailing::Blacklisted - what is on Odoo's mail blacklist, and why

=head1 SYNOPSIS

    oom-ops run mailing.blacklisted --conf ops.conf
    oom-ops run mailing.blacklisted --conf ops.conf --set email=gone@example.com,away@example.com
    oom-ops run mailing.blacklisted --conf ops.conf --set contains=OOMM12345 --set archived=1

=head1 DESCRIPTION

C<mailing.blacklisted> reads the rows of C<mail.blacklist>, the list
Odoo's mass mailing never sends to. It is the read that
C<mailing.blacklist> lacked: C<mailing.contacts> shows a contact's
C<blacklisted> flag, but a blacklist row with no contact (an address
blacklisted before it was ever imported, or whose contact was deleted)
was invisible. The filters combine:

    email     one address or a comma-separated list, matched on the
              normalised (trimmed, lower-cased) address
    contains  rows whose address contains the text (a stamp, a domain)
    archived  include removed rows (a removal archives the row)
    limit     rows to return, default 200

One row per blacklist row: C<id>, C<email>, C<active> (false once
removed), C<created> (Odoo's C<create_date>, UTC), C<reason> and
C<contacts>. C<reason> is the text of the last note on the row's own
thread that C<mailing.blacklist> or Odoo's own remove-with-reason wrote
("Blacklisting Reason: ..." or "Unblacklisting Reason: ...", the prefix
taken off); absent when no reason was given, because the reason is a
C<mail.message> on the row and nowhere else (proved on demo16,
2026-10-15). C<contacts> is the C<mailing.contact> rows with that
normalised address, as C<< { id, name } >>, empty when there is none.

The report is C<< { matching, shown, rows, fields } >>: C<matching> is
how many rows the filters select, C<shown> how many are returned, so a
cut-off is never silent. Series: Odoo 16 and 18; another series is
refused by name until its profile is probed.

=cut

sub op_name ($class) { 'mailing.blacklisted' }
sub summary ($class) { 'Read the mail blacklist: address, whether it is active, the reason given, the contacts with that address' }
sub pack    ($class) { 'mailing' }
# The keys of the descriptors this read returns in its fields block.
sub fields ($class) {
    return [
        { name => 'id', meaning => 'Id' },
        { name => 'email', meaning => 'Email' },
        { name => 'active', meaning => 'On the blacklist (false once removed)' },
        { name => 'created', meaning => 'Blacklisted since (Odoo\'s create date, UTC)' },
        { name => 'reason', meaning => 'The last reason noted on the row' },
        { name => 'contacts', meaning => 'Mailing contacts with this address (id, name)' },
    ];
}

sub params ($class) {
    {   email    => { type => 'list', help => 'one address or a comma-separated list (matched on the normalised address)' },
        contains => { type => 'str',  help => 'rows whose address contains this text' },
        archived => { type => 'bool', default => 0, help => 'include removed rows' },
        limit    => { type => 'int',  default => 200, help => 'rows to return' },
    };
}
sub read_scope ($class) {
    {   blacklist => [qw(search_read search_count)],
        contact   => ['search_read'],
        message   => ['search_read'],
    };
}

sub scope_for ($self, $phase) { Odoo::Ops::Mailing::Common::scope( $self, $phase, $self->SUPER::scope_for($phase) ) }

my $REASON = qr/^\s*(?:Un)?[Bb]lacklisting Reason:\s*/;

sub report ($self) {
    my $p = Odoo::Ops::Mailing::Common::ready($self);
    my $f = sub ( $lm, $lf ) { $p->field( $lm => $lf ) };
    Odoo::Error->throw( kind => 'usage', message => 'mailing.blacklisted: limit must be 1 or more' ) if $self->param('limit') < 1;

    my @dom;
    if ( defined $self->param('email') ) {
        my @e = map { Odoo::Ops::Mailing::Common::email($_) // lc $_ } @{ $self->param('email') };
        push @dom, [ $f->( blacklist => 'email' ), 'in', \@e ];
    }
    push @dom, [ $f->( blacklist => 'email' ), 'ilike', $self->param('contains') ] if defined $self->param('contains');
    push @dom, [ $f->( blacklist => 'active' ), 'in', [ JSON::PP::true, JSON::PP::false ] ] if $self->param('archived');

    my $bm = $self->model('blacklist');
    my $matching = $bm->count( \@dom );
    my $rows = $bm->search_read( \@dom, [ map { $f->( blacklist => $_ ) } qw(email active created) ], order => 'id asc', limit => $self->param('limit') );

    # the contacts are found by normalised address, which is what a blacklist row is matched on
    my %addr = map { lc $_->{ $f->( blacklist => 'email' ) } => 1 } @$rows;
    my %contacts;
    if (%addr) {
        my ( $ce, $cn ) = ( $f->( contact => 'email_normalized' ), $f->( contact => 'name' ) );
        my $cs = $self->model('contact')->all( [ [ $ce, 'in', [ sort keys %addr ] ] ], [ $ce, $cn ] );
        push @{ $contacts{ lc $_->{$ce} } }, { id => $_->{id}, name => Odoo::Ops::Mailing::Common::text( $_->{$cn} ) } for sort { $a->{id} <=> $b->{id} } @$cs;
    }

    # the last reason note of each row: the highest message id wins, whatever order the server answers in
    my %reason;
    my @ids = map { $_->{id} } @$rows;
    if (@ids) {
        my ( $mm, $mr, $mb ) = map { $f->( message => $_ ) } qw(model res_id body);
        my $ms = $self->model('message')->search_read( [ [ $mm, '=', $p->model_name('blacklist') ], [ $mr, 'in', \@ids ] ], [ $mr, $mb ], order => 'id desc' );
        for my $m ( sort { $a->{id} <=> $b->{id} } @$ms ) {
            my $text = _plain( $m->{$mb} );
            next if $text !~ $REASON;
            $text =~ s/$REASON//;
            $reason{ $m->{$mr} } = $text;
        }
    }

    my @out = map {
        my $r = $_;
        my $e = $r->{ $f->( blacklist => 'email' ) };
        my $created = Odoo::Ops::Mailing::Common::text( $r->{ $f->( blacklist => 'created' ) } );
        +{
            id       => $r->{id},
            email    => lc $e,
            active   => $r->{ $f->( blacklist => 'active' ) } ? JSON::PP::true : JSON::PP::false,
            ( length $created ? ( created => $created ) : () ),
            ( length( $reason{ $r->{id} } // '' ) ? ( reason => $reason{ $r->{id} } ) : () ),
            contacts => $contacts{ lc $e } // [],
        };
    } @$rows;
    return {
        matching => $matching,
        shown    => scalar @out,
        rows     => \@out,
        fields   => {
            id       => { portable_type => 'integer', string => 'Id' },
            email    => { portable_type => 'text',    string => 'Email' },
            active   => { portable_type => 'boolean', string => 'On the blacklist (false once removed)' },
            created  => { portable_type => 'datetime', string => 'Blacklisted since (Odoo\'s create date, UTC)' },
            reason   => { portable_type => 'text',    string => 'The last reason noted on the row' },
            contacts => { portable_type => 'list',    string => 'Mailing contacts with this address (id, name)' },
        },
    };
}

# a note's body is HTML: the text a person reads
sub _plain ($html) {
    my $t = Odoo::Ops::Mailing::Common::text($html);
    $t =~ s/<[^>]*>//g;
    $t =~ s/&lt;/</g;
    $t =~ s/&gt;/>/g;
    $t =~ s/&quot;/"/g;
    $t =~ s/&#39;/'/g;
    $t =~ s/&amp;/&/g;
    $t =~ s/\s+\z//;
    return $t;
}

1;
