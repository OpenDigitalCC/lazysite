package Odoo::Ops::Mailing::Subscribe;

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

Odoo::Ops::Mailing::Subscribe - put contacts on a mailing list, opt them out, or take them off

=head1 SYNOPSIS

    oom-ops run mailing.subscribe --conf ops.conf --set list=Newsletter \
        --set rows=docs/examples/mailing/contacts.csv
    oom-ops run mailing.subscribe --conf ops.conf --set list=Newsletter \
        --set rows=gone.csv --set mode=unsubscribe
    oom-ops run mailing.subscribe --conf ops.conf --set list=Newsletter \
        --set email=ann@example.com,bob@example.com --set mode=unsubscribe

=head1 DESCRIPTION

C<mailing.subscribe> takes rows with C<name>, C<email>, C<company>
(optional) and C<tags> (optional, names, a list or text split on C<;>
or C<,>) from C<rows> (a C<.csv>, C<.json> or C<.jsonl> file), C<records>
(a list) or C<mapping> (a Source mapping whose target is C<contact>),
and brings the list C<list> (a name or an id) to match, in C<mode>:

    subscribe     (default) the contact is on the list and subscribed
    unsubscribe   opt out: the subscription stays, flagged opted out
    remove        the subscription row goes; the contact stays

C<email> (one address, or several comma-separated) is the fourth way in,
for a person or an agent with a handful of addresses and no file: each
becomes a row with C<email> and no name. In C<subscribe> mode a contact
made from an address alone is named from the local part of the address
(C<ann.smith@example.com> is named C<ann.smith>; the plan says so), and
an existing contact keeps its name; C<unsubscribe> and C<remove> only
need the address to match. C<names> beside C<email> is a comma-separated
list in the same order, one name per address (the counts must match, else
usage; an empty entry leaves that address named from its local part).
C<email> together with C<rows>, C<records> or
C<mapping> is refused by name.

A contact is found by its normalised address (trimmed, lower-cased)
against Odoo's C<email_normalized>, never by name. A missing list is
made in the same plan when C<create_list> is on (the default) and the
mode is C<subscribe>; the list is a support change, outside the input rows.

Every row lands in exactly one bucket (C<list-create> and C<tag-create> are support changes of the plan, outside the rows):

    list-create          the list does not exist yet
    contact-create       no contact has the address; made, subscribed (unique_by email)
    subscribe            the contact exists, was not on the list
    resubscribe          the contact was opted out of this list
    contact-update       already subscribed, but name, company or tags differ (name and
                         company are overwritten by the file, tags only added)
    already-subscribed   nothing to do
    unsubscribe          opted out (mode unsubscribe)
    already-unsubscribed nothing to do
    remove               the subscription row goes (mode remove)
    not-subscribed       nothing to do: no such contact or not on the list
    blacklisted          held: subscribe mode, the address is on the blacklist and Odoo
                         will never mail it; run mailing.blacklist mode=remove first if
                         that is wanted
    invalid-email        held: the text is not an address
    duplicate-in-input   held: an earlier row carries the same address
    ambiguous            held: more than one contact has the address and the file cannot
                         say which; merge them in Odoo
    tag-not-allowed      held: the row names a tag that does not exist and Odoo says this
                         user may not create partner tags (check_access_rights); the
                         rows whose tags all exist are planned as usual
    held-*, invalid-row  held by the source or the caller / a row the source could not map

A row that needs a subscription change and also differs in name, company
or tags lands in its subscription bucket, with the contact update as a
support change of the same row (outside the bucket count, named in the
plan). Tags are C<res.partner.category> by name, created when absent as
support changes. A second run of the same file plans
C<already-subscribed> throughout.

Contact creates and updates carry the quiet context (no chatter, no
tracking). A revert undoes creates (the contact, the list, a tag) and
writes; a C<remove> is an unlink and is held as irreversible.

Series: Odoo 16 and 18; another series is refused by name until its
profile is probed.

=cut

sub op_name ($class) { 'mailing.subscribe' }
sub summary ($class) { 'Plan putting contacts on a mailing list (subscribe, unsubscribe or remove), from a file or records' }
sub pack    ($class) { 'mailing' }
# What a plan of this operation sorts rows into (oom-ops describe prints them;
# t/99-declared-buckets.t checks them against what the tests plan).
sub buckets ($class) {
    return [
        { name => 'list-create', meaning => 'the list does not exist yet; it is made (a support row)' },
        { name => 'contact-create', meaning => 'no contact has the address; one is made and subscribed' },
        { name => 'subscribe', meaning => 'the contact exists and was not on the list; it is subscribed' },
        { name => 'resubscribe', meaning => 'the contact had opted out of this list; it is subscribed again' },
        { name => 'contact-update', meaning => 'already subscribed, but name, company or tags differ; the contact is updated' },
        { name => 'unsubscribe', meaning => 'the contact is opted out (mode unsubscribe)' },
        { name => 'remove', meaning => 'the subscription row goes and the contact stays (mode remove)' },
        { name => 'tag-create', meaning => 'a tag named by rows is made first (a support row)' },
        { name => 'already-subscribed', meaning => 'nothing to do: the contact is subscribed' },
        { name => 'already-unsubscribed', meaning => 'nothing to do: the contact is already opted out' },
        { name => 'not-subscribed', meaning => 'nothing to do: no such contact, or not on the list' },
    ];
}
sub holds ($class) {
    return [
        { name => 'blacklisted', meaning => 'subscribe: the address is on the blacklist and Odoo will never mail it (mailing.blacklist mode=remove first, if wanted)' },
        { name => 'invalid-email', meaning => 'the text is not an address' },
        { name => 'invalid-row', meaning => 'the source could not map the row, or it has no values' },
        { name => 'duplicate-in-input', meaning => 'an earlier row carries the same address' },
        { name => 'ambiguous', meaning => 'more than one contact has the address and the file cannot say which; merge them in Odoo' },
        { name => 'tag-not-allowed', meaning => 'subscribe: the row names a tag that does not exist and this user may not create partner tags (Odoo\'s access check says no); make the tag with a config that may, or leave the tags column empty' },
        { name => 'held-<kind>', meaning => 'the source or the caller held the row, with the reason' },
    ];
}

sub params ($class) {
    {   list        => { type => 'str',  required => 1, help => 'the list, by name or id' },
        email       => { type => 'list', help => 'one address or a comma-separated list, instead of rows, records or mapping' },
        names       => { type => 'list', help => 'with email: one name per address, same order, comma-separated; without it a contact made from an address is named from its local part (ann.smith@x.com is ann.smith)' },
        Odoo::Ops::Mailing::Common::rows_params(),
        mode        => { type => 'str',  default => 'subscribe', help => 'subscribe (default), unsubscribe or remove' },
        create_list => { type => 'bool', default => 1, help => 'make the list when no list has the name (subscribe mode)' },
    };
}
sub read_scope ($class) {
    {   list         => ['search_read'],
        contact      => ['search_read'],
        subscription => ['search_read'],
        blacklist    => ['search_read'],
        tag          => [qw(search_read check_access_rights)],
    };
}
sub write_scope ($class) {
    {   list         => [qw(create read)],
        contact      => [qw(create write read)],
        subscription => [qw(create write unlink read)],
        tag          => [qw(create read)],
    };
}

sub scope_for ($self, $phase) { Odoo::Ops::Mailing::Common::scope( $self, $phase, $self->SUPER::scope_for($phase) ) }

my %MODE = map { $_ => 1 } qw(subscribe unsubscribe remove);
my $QUIET = sub () { { tracking_disable => JSON::PP::true, mail_create_nolog => JSON::PP::true, mail_notrack => JSON::PP::true, mail_create_nosubscribe => JSON::PP::true } };

sub plan ($self) {
    my $p    = Odoo::Ops::Mailing::Common::ready($self);
    my $mode = $self->param('mode');
    Odoo::Error->throw( kind => 'usage', message => "mailing.subscribe: mode must be subscribe, unsubscribe or remove, not '$mode'" ) if !$MODE{$mode};
    my $f = sub ( $lm, $lf ) { $p->field( $lm => $lf ) };
    my $rows = Odoo::Ops::Mailing::Common::rows( $self, email => 1, names => 1 );

    # the list: found, or made in this plan
    my $ref   = $self->param('list');
    my $lists = Odoo::Ops::Mailing::Common::lists_by( $self, $ref, archived => 1 );
    Odoo::Error->throw( kind => 'usage', message => "mailing.subscribe: '$ref' names " . scalar(@$lists) . ' lists (ids ' . join( ', ', map { $_->{id} } @$lists ) . '); give the id' )
        if @$lists > 1;
    my $list = $lists->[0];
    Odoo::Error->throw( kind => 'refused', code => 'archived', message => "mailing.subscribe: list '$ref' is archived; unarchive it in Odoo first", fix => 'unarchive the list in Odoo, or name another' )
        if $list && !$list->{ $f->( list => 'active' ) };
    my $make = 0;
    if ( !$list ) {
        Odoo::Error->throw( kind => 'refused', code => 'unknown-list', message => "mailing.subscribe: no list '$ref'", fix => 'oom-ops run mailing.lists --conf <conf> lists the mailing lists; create_list=1 makes one by name' )
            if $ref =~ /^\d+\z/ || $mode ne 'subscribe' || !$self->param('create_list');
        $make = 1;
    }
    my $lid = $make ? { '$ref' => 'list' } : $list->{id};

    # who is already there, by normalised address
    my %addr;
    for my $r (@$rows) {
        next if ref $r->{values} ne 'HASH';
        my $e = Odoo::Ops::Mailing::Common::email( $r->{values}{email} );
        $addr{$e} = 1 if defined $e;
    }
    my ( %contacts, %subs, %black, %tags );
    if (%addr) {
        my $cs = $self->model('contact')->all( [ [ $f->( contact => 'email_normalized' ), 'in', [ sort keys %addr ] ] ],
            [ map { $f->( contact => $_ ) } qw(name email_normalized company tags) ] );
        push @{ $contacts{ $_->{ $f->( contact => 'email_normalized' ) } } }, $_ for @$cs;
        if ( !$make && @$cs ) {
            my $ss = $self->model('subscription')->all( [ [ $f->( subscription => 'list' ), '=', $list->{id} ],
                [ $f->( subscription => 'contact' ), 'in', [ map { $_->{id} } @$cs ] ] ],
                [ map { $f->( subscription => $_ ) } qw(contact opt_out) ] );
            $subs{ Odoo::Ops::Mailing::Common::id_of( $_->{ $f->( subscription => 'contact' ) } ) } = $_ for @$ss;
        }
        my $bl = $self->model('blacklist')->all( [ [ $f->( blacklist => 'email' ), 'in', [ sort keys %addr ] ], [ $f->( blacklist => 'active' ), '=', JSON::PP::true ] ],
            [ $f->( blacklist => 'email' ) ] );
        $black{ lc $_->{ $f->( blacklist => 'email' ) } } = 1 for @$bl;
    }
    my $tm = $self->model('tag');
    $tags{ lc $_->{ $f->( tag => 'name' ) } } //= $_->{id} for @{ $tm->all( [], [ $f->( tag => 'name' ) ] ) };

    # whether this user may make a tag, asked of Odoo once and only when a row names a tag that does not exist
    my $may_tag;
    my $tag_ok = sub {
        $may_tag //= do {
            my $ok = eval { $tm->call( 'check_access_rights', [], operation => 'create', raise_exception => JSON::PP::false ) };
            # a server that cannot be asked is not taken for a refusal: the apply then says what Odoo says
            $@ ? 1 : ( $ok ? 1 : 0 );
        };
    };
    my ( @decisions, %seen, %need_tag, %named_from_address );
    my $i = 0;
    for my $row (@$rows) {
        $i++;
        push @decisions, $self->_decide( $p, $mode, $row, $i, $lid, $make, \%contacts, \%subs, \%black, \%tags, \%seen, \%need_tag, \%named_from_address, $tag_ok );
    }

    my $plan = $self->new_plan( input_count => scalar(@$rows) );
    $plan->note( 'list ' . ( $make ? "'$ref' will be created" : "'$list->{ $f->( list => 'name' ) }' (id $list->{id})" ) . "; mode $mode; " . scalar(@$rows) . ' rows' );
    if ( my @n = sort keys %named_from_address ) {
        $plan->note( 'named from the address (no name was given): ' . join( ', ', map { "$_ as '$named_from_address{$_}'" } @n ) );
    }
    if ($make) {
        $plan->add( bucket => 'list-create', action => 'create', model => $p->model_name('list'), ref => 'list', support => 1, key => "list:$ref",
            vals => { $f->( list => 'name' ) => $ref }, unique_by => $f->( list => 'name' ) );
    }
    if ( my @new = sort keys %need_tag ) {
        $plan->note( 'tags created: ' . join( ', ', map { $need_tag{$_} } @new ) );
        for my $t (@new) {
            $plan->add( bucket => 'tag-create', action => 'create', model => $p->model_name('tag'), ref => "tag:$t", support => 1,
                key => "tag:$t", vals => { $f->( tag => 'name' ) => $need_tag{$t} }, unique_by => $f->( tag => 'name' ) );
        }
    }
    for my $d (@decisions) {
        for my $c ( @{ $d->{support} // [] } ) { $plan->add( %$c, support => 1 ) }
        $plan->add( %{ $d->{main} } );
    }
    return $plan;
}

sub _decide ($self, $p, $mode, $row, $n, $lid, $make, $contacts, $subs, $black, $tags, $seen, $need_tag, $named_from_address, $tag_ok) {
    my $f   = sub ( $lm, $lf ) { $p->field( $lm => $lf ) };
    my $key = "row:$row->{key}";
    my $hold = sub ($bucket, $reason) { +{ main => { bucket => $bucket, action => 'hold', key => $key, reason => $reason } } };
    my $skip = sub ($bucket, $reason, %x) { +{ main => { bucket => $bucket, action => 'skip', key => $key, reason => $reason, %x } } };
    return $hold->( 'invalid-row', $row->{error} ) if defined $row->{error};
    if ( my $h = $row->{held} ) {
        my ($kind) = $h =~ /^(\w+):/;
        return $hold->( 'held-' . ( $kind // 'flag' ), $h );
    }
    my $v = $row->{values};
    return $hold->( 'invalid-row', 'the row has no values' ) if ref $v ne 'HASH';
    my $raw = $v->{email};
    my $e   = Odoo::Ops::Mailing::Common::email($raw);
    return $hold->( 'invalid-email', "'" . ( $raw // '' ) . "' is not an email address" ) if !defined $e;
    return $hold->( 'duplicate-in-input', "same address as row #$seen->{$e}" ) if $seen->{$e};
    $seen->{$e} = $n;

    my $name    = Odoo::Ops::Mailing::Common::text( $v->{name} ) =~ s/^\s+|\s+\z//gr;
    my $company = Odoo::Ops::Mailing::Common::text( $v->{company} ) =~ s/^\s+|\s+\z//gr;
    my @tagnames = grep { length } map { s/^\s+|\s+\z//gr } map { split /\s*[;,]\s*/ } ref $v->{tags} eq 'ARRAY' ? @{ $v->{tags} } : ( $v->{tags} // () );

    my @cs = @{ $contacts->{$e} // [] };
    my $c;
    if ( @cs > 1 ) {
        # the one already on the list is the one meant; none or several on it cannot be told apart,
        # except that without a subscription there is nothing to unsubscribe or remove
        my @on = grep { $subs->{ $_->{id} } } @cs;
        return $hold->( 'ambiguous', 'contacts ' . join( ', ', map { $_->{id} } @cs ) . " all have the address $e; merge them in Odoo" )
            if @on > 1 || ( !@on && $mode eq 'subscribe' );
        $c = @on ? $on[0] : $cs[0];
    }
    else { $c = $cs[0] }
    my $sub = $c ? $subs->{ $c->{id} } : undef;
    my $opted_out = $sub && $sub->{ $f->( subscription => 'opt_out' ) };

    if ( $mode eq 'unsubscribe' ) {
        return $skip->( 'not-subscribed', $c ? "contact $c->{id} is not on the list" : "no contact has the address $e" ) if !$sub;
        return $skip->( 'already-unsubscribed', "contact $c->{id} is already opted out", id => $sub->{id} ) if $opted_out;
        return +{ main => {
            bucket => 'unsubscribe', action => 'write', model => $p->model_name('subscription'), id => $sub->{id}, key => $key,
            vals => { $f->( subscription => 'opt_out' ) => JSON::PP::true }, before => { $f->( subscription => 'opt_out' ) => 0 },
            reason => "contact $c->{id} ($e) opts out of the list",
        } };
    }
    if ( $mode eq 'remove' ) {
        return $skip->( 'not-subscribed', $c ? "contact $c->{id} is not on the list" : "no contact has the address $e" ) if !$sub;
        return +{ main => {
            bucket => 'remove', action => 'unlink', model => $p->model_name('subscription'), id => $sub->{id}, key => $key,
            before => { $f->( subscription => 'opt_out' ) => $opted_out ? 1 : 0 },
            reason => "contact $c->{id} ($e) comes off the list; the contact stays",
        } };
    }

    # subscribe
    return $hold->( 'blacklisted', "$e is on the blacklist: Odoo never mails it, so subscribing it would only look done; run mailing.blacklist mode=remove first if that is wanted" )
        if $black->{$e};

    # tags by name; unknown names become support creates, unless this user may not make a tag: then the row is held
    my @missing = grep { !$tags->{ lc $_ } } @tagnames;
    return $hold->( 'tag-not-allowed', "$e names " . ( @missing == 1 ? "the tag '$missing[0]'" : 'the tags ' . join( ', ', map { "'$_'" } @missing ) ) . ', which does not exist: '
        . "this user may not create partner tags (Odoo's access check says no): make the tag with a config that may, or leave the tags column empty" )
        if @missing && !$tag_ok->();
    my @tag_ids;
    for my $t (@tagnames) {
        my $k = lc $t;
        if ( $tags->{$k} ) { push @tag_ids, $tags->{$k} }
        else { $need_tag->{$k} //= $t; push @tag_ids, { '$ref' => "tag:$k" } }
    }

    if ( !$c ) {
        # an address on its own carries no name; Odoo's list import shows the local part for want of one
        if ( !length $name && $row->{from_email} ) { ( $name = $e ) =~ s/\@.*//s; $named_from_address->{$e} = $name }
        my %vals = (
            $f->( contact => 'email' ) => $raw =~ s/^\s+|\s+\z//gr,
            ( length $name    ? ( $f->( contact => 'name' )    => $name )    : () ),
            ( length $company ? ( $f->( contact => 'company' ) => $company ) : () ),
            ( @tag_ids        ? ( $f->( contact => 'tags' )    => [ [ 6, 0, \@tag_ids ] ] ) : () ),
            $f->( contact => 'subscriptions' ) => [ [ 0, 0, { $f->( subscription => 'list' ) => $lid } ] ],
        );
        return +{ main => {
            bucket => 'contact-create', action => 'create', model => $p->model_name('contact'), key => $key, vals => \%vals,
            unique_by => { field => $f->( contact => 'email' ), fold => 1 }, context => $QUIET->(),
            reason => "no contact has the address $e",
        } };
    }

    # an existing contact: what differs, and what the list needs
    my ( %set, %before );
    if ( length $name && $name ne Odoo::Ops::Mailing::Common::text( $c->{ $f->( contact => 'name' ) } ) ) {
        $set{ $f->( contact => 'name' ) } = $name;
        $before{ $f->( contact => 'name' ) } = $c->{ $f->( contact => 'name' ) };
    }
    if ( length $company && $company ne Odoo::Ops::Mailing::Common::text( $c->{ $f->( contact => 'company' ) } ) ) {
        $set{ $f->( contact => 'company' ) } = $company;
        $before{ $f->( contact => 'company' ) } = $c->{ $f->( contact => 'company' ) };
    }
    my %have = map { $_ => 1 } @{ $c->{ $f->( contact => 'tags' ) } // [] };
    my @add = grep { ref $_ || !$have{$_} } @tag_ids;
    if (@add) {
        $set{ $f->( contact => 'tags' ) } = [ map { [ 4, $_, 0 ] } @add ];
        $before{ $f->( contact => 'tags' ) } = $c->{ $f->( contact => 'tags' ) };
    }
    my %update = %set ? (
        bucket => 'contact-update', action => 'write', model => $p->model_name('contact'), id => $c->{id}, key => "$key:contact",
        vals => \%set, before => \%before, context => $QUIET->(),
        reason => "contact $c->{id}: " . join( ', ', map { s/_ids\z/s/r } sort keys %set ) . ' differ from the file',
    ) : ();

    if ( $sub && !$opted_out ) {
        return +{ main => { %update, key => $key } } if %update;
        return $skip->( 'already-subscribed', "contact $c->{id} is on the list", id => $sub->{id} );
    }
    my $main;
    if ($sub) {
        $main = {
            bucket => 'resubscribe', action => 'write', model => $p->model_name('subscription'), id => $sub->{id}, key => $key,
            vals => { $f->( subscription => 'opt_out' ) => JSON::PP::false }, before => { $f->( subscription => 'opt_out' ) => 1 },
            reason => "contact $c->{id} ($e) was opted out of the list",
        };
    }
    else {
        $main = {
            bucket => 'subscribe', action => 'create', model => $p->model_name('subscription'), key => $key,
            vals => { $f->( subscription => 'contact' ) => $c->{id}, $f->( subscription => 'list' ) => $lid },
            reason => "contact $c->{id} ($e) is not on the list",
        };
    }
    return +{ main => $main, ( %update ? ( support => [ \%update ] ) : () ) };
}

1;
