package Odoo::Ops::Mailing::Delete;

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

Odoo::Ops::Mailing::Delete - delete a draft mailing, contacts or lists; a sent mailing is kept

=head1 SYNOPSIS

    oom-ops run mailing.delete --conf ops.conf --set mailing=7
    oom-ops run mailing.delete --conf ops.conf --set contact=12,13
    oom-ops run mailing.delete --conf ops.conf --set email=gone@example.com
    oom-ops run mailing.delete --conf ops.conf --set list="Old news"
    oom-ops run mailing.delete --conf ops.conf --set list=4 --set force=1

=head1 DESCRIPTION

Exactly one of C<mailing>, C<contact>, C<email>, C<list> is given; two
together are refused by name.

B<A mailing.> The owner's position (2026-10-15, open to change): a sent
mailing is the record of what went out and is kept. So a mailing is
deleted when it is a C<draft> (which includes one that C<mailing.cancel>
took back from the queue) and held otherwise:

    delete       the draft is unlinked (Odoo 16 allows it; proved on demo16)
    sent-kept    held: the mailing is in_queue, sending or done. The hold names the
                 traces and the contacts they point at, and says to archive it with
                 mailing.archive

B<Contacts.> C<contact> is mailing-contact ids and C<email> addresses
(matched on the normalised address, so every contact with that address),
each comma-separated. One change per contact in bucket C<delete>. The
contact's subscriptions go with it (the subscription's C<contact_id> is
ondelete cascade); the lists stay. A contact that mailing traces point at
still deletes: the trace keeps the address (its C<email> is its own
field) and loses the contact (C<res_id> is not a foreign key), and the
change says so, per mailing. An id or address that names no contact is
held (C<unknown-contact>, C<unknown-email>).

B<Lists.> C<list> is list names or ids, comma-separated (an archived list
is found too). One change per list in bucket C<delete>. The list's
subscription rows go with it (ondelete cascade); the contacts stay. A
list that a mailing still names in C<contact_list_ids> (archived mailings
included) is held C<in-use>, naming the mailings, unless C<force=1>: then
the change says each mailing will lose the list (Odoo drops the link; the
mailing stays). A name or id that names no list is held (C<unknown-list>),
and a name shared by two lists is held C<ambiguous-list> so that the
person gives the id.

B<Reverting.> A mailing, contact or list delete is a C<custom> change,
because the runner does not recreate a plain C<unlink> (it holds one as
irreversible). Each carries what it needs to be recreated, and a revert
recreates the record with a B<new id>. A contact comes back with its
name, address, company, tags B<and its memberships> (the lists it was on,
with C<opt_out>, as C<subscription_list_ids>); a list comes back with its
name, C<active> and its subscription rows (each contact and C<opt_out>).
What does not come back: the traces that pointed at the old contact id
(they keep the address and the old, now empty, reference), the lists a
mailing lost under C<force=1>, and a subscription whose list or contact
has been deleted since. The date an opt-out was made is Odoo's to stamp:
a recreated opt-out carries the date of the revert.

Series: written for Odoo 16; another series is refused by name until its
profile is probed.

=cut

sub op_name ($class) { 'mailing.delete' }
sub summary ($class) { 'Plan deleting a draft mailing, mailing contacts or mailing lists (a sent mailing is kept: archive it instead)' }
sub pack    ($class) { 'mailing' }
sub params ($class) {
    {   mailing => { type => 'int',  help => 'a draft mailing, by id' },
        contact => { type => 'list', help => 'mailing contacts to delete, by id (comma-separated)' },
        email   => { type => 'list', help => 'mailing contacts to delete, by address (comma-separated, normalised match)' },
        list    => { type => 'list', help => 'mailing lists to delete, by name or id (comma-separated)' },
        force   => { type => 'bool', default => 0, help => 'with list: delete a list a mailing still names; the mailing loses it' },
    };
}
sub buckets ($class) {
    [ { name => 'delete', meaning => 'the draft mailing, contact or list is unlinked; a revert recreates it with a new id (a contact or list with its memberships)' } ];
}
sub holds ($class) {
    [   { name => 'sent-kept', meaning => 'a sent (or queued, or sending) mailing is kept as the record of what went out; archive it with mailing.archive' },
        { name => 'unknown-contact', meaning => 'no mailing contact has that id' },
        { name => 'unknown-email', meaning => 'no mailing contact has that address (or the text is not an address)' },
        { name => 'unknown-list', meaning => 'no mailing list has that name or id' },
        { name => 'ambiguous-list', meaning => 'the name is shared by several lists; give the id' },
        { name => 'in-use', meaning => 'a mailing still names the list; force=1 deletes it and the mailing loses the list' },
    ];
}
sub read_scope ($class) {
    {   mailing      => [qw(read search_read)],
        contact      => [qw(read search_read)],
        list         => [qw(read search_read)],
        subscription => ['search_read'],
        trace        => [qw(search_read search_count)],
    };
}
sub write_scope ($class) {
    {   mailing => [qw(read search_count unlink create)],
        contact => [qw(read search_count unlink create)],
        list    => [qw(read search_count unlink create)],
    };
}

sub scope_for ($self, $phase) { Odoo::Ops::Mailing::Common::scope( $self, $phase, $self->SUPER::scope_for($phase) ) }

my @KEEP = qw(subject body_html body_arch email_from reply_to reply_to_mode schedule_type schedule_date);

sub plan ($self) {
    my $p = Odoo::Ops::Mailing::Common::ready($self);
    my @given = grep { defined $self->param($_) } qw(mailing contact email list);
    Odoo::Error->throw( kind => 'usage', message => 'mailing.delete: give exactly one of mailing, contact, email, list (got ' . ( @given ? join( ' and ', @given ) : 'none' ) . ')' )
        if @given != 1;
    Odoo::Error->throw( kind => 'usage', message => 'mailing.delete: force applies to list only (a list a mailing still names)' )
        if $self->param('force') && $given[0] ne 'list';

    return $self->_plan_contacts($p) if $given[0] eq 'contact' || $given[0] eq 'email';
    return $self->_plan_lists($p)    if $given[0] eq 'list';
    return $self->_plan_mailing($p);
}

sub _plan_mailing ($self, $p) {
    my $f = sub ($lf) { $p->field( mailing => $lf ) };
    my $id = $self->param('mailing');
    my $m  = $self->model('mailing')->read( [$id], [ map { $f->($_) } qw(state model lists active), @KEEP ] )->[0]
        or Odoo::Error->throw( kind => 'refused', code => 'unknown-mailing', message => "mailing.delete: no mailing $id",
            fix => q(oom-ops run mailing.status --conf <conf> lists the mailings) );
    my $state = $m->{ $f->('state') };
    my $subject = $m->{ $f->('subject') };
    my $plan = $self->new_plan( input_count => 1 );
    my $key  = "mailing:$id";

    if ( $state ne 'draft' ) {
        my $t = $p->field( trace => 'mailing' );
        my %tf = map { $_ => $p->field( trace => $_ ) } qw(email res_id model status);
        my $tm = $self->model('trace');
        my $n  = $tm->count( [ [ $t, '=', $id ] ] );
        my $rows = $tm->search_read( [ [ $t, '=', $id ] ], [ values %tf ], order => 'id asc', limit => 10 );
        my @who = map {
            my $c = ( $_->{ $tf{model} } // '' ) eq $p->model_name('contact') && $_->{ $tf{res_id} } ? ", contact $_->{$tf{res_id}}" : '';
            "$_->{$tf{email}} (trace $_->{id}$c, $_->{$tf{status}})"
        } @$rows;
        my $about = $n ? "its $n trace(s) point at " . join( '; ', @who ) . ( $n > @who ? "; and " . ( $n - @who ) . ' more' : '' ) : 'it has no traces';
        $plan->add( bucket => 'sent-kept', action => 'hold', key => $key, id => $id,
            reason => "mailing $id ('$subject') is $state: a sent mailing is kept as the record of what went out; archive it with mailing.archive. Deleting it would also delete the record of who was mailed: $about" );
        return $plan;
    }

    my %recreate = (
        ( map { $f->($_) => $m->{ $f->($_) } } grep { my $v = $m->{ $f->($_) }; defined $v && !ref $v && $v ne '' } @KEEP ),
        $f->('model') => Odoo::Ops::Mailing::Common::id_of( $m->{ $f->('model') } ),
        $f->('lists') => [ [ 6, 0, $m->{ $f->('lists') } // [] ] ],
        $f->('active') => $m->{ $f->('active') } ? JSON::PP::true : JSON::PP::false,
    );
    $plan->note("mailing $id ('$subject') is a draft; deleting it takes its record away. A revert recreates it from the before-image with a new id");
    $plan->add(
        bucket => 'delete', action => 'custom', handler => $self->op_name, kind => 'delete',
        model => $p->model_name('mailing'), id => $id, key => $key,
        before => { $f->('state') => 'draft', $f->('subject') => $subject },
        vals   => { recreate => \%recreate, state_field => $f->('state') },
        reason => "mailing $id ('$subject') is a draft and is deleted",
    );
    return $plan;
}

# Contacts: one change per contact, found by id or by normalised address.
sub _plan_contacts ($self, $p) {
    my $f = sub ( $lm, $lf ) { $p->field( $lm => $lf ) };
    my $cm = $self->model('contact');
    my @cf = map { $f->( contact => $_ ) } qw(name email company tags);
    my ( @items, %contact, @order );    # an item is what the person named: held when it finds nothing
    if ( defined $self->param('contact') ) {
        for my $ref ( @{ $self->param('contact') } ) {
            Odoo::Error->throw( kind => 'usage', message => "mailing.delete: contact takes ids, not '$ref'" ) if $ref !~ /^\d+\z/;
            push @items, { key => "contact:$ref", ref => $ref, ids => [ 0 + $ref ], hold => 'unknown-contact', why => "no mailing contact $ref" };
        }
        my @ids = map { $_->{ids}[0] } @items;
        my $rows = @ids ? $cm->search_read( [ [ 'id', 'in', \@ids ] ], \@cf ) : [];
        $contact{ $_->{id} } = $_ for @$rows;
    }
    else {
        my %seen;
        for my $ref ( @{ $self->param('email') } ) {
            my $e = Odoo::Ops::Mailing::Common::email($ref);
            if ( !defined $e ) { push @items, { key => "email:$ref", ref => $ref, ids => [], hold => 'unknown-email', why => "'$ref' is not an email address" }; next }
            next if $seen{$e}++;
            push @items, { key => "email:$e", ref => $e, norm => $e, hold => 'unknown-email', why => "no mailing contact has the address $e" };
        }
        my @norm = map { $_->{norm} } grep { defined $_->{norm} } @items;
        my $rows = @norm ? $cm->search_read( [ [ $f->( contact => 'email_normalized' ), 'in', \@norm ] ], [ @cf, $f->( contact => 'email_normalized' ) ], order => 'id asc' ) : [];
        $contact{ $_->{id} } = $_ for @$rows;
        for my $it ( grep { defined $_->{norm} } @items ) {
            $it->{ids} = [ map { $_->{id} } grep { lc( Odoo::Ops::Mailing::Common::text( $_->{ $f->( contact => 'email_normalized' ) } ) ) eq $it->{norm} } @$rows ];
        }
    }

    # what each contact belongs to, and which mailings' traces point at it
    my @cids = sort { $a <=> $b } keys %contact;
    my %subs;
    my %lname;
    if (@cids) {
        my @sf = map { $f->( subscription => $_ ) } qw(contact list opt_out);
        push @{ $subs{ Odoo::Ops::Mailing::Common::id_of( $_->{ $f->( subscription => 'contact' ) } ) } }, $_
            for sort { $a->{id} <=> $b->{id} } @{ $self->model('subscription')->all( [ [ $f->( subscription => 'contact' ), 'in', \@cids ] ], [ 'id', @sf ] ) };
        my @lids = keys %{ { map { Odoo::Ops::Mailing::Common::id_of( $_->{ $f->( subscription => 'list' ) } ) => 1 } map { @$_ } values %subs } };
        %lname = map { $_->{id} => $_->{ $f->( list => 'name' ) } } @{ $self->model('list')->read( [ sort { $a <=> $b } @lids ], [ $f->( list => 'name' ) ] ) } if @lids;
    }
    my %traces;    # contact => mailing => count
    if (@cids) {
        my ( $tm, $tr, $tmod ) = map { $f->( trace => $_ ) } qw(mailing res_id model);
        my $ts = $self->model('trace')->all( [ [ $tmod, '=', $p->model_name('contact') ], [ $tr, 'in', \@cids ] ], [ $tm, $tr ] );
        $traces{ $_->{$tr} }{ Odoo::Ops::Mailing::Common::id_of( $_->{$tm} ) }++ for @$ts;
    }

    # one change per distinct contact; input_count is what the plan sorts, so it is counted after the sorting
    my ( @changes, %done );
    for my $it (@items) {
        my @ids = grep { $contact{$_} } @{ $it->{ids} // [] };
        if ( !@ids ) { push @changes, { hold => $it->{hold}, key => $it->{key}, reason => "$it->{why}; mailing.contacts finds the contacts" }; next }
        for my $id (@ids) {
            next if $done{$id}++;
            push @changes, { contact => $contact{$id}, key => "contact:$id" };
        }
    }
    my $plan = $self->new_plan( input_count => scalar @changes );
    $plan->note( 'delete ' . scalar( grep { $_->{contact} } @changes ) . ' mailing contact(s); their subscriptions go with them, the lists stay' );
    for my $ch (@changes) {
        if ( $ch->{hold} ) { $plan->add( bucket => $ch->{hold}, action => 'hold', key => $ch->{key}, reason => $ch->{reason} ); next }
        my $c    = $ch->{contact};
        my $id   = $c->{id};
        my @subs = @{ $subs{$id} // [] };
        my @on   = map { ( $lname{ Odoo::Ops::Mailing::Common::id_of( $_->{ $f->( subscription => 'list' ) } ) } // 'a list' ) . ( $_->{ $f->( subscription => 'opt_out' ) } ? ' (opted out)' : '' ) } @subs;
        my @effects;
        for my $mid ( sort { $a <=> $b } keys %{ $traces{$id} // {} } ) {
            push @effects, { effect => "$traces{$id}{$mid} trace" . ( $traces{$id}{$mid} == 1 ? "" : "s" ) . " of mailing $mid keep" . ( $traces{$id}{$mid} == 1 ? "s" : "" ) . " its id and email; the contact is gone", suppressed => 0, evidence => 'mailing.trace.res_id is not a foreign key; source 16.0 mailing_trace.py' };
        }
        my $email = Odoo::Ops::Mailing::Common::text( $c->{ $f->( contact => 'email' ) } );
        my $name  = Odoo::Ops::Mailing::Common::text( $c->{ $f->( contact => 'name' ) } );
        my %recreate = (
            $f->( contact => 'name' ) => $name,
            ( length $email ? ( $f->( contact => 'email' ) => $email ) : () ),
            ( length( Odoo::Ops::Mailing::Common::text( $c->{ $f->( contact => 'company' ) } ) ) ? ( $f->( contact => 'company' ) => $c->{ $f->( contact => 'company' ) } ) : () ),
            ( @{ $c->{ $f->( contact => 'tags' ) } // [] } ? ( $f->( contact => 'tags' ) => [ [ 6, 0, $c->{ $f->( contact => 'tags' ) } ] ] ) : () ),
            # the memberships: a revert puts the contact back on its lists, opted out where it was
            ( @subs ? ( $f->( contact => 'subscriptions' ) => [ map { [ 0, 0, {
                $f->( subscription => 'list' ) => Odoo::Ops::Mailing::Common::id_of( $_->{ $f->( subscription => 'list' ) } ),
                $f->( subscription => 'opt_out' ) => $_->{ $f->( subscription => 'opt_out' ) } ? JSON::PP::true : JSON::PP::false } ] } @subs ] ) : () ),
        );
        $plan->add(
            bucket => 'delete', action => 'custom', handler => $self->op_name, kind => 'delete-contact',
            model => $p->model_name('contact'), id => $id, key => $ch->{key},
            before => { $f->( contact => 'name' ) => $name, $f->( contact => 'email' ) => $email, $f->( contact => 'subscriptions' ) => [ map { $_->{id} } @subs ] },
            vals   => { recreate => \%recreate },
            ( @effects ? ( effects => \@effects ) : () ),
            reason => "contact $id (" . ( length $email ? $email : $name ) . ') is deleted'
                . ( @on ? '; its ' . scalar(@on) . ' subscription(s) go with it (' . join( ', ', @on ) . ')' : '; it has no subscriptions' ),
        );
    }
    return $plan;
}

# Lists: one change per list; a list a mailing names is held unless forced.
sub _plan_lists ($self, $p) {
    my $f = sub ( $lm, $lf ) { $p->field( $lm => $lf ) };
    my ( @changes, %done );

    for my $ref ( @{ $self->param('list') } ) {
        my $found = Odoo::Ops::Mailing::Common::lists_by( $self, $ref, archived => 1 );
        if ( !@$found ) { push @changes, { hold => 'unknown-list', key => "list:$ref", reason => "no mailing list '$ref'; mailing.lists shows them" }; next }
        if ( @$found > 1 ) {
            push @changes, { hold => 'ambiguous-list', key => "list:$ref", reason => "'$ref' names " . scalar(@$found) . ' lists (ids ' . join( ', ', map { $_->{id} } @$found ) . '); give the id' };
            next;
        }
        my $id = $found->[0]{id};
        push @changes, { list => $found->[0], key => "list:$id" } if !$done{$id}++;
    }
    my @lids = map { $_->{list}{id} } grep { $_->{list} } @changes;
    my ( %subs, %mailings );
    if (@lids) {
        my @sf = map { $f->( subscription => $_ ) } qw(contact list opt_out);
        push @{ $subs{ Odoo::Ops::Mailing::Common::id_of( $_->{ $f->( subscription => 'list' ) } ) } }, $_
            for sort { $a->{id} <=> $b->{id} } @{ $self->model('subscription')->all( [ [ $f->( subscription => 'list' ), 'in', \@lids ] ], [ 'id', @sf ] ) };
        # archived mailings name their lists too, and a sent one is the record that used it
        my $ms = $self->model('mailing')->all( [ [ $f->( mailing => 'lists' ), 'in', \@lids ], [ $f->( mailing => 'active' ), 'in', [ JSON::PP::true, JSON::PP::false ] ] ],
            [ map { $f->( mailing => $_ ) } qw(subject state lists) ] );
        for my $m (@$ms) {
            my %in = map { $_ => 1 } @lids;
            push @{ $mailings{$_} }, $m for grep { $in{$_} } @{ $m->{ $f->( mailing => 'lists' ) } // [] };
        }
    }
    my $plan = $self->new_plan( input_count => scalar @changes );
    $plan->note( 'delete ' . scalar(@lids) . ' mailing list(s); their subscription rows go with them, the contacts stay' . ( $self->param('force') ? '; force=1: a mailing that names a list loses it' : '' ) );
    for my $ch (@changes) {
        if ( $ch->{hold} ) { $plan->add( bucket => $ch->{hold}, action => 'hold', key => $ch->{key}, reason => $ch->{reason} ); next }
        my $l    = $ch->{list};
        my $id   = $l->{id};
        my $name = $l->{ $f->( list => 'name' ) };
        my @subs = @{ $subs{$id} // [] };
        my @ms   = @{ $mailings{$id} // [] };
        my $text = sub { join '; ', map { "mailing $_->{id} ('" . $_->{ $f->( mailing => 'subject' ) } . "', $_->{ $f->( mailing => 'state' ) })" } @_ };
        my $who  = $text->(@ms);
        if ( @ms && !$self->param('force') ) {
            $plan->add( bucket => 'in-use', action => 'hold', key => $ch->{key}, id => $id,
                reason => "list $id ('$name') is named by $who; delete or re-point those mailings first, or force=1 deletes the list and the mailing loses it" );
            next;
        }
        my @effects = (
            { effect => scalar(@subs) . ' subscription row(s) go with the list; the contacts stay', suppressed => 0, evidence => 'mailing.contact.subscription.list_id is ondelete cascade; source 16.0 mailing_contact.py' },
            ( map { { effect => "mailing $_->{id} loses the list (its subject and traces stay)", suppressed => 0, evidence => 'mail_mass_mailing_list_rel cascades; live 2026-10-15' } } @ms ),
        );
        my %recreate = (
            $f->( list => 'name' ) => $name,
            $f->( list => 'active' ) => $l->{ $f->( list => 'active' ) } ? JSON::PP::true : JSON::PP::false,
            ( @subs ? ( $f->( list => 'subscriptions' ) => [ map { [ 0, 0, {
                $f->( subscription => 'contact' ) => Odoo::Ops::Mailing::Common::id_of( $_->{ $f->( subscription => 'contact' ) } ),
                $f->( subscription => 'opt_out' ) => $_->{ $f->( subscription => 'opt_out' ) } ? JSON::PP::true : JSON::PP::false } ] } @subs ] ) : () ),
        );
        $plan->add(
            bucket => 'delete', action => 'custom', handler => $self->op_name, kind => 'delete-list',
            model => $p->model_name('list'), id => $id, key => $ch->{key},
            before => { $f->( list => 'name' ) => $name, $f->( list => 'subscriptions' ) => [ map { $_->{id} } @subs ] },
            vals   => { recreate => \%recreate },
            effects => \@effects,
            reason => "list $id ('$name') is deleted; its " . scalar(@subs) . ' subscription(s) go with it and the contacts stay'
                . ( @ms ? "; force=1: $who will lose the list" : '' ),
        );
    }
    return $plan;
}

my %KIND = ( delete => 'mailing', 'delete-contact' => 'contact', 'delete-list' => 'list' );

sub apply_custom ($class, $client, $c) {
    my $kind = $c->{kind} // '';
    Odoo::Error->throw( kind => 'usage', message => "mailing.delete cannot apply kind '$kind'" ) if !$KIND{$kind};
    my $mm = $client->model( $c->{model} );
    $mm->unlink( $c->{id} );
    # read back absence, archived records included: a delete that left the record is not verified.
    # A contact has no active field, so only a mailing or a list is asked with one.
    my $left = $mm->count( [ [ 'id', '=', $c->{id} ], ( $kind eq 'delete-contact' ? () : ( [ 'active', 'in', [ JSON::PP::true, JSON::PP::false ] ] ) ) ] );
    return { id => $c->{id}, returned => { deleted => $c->{id} }, after => $left ? undef : { deleted => JSON::PP::true } };
}

sub undo_custom ($class, $entry) {
    my $kind = $entry->{kind} // '';
    return ( undef, "mailing.delete cannot undo kind '$kind'" ) if !$KIND{$kind};
    my %what = ( delete => 'a draft', 'delete-contact' => 'a contact with its memberships', 'delete-list' => 'a list with its subscriptions' );
    return {
        action => 'create', model => $entry->{model}, bucket => 'undo-delete', vals => { %{ $entry->{vals}{recreate} } },
        reason => "$KIND{$kind} $entry->{id} is recreated as $what{$kind}; the new record has a new id",
    };
}

1;
