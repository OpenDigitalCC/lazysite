package Odoo::Ops::Mailing::Blacklist;

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

Odoo::Ops::Mailing::Blacklist - addresses Odoo must never mail

=head1 SYNOPSIS

    oom-ops run mailing.blacklist --conf ops.conf --set email=gone@example.com --set reason="asked by phone"
    oom-ops run mailing.blacklist --conf ops.conf --set email=back@example.com --set mode=remove

=head1 DESCRIPTION

C<mailing.blacklist> puts addresses on Odoo's blacklist (C<mail.blacklist>)
or takes them off. One address is C<email>; many are C<rows>, C<records>
or C<mapping> with an C<email> column, as C<mailing.subscribe> reads
them. C<mode> is C<add> (default) or C<remove>. An address on the
blacklist is skipped by every mass mailing, whatever list it is on and
whether or not it is opted out; a contact on it reads C<blacklisted>.

Buckets: C<add> (made, or an archived row brought back), C<already-listed>,
C<remove>, C<not-listed>, and the holds C<invalid-email> and
C<duplicate-in-input>. A removal archives the row (C<active> false), as
Odoo's own unblacklisting does, so the address can be added again and
the history stays.

C<reason> is written on the blacklist row's own message thread -
"Blacklisting Reason: ..." on an add, "Unblacklisting Reason: ..." on
a removal, the words Odoo's own remove-with-reason uses - so a person
reading the record in Odoo sees why. Both are C<custom> changes
(kind C<blacklist-add>, C<blacklist-remove>) because the reason is
posted after the row is made; a revert of one is the other.

Who may do this on Odoo 16: an administrator (Settings) or an Email
Marketing user - both can create, write and delete C<mail.blacklist>
rows (proved on demo16, 2026-10-15).

Series: written for Odoo 16; another series is refused by name until its
profile is probed.

=cut

sub op_name ($class) { 'mailing.blacklist' }
sub summary ($class) { 'Plan adding addresses to Odoo\'s mail blacklist, or taking them off (archive)' }
sub pack    ($class) { 'mailing' }
# What a plan of this operation sorts rows into (oom-ops describe prints them;
# t/99-declared-buckets.t checks them against what the tests plan).
sub buckets ($class) {
    return [
        { name => 'add', meaning => 'an address is put on the blacklist (made, or an archived row brought back)' },
        { name => 'remove', meaning => 'an address is taken off the blacklist (the row is archived)' },
        { name => 'already-listed', meaning => 'the address is on the blacklist already' },
        { name => 'not-listed', meaning => 'the address is not on the blacklist' },
    ];
}
sub holds ($class) {
    return [
        { name => 'invalid-email', meaning => 'the text is not an address' },
        { name => 'invalid-row', meaning => 'the source could not map the row' },
        { name => 'duplicate-in-input', meaning => 'an earlier row carries the same address' },
    ];
}

sub params ($class) {
    {   email  => { type => 'str', help => 'one address (or give rows, records or mapping)' },
        Odoo::Ops::Mailing::Common::rows_params(),
        mode   => { type => 'str', default => 'add', help => 'add (default) or remove' },
        reason => { type => 'str', help => 'why; written on the blacklist row\'s thread' },
    };
}
sub read_scope  ($class) { { blacklist => ['search_read'] } }
sub write_scope ($class) { { blacklist => [qw(create write read message_post)] } }

sub scope_for ($self, $phase) { Odoo::Ops::Mailing::Common::scope( $self, $phase, $self->SUPER::scope_for($phase) ) }

sub plan ($self) {
    my $p    = Odoo::Ops::Mailing::Common::ready($self);
    my $mode = $self->param('mode');
    Odoo::Error->throw( kind => 'usage', message => "mailing.blacklist: mode must be add or remove, not '$mode'" ) if $mode !~ /^(add|remove)\z/;
    my $f = sub ($lf) { $p->field( blacklist => $lf ) };
    my @in = grep { defined $self->param($_) } qw(email rows records mapping);
    Odoo::Error->throw( kind => 'usage', message => 'mailing.blacklist: give exactly one of email, rows, records, mapping (got ' . ( @in ? "@in" : 'none' ) . ')' )
        if @in != 1;
    my $rows = $in[0] eq 'email'
        ? [ { key => 'email', values => { email => $self->param('email') } } ]
        : Odoo::Ops::Mailing::Common::rows($self);

    my %addr = map { $_ => 1 } grep { defined } map { Odoo::Ops::Mailing::Common::email( ref $_->{values} eq 'HASH' ? $_->{values}{email} : undef ) } @$rows;
    my %have;
    if (%addr) {
        my $bl = $self->model('blacklist')->all( [ [ $f->('email'), 'in', [ sort keys %addr ] ], [ $f->('active'), 'in', [ JSON::PP::true, JSON::PP::false ] ] ],
            [ $f->('email'), $f->('active') ] );
        $have{ lc $_->{ $f->('email') } } = $_ for @$bl;
    }
    my $plan = $self->new_plan( input_count => scalar @$rows );
    $plan->note( "mode $mode; " . scalar(@$rows) . ' address(es)' . ( defined $self->param('reason') ? "; reason: " . $self->param('reason') : '' ) );
    my ( %seen, $n );
    for my $row (@$rows) {
        $n++;
        my $key = "row:$row->{key}";
        my $hold = sub ($b, $why) { $plan->add( bucket => $b, action => 'hold', key => $key, reason => $why ) };
        my $skip = sub ($b, $why, %x) { $plan->add( bucket => $b, action => 'skip', key => $key, reason => $why, %x ) };
        if ( defined $row->{error} ) { $hold->( 'invalid-row', $row->{error} ); next }
        if ( my $h = $row->{held} ) { my ($k) = $h =~ /^(\w+):/; $hold->( 'held-' . ( $k // 'flag' ), $h ); next }
        my $raw = ref $row->{values} eq 'HASH' ? $row->{values}{email} : undef;
        my $e   = Odoo::Ops::Mailing::Common::email($raw);
        if ( !defined $e ) { $hold->( 'invalid-email', "'" . ( $raw // '' ) . "' is not an email address" ); next }
        if ( $seen{$e} ) { $hold->( 'duplicate-in-input', "same address as row #$seen{$e}" ); next }
        $seen{$e} = $n;
        my $r = $have{$e};
        my $live = $r && $r->{ $f->('active') };
        my $bl = $p->model_name('blacklist');
        my @post = defined $self->param('reason') && length $self->param('reason') ? ( [ $bl, 'message_post' ] ) : ();
        my %c = ( action => 'custom', handler => $self->op_name, model => $bl, key => $key );
        if ( $mode eq 'add' ) {
            if ($live) { $skip->( 'already-listed', "$e is on the blacklist", id => $r->{id} ); next }
            $plan->add( %c, bucket => 'add', kind => 'blacklist-add', ( $r ? ( id => $r->{id}, before => { $f->('active') => 0 } ) : () ),
                calls => [ ( $r ? () : ( [ $bl, 'create' ] ) ), [ $bl, 'write' ], [ $bl, 'read' ], @post ],
                vals => $self->_vals($e), reason => $r ? "$e was unblacklisted; brought back" : "$e is not on the blacklist" );
        }
        else {
            if ( !$live ) { $skip->( 'not-listed', "$e is not on the blacklist" ); next }
            $plan->add( %c, bucket => 'remove', kind => 'blacklist-remove', id => $r->{id}, before => { $f->('active') => 1 },
                calls => [ [ $bl, 'write' ], [ $bl, 'read' ], @post ],
                vals => $self->_vals($e), reason => "$e comes off the blacklist (the row is archived)" );
        }
    }
    return $plan;
}

# everything apply needs, in physical names, so the plan is self-contained
sub _vals ($self, $e) {
    my $p = $self->profile;
    return {
        email_field  => $p->field( blacklist => 'email' ),
        active_field => $p->field( blacklist => 'active' ),
        email        => $e,
        ( defined $self->param('reason') ? ( reason => $self->param('reason') ) : () ),
    };
}

sub apply_custom ($class, $client, $c) {
    my $kind = $c->{kind} // '';
    Odoo::Error->throw( kind => 'usage', message => "mailing.blacklist cannot apply kind '$kind'" ) if $kind !~ /^blacklist-(add|remove)\z/;
    my $add = $1 eq 'add';
    my $v   = $c->{vals};
    my $m   = $client->model( $c->{model} );
    my $id  = $c->{id};
    my $reported = 'write';    # created when Odoo made the row, written when it was brought back or archived
    if ($add) {
        if ($id) { $m->write( $id, { $v->{active_field} => JSON::PP::true } ) }
        else {
            # create returns the existing row when the address is already there (Odoo's own create), so a row made since planning is reused
            my $made = $m->create( { $v->{email_field} => $v->{email} } );
            $id = ref $made eq 'ARRAY' ? $made->[0] : $made;
            $reported = 'create';
            $m->write( $id, { $v->{active_field} => JSON::PP::true } );
        }
    }
    else {
        $m->write( $id, { $v->{active_field} => JSON::PP::false } );
    }
    if ( defined $v->{reason} && length $v->{reason} ) {
        my $text = $v->{reason} =~ s/&/&amp;/gr =~ s/</&lt;/gr =~ s/>/&gt;/gr;
        $m->call( 'message_post', [ [$id] ], body => ( $add ? 'Blacklisting Reason: ' : 'Unblacklisting Reason: ' ) . $text,
            message_type => 'comment', subtype_xmlid => 'mail.mt_note' );
    }
    my $after = $m->read_one( $id, [ $v->{email_field}, $v->{active_field} ] );
    my $ok = $after && ( $after->{ $v->{active_field} } ? 1 : 0 ) == ( $add ? 1 : 0 );
    return { id => $id, after => $ok ? $after : undef, returned => $id, reported => $reported };
}

# a revert of an add archives the row; a revert of a removal brings it back
sub undo_custom ($class, $entry) {
    my $kind = $entry->{kind} // '';
    return ( undef, "$kind has no inverse here" ) if $kind !~ /^blacklist-(add|remove)\z/;
    my $was_add = $1 eq 'add';
    my $v = { %{ $entry->{vals} // {} } };
    delete $v->{reason};
    return {
        action => 'custom', handler => 'mailing.blacklist', model => $entry->{model}, id => $entry->{id},
        kind   => $was_add ? 'blacklist-remove' : 'blacklist-add',
        bucket => $was_add ? 'undo-add' : 'undo-remove',
        before => { $v->{active_field} => $was_add ? 1 : 0 },
        calls  => [ map { [ $entry->{model}, $_ ] } qw(write read) ],
        vals   => $v,
    };
}

1;
