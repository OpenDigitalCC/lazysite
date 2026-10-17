package Odoo::Ops::Discuss::Messages;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Discuss::Common;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Discuss::Messages - the messages of one channel

=head1 SYNOPSIS

    oom-ops run discuss.messages --conf ops.conf --set channel=7
    oom-ops run discuss.messages --conf ops.conf --set channel=7 --set since=120 --set limit=50

=head1 DESCRIPTION

C<discuss.messages>: the messages of the channel C<channel> (its id, as
C<discuss.channels> prints it), newest first. C<since> keeps the messages
after that message id; C<limit> (default 20) caps the count. A message Odoo
keeps for the system alone (C<user_notification>) is left out, as its own
client leaves it out.

One row per message: C<id>, C<author> (the partner's name) and C<author_id>,
C<date>, C<body_text> (the body as plain text), C<body_html> (as Odoo holds it),
C<parent_id> (the message replied to, or null), C<attachments> (their names),
C<type> (Odoo's message type: C<comment> is what people write, C<notification>
is a join or a leave) and C<seen> (whether the login has read it: its id is not
after the login's last seen message; false for a login with no membership row).
A message emptied by C<discuss.delete> reads with an empty body.

The channel is read as the login: a channel it cannot read is refused by name.
Series: written for Odoo 16; another series is refused by name.

=cut

sub op_name ($class) { 'discuss.messages' }
sub summary ($class) { 'Read the messages of one Discuss channel, newest first' }
sub pack    ($class) { 'discuss' }
sub fields ($class) {
    return [
        { name => 'id', meaning => 'Id' },
        { name => 'author', meaning => 'Author (the partner)' },
        { name => 'author_id', meaning => 'Author partner id' },
        { name => 'date', meaning => 'Date (UTC)' },
        { name => 'body_text', meaning => 'Body as plain text' },
        { name => 'body_html', meaning => 'Body as Odoo holds it' },
        { name => 'parent_id', meaning => 'The message replied to' },
        { name => 'attachments', meaning => 'Attachment names' },
        { name => 'type', meaning => 'Odoo message type' },
        { name => 'seen', meaning => 'The login has read it' },
    ];
}

sub params ($class) {
    {   channel => { type => 'int', required => 1, help => 'the channel id (discuss.channels prints it)' },
        since   => { type => 'int', help => 'only messages after this message id' },
        limit   => { type => 'int', default => 20, help => 'at most this many messages (default 20)' },
    };
}
sub read_scope ($class) {
    { channel => ['search_read'], member => ['search_read'], message => ['search_read'], attachment => ['search_read'] };
}

sub report ($self) {
    my $p = Odoo::Ops::Discuss::Common::ready($self);
    my $f = sub ( $lm, $lf ) { $p->field( $lm => $lf ) };
    my $limit = $self->param('limit');
    Odoo::Error->throw( kind => 'usage', message => 'discuss.messages: limit must be at least 1' ) if $limit < 1;
    my $cid = $self->param('channel');
    my $ch  = Odoo::Ops::Discuss::Common::channel_row( $self, $cid )
        or Odoo::Error->throw( kind => 'usage', message => "discuss.messages: this login can read no channel $cid", fix => 'oom-ops run discuss.channels lists the channels' );
    my $me  = Odoo::Ops::Discuss::Common::my_partner( $self->client );
    my $mem = Odoo::Ops::Discuss::Common::member_row( $self, $cid, $me );
    my @dom = (
        [ $f->( message => 'model' ), '=', $p->model_name('channel') ],
        [ $f->( message => 'res_id' ), '=', 0 + $cid ],
        [ $f->( message => 'type' ), '!=', 'user_notification' ],
    );
    push @dom, [ 'id', '>', $self->param('since') ] if defined $self->param('since');
    my $rows = $self->model('message')->search_read( \@dom,
        [ map { $f->( message => $_ ) } qw(author date body parent attachments type) ], order => 'id desc', limit => $limit );
    my %att;
    my @aid = map { @{ $_->{ $f->( message => 'attachments' ) } // [] } } @$rows;
    if (@aid) {
        $att{ $_->{id} } = $_->{ $f->( attachment => 'name' ) }
            for @{ $self->model('attachment')->search_read( [ [ 'id', 'in', \@aid ] ], [ $f->( attachment => 'name' ) ] ) };
    }
    my $seen = $mem ? $mem->{seen} : undef;
    my @out = map {
        my $r = $_;
        +{
            id          => $r->{id},
            author      => Odoo::Ops::Discuss::Common::name_of( $r->{ $f->( message => 'author' ) } ),
            author_id   => Odoo::Ops::Discuss::Common::id_of( $r->{ $f->( message => 'author' ) } ),
            date        => $r->{ $f->( message => 'date' ) },
            body_text   => Odoo::Ops::Discuss::Common::html_text( $r->{ $f->( message => 'body' ) } ),
            body_html   => $r->{ $f->( message => 'body' ) } // '',
            parent_id   => Odoo::Ops::Discuss::Common::id_of( $r->{ $f->( message => 'parent' ) } ),
            attachments => [ map { $att{$_} // "attachment $_" } @{ $r->{ $f->( message => 'attachments' ) } // [] } ],
            type        => $r->{ $f->( message => 'type' ) },
            seen        => ( defined $seen && $r->{id} <= $seen ) ? JSON::PP::true : JSON::PP::false,
        };
    } @$rows;
    my $int = sub ($s) { { portable_type => 'integer', string => $s } };
    my $txt = sub ($s) { { portable_type => 'text', string => $s } };
    return {
        channel => { id => $ch->{id}, name => $ch->{name}, type => $ch->{type} },
        count   => scalar @out,
        rows    => \@out,
        fields  => {
            id => $int->('Id'), author => $txt->('Author (the partner)'), author_id => $int->('Author partner id'),
            date => { portable_type => 'datetime', string => 'Date (UTC)' }, body_text => $txt->('Body as plain text'),
            body_html => $txt->('Body as Odoo holds it'), parent_id => $int->('The message replied to'),
            attachments => $txt->('Attachment names'), type => $txt->('Odoo message type'),
            seen => { portable_type => 'boolean', string => 'The login has read it' },
        },
    };
}

1;
