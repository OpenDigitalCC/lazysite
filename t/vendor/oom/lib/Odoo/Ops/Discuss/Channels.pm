package Odoo::Ops::Discuss::Channels;

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

Odoo::Ops::Discuss::Channels - the channels the login belongs to

=head1 SYNOPSIS

    oom-ops run discuss.channels --conf ops.conf
    oom-ops run discuss.channels --conf ops.conf --set type=chat

=head1 DESCRIPTION

C<discuss.channels>: one row per channel the login the config runs as is a
member of - C<id>, C<name>, C<type> (C<channel>, C<chat> or C<group>),
C<members> (Odoo's member count), C<unread> (the member's own unread counter,
as Odoo computes it), C<last_message> (the id of the newest message, or null),
C<seen> (the id of the last message the login has read, or null). Archived
channels are left out. C<type> keeps one channel type.

The report is C<< { count, rows, fields } >> like the other reads. Series: 16, 18
and 19; 17 is refused by name as not probed.

=cut

sub op_name ($class) { 'discuss.channels' }
sub summary ($class) { 'Read the Discuss channels this login belongs to, with unread counts' }
sub pack    ($class) { 'discuss' }
sub fields ($class) {
    return [
        { name => 'id', meaning => 'Id' },
        { name => 'name', meaning => 'Name' },
        { name => 'type', meaning => 'channel, chat or group' },
        { name => 'members', meaning => 'Members' },
        { name => 'unread', meaning => 'Messages after the last one this login has read' },
        { name => 'last_message', meaning => 'Id of the newest message' },
        { name => 'seen', meaning => 'Id of the last message this login has read' },
    ];
}

sub params ($class) {
    { type => { type => 'str', help => 'only channels of this type: channel, chat or group' } };
}
sub read_scope ($class) {
    { channel => [qw(search_read read)], member => ['search_read'], message => ['search_read'] };
}

sub report ($self) {
    my $p = Odoo::Ops::Discuss::Common::ready($self);
    my $f = sub ( $lm, $lf ) { $p->field( $lm => $lf ) };
    my $me = Odoo::Ops::Discuss::Common::my_partner( $self->client );
    my $mem = $self->model('member')->search_read( [ [ $f->( member => 'partner' ), '=', $me ] ],
        [ map { $f->( member => $_ ) } qw(channel seen unread) ] );
    my %by = map { Odoo::Ops::Discuss::Common::id_of( $_->{ $f->( member => 'channel' ) } ) => $_ } @$mem;
    my @dom = ( [ 'id', 'in', [ sort { $a <=> $b } keys %by ] ] );
    push @dom, [ $f->( channel => 'type' ), '=', $self->param('type') ] if defined $self->param('type');
    my $chan = %by ? $self->model('channel')->search_read( \@dom,
        [ map { $f->( channel => $_ ) } qw(name type members) ] ) : [];
    my @out;
    for my $c ( sort { lc( $a->{ $f->( channel => 'name' ) } // '' ) cmp lc( $b->{ $f->( channel => 'name' ) } // '' ) || $a->{id} <=> $b->{id} } @$chan ) {
        my $m = $by{ $c->{id} };
        push @out, {
            id           => $c->{id},
            name         => $c->{ $f->( channel => 'name' ) },
            type         => $c->{ $f->( channel => 'type' ) },
            members      => $c->{ $f->( channel => 'members' ) } // 0,
            unread       => $m->{ $f->( member => 'unread' ) } // 0,
            last_message => Odoo::Ops::Discuss::Common::last_message_id( $self, $c->{id} ),
            seen         => Odoo::Ops::Discuss::Common::id_of( $m->{ $f->( member => 'seen' ) } ),
        };
    }
    my $int = sub ($s) { { portable_type => 'integer', string => $s } };
    return {
        count  => scalar @out,
        rows   => \@out,
        fields => {
            id           => $int->('Id'),
            name         => { portable_type => 'text', string => 'Name' },
            type         => { portable_type => 'text', string => 'channel, chat or group' },
            members      => $int->('Members'),
            unread       => $int->('Messages after the last one this login has read'),
            last_message => $int->('Id of the newest message'),
            seen         => $int->('Id of the last message this login has read'),
        },
    };
}

1;
