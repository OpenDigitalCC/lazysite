package Odoo::Ops::Mailing::Create;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Encode ();
use JSON::PP ();

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Mailing::Common;
use Odoo::Ops::Mailing::Plaintext;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Mailing::Create - make a mailshot as a draft, or change a draft

=head1 SYNOPSIS

    oom-ops run mailing.create --conf ops.conf --set subject="October news" \
        --set lists=Newsletter --set body_file=docs/examples/mailing/newsletter.html
    oom-ops run mailing.create --conf ops.conf --set mailing=7 --set subject="October news, corrected"

=head1 DESCRIPTION

C<mailing.create> plans one draft C<mailing.mailing> to the lists in
C<lists> (names or ids, comma-separated; at least one) with the body
from C<body_file> (a path to HTML) or C<body> (a string) - exactly one
of the two. Nothing is sent: a draft is sent by C<mailing.send>, after
C<mailing.test>.

Optional: C<from> (C<email_from>; absent leaves Odoo's default, which
is the creating user's formatted email, so that user must have one),
C<reply_to>, and C<schedule> (a UTC datetime, C<YYYY-MM-DD HH:MM:SS>,
which makes the mailing a scheduled one; it still waits for
C<mailing.send>). The body is kept both as Odoo sends it (C<body_html>)
and as its editor keeps it (C<body_arch>).

C<country_in> or C<country_not_in> (one of the two, a list of ISO country
codes) sends the mailing to part of its lists: the contacts whose own
country (C<mailing.contact.country_id>; a linked partner is not consulted,
a list contact need not have one) is one of the codes, or, for
C<country_not_in>, is none of them and every contact with no country. It is
written as the mailing's C<mailing_domain>: Odoo's default for the lists
(C<[('list_ids', 'in', [ids])]>, no blacklist term) and the clause on
C<country_id>. A code C<res.country> does not hold is refused C<usage>,
naming it. The plan states the filter in words, the domain, and the number
of C<mailing.contact> records Odoo's own domain gives at plan time (what
the mailing's C<total> will read), and counts the audience for that part
alone. Odoo recomputes the domain whenever the lists are written, so a
filter is part of the same write as the lists or is asked for again; a plan
that changes the lists of a filtered draft without asking for a filter says
that it is lost. After apply the domain is read back: a domain Odoo stored
other than written is listed under the result's C<custom> as C<read-back
differs>, and the change counts as not verified. Drafts that share a
subject and lists but differ in the filter are different drafts (the parts
of one message): C<exists> and C<sent before> compare the domain too.

C<slice> (C<< { from_id, before_id } >>, either may be left out, not both)
sends the mailing to one slice of its lists, or of the part a country filter
gives: the contacts with C<id E<gt>= from_id> and C<id E<lt> before_id>, for a
part too big for one mailing (C<mailing.partition> C<slices> gives the cut
points, and the first slice has no C<from_id>, the last no C<before_id>).
Odoo's domains have no modulo, so a slice is a contact id range. The domain
written is Odoo's default for the lists, the country clause when there is
one, and the id clause; the plan states the range in words and the number of
C<mailing.contact> records Odoo's own domain gives at plan time, as for a
country filter, and the domain is read back after apply in the same way.
Drafts of one subject and lists that differ in the range are different drafts
(each slice has its own schedule), so none is C<exists> or C<sent before>
because of another. A C<from_id> that is not below C<before_id> is refused
C<usage>; so is a C<slice> that holds neither bound or anything else, and a
mailing that is not to lists (C<mailing=ID>) is refused C<not-a-list-mailing>,
as for a country filter. Changing the lists of a draft that has a slice, as
of one that has a filter, makes Odoo recompute its domain: the slice is
written again with the lists.

One row, one bucket:

    mailing-create    the draft is made; the plan note counts who would receive it now
    mailing-update    C<mailing=ID>: that draft changes, with before-images
    unchanged         C<mailing=ID>: nothing differs
    unknown-list      held: a list does not exist (named)
    exists            held: a draft with this subject and these lists is there already
                      (its id is in the reason; pass mailing=ID to change it instead)
    no-unsubscribe-link  held: the body has no anchor whose href is /unsubscribe_from_list,
                      the path Odoo rewrites to the recipient's own link at send time;
                      allow_no_unsubscribe=1 lets it through and the plan says so

When the body's unsubscribe anchor will stay a placeholder in the plain-text part, the plan carries one note saying so: Odoo makes the text
part before it swaps the recipient's own link into the HTML part, so the text
part's C</unsubscribe_from_list> link will answer 404, while the HTML part and the
C<List-Unsubscribe> header work (L<Odoo::Ops::Mailing::Plaintext>). It is a note
and not a hold, because nothing the author can do in the body changes it.

A mailing that is not a draft refuses by name (C<not-draft>). The read
back after apply includes C<total>, Odoo's count of the lists' contacts
in the lists; it counts opted-out and blacklisted ones, so the number
that will receive it is the plan's note (distinct addresses,
subscribed to some list, not blacklisted). Odoo's
C<expected> is 0 until a send makes traces.

Series: Odoo 16 and 18; another series is refused by name until its
profile is probed.

=cut

sub op_name ($class) { 'mailing.create' }
sub summary ($class) { 'Plan a mailshot as a draft to mailing lists, or change a draft (nothing is sent)' }
sub pack    ($class) { 'mailing' }
# What a plan of this operation sorts rows into (oom-ops describe prints them;
# t/99-declared-buckets.t checks them against what the tests plan).
sub buckets ($class) {
    return [
        { name => 'mailing-create', meaning => 'a draft mailing is made; the plan note counts who would receive it now' },
        { name => 'mailing-update', meaning => 'mailing=ID: that draft is changed, with before-images' },
        { name => 'unchanged', meaning => 'mailing=ID: nothing differs' },
    ];
}
sub holds ($class) {
    return [
        { name => 'unknown-list', meaning => 'a list does not exist' },
        { name => 'exists', meaning => 'a draft with this subject and these lists is there already; pass mailing=ID to change it' },
        { name => 'no-unsubscribe-link', meaning => 'the body has no anchor to /unsubscribe_from_list, the path Odoo rewrites for each recipient (allow_no_unsubscribe=1 lets it through)' },
    ];
}

sub params ($class) {
    {   subject  => { type => 'str',  help => 'the subject (required to create)' },
        lists    => { type => 'list', help => 'the lists, names or ids, comma-separated' },
        body_file => { type => 'path', help => 'a file of HTML, with an /unsubscribe_from_list anchor' },
        body     => { type => 'str',  help => 'the HTML as a string (instead of body_file)' },
        from     => { type => 'str',  help => 'email_from; absent leaves Odoo\'s default' },
        reply_to => { type => 'str',  help => 'reply-to address' },
        schedule => { type => 'str',  help => 'UTC datetime to send, YYYY-MM-DD HH:MM:SS' },
        mailing  => { type => 'int',  help => 'change this draft instead of making one' },
        country_in     => { type => 'list', help => 'send only to the lists\' contacts whose own country is one of these ISO codes (AU,JP)' },
        country_not_in => { type => 'list', help => 'send only to the lists\' contacts whose own country is none of these ISO codes, and to those with no country' },
        slice    => { type => 'json', help => 'send only to the contacts of this id range: {"from_id":N,"before_id":M} (id >= from_id and id < before_id; either may be left out, not both)' },
        allow_no_unsubscribe => { type => 'bool', default => 0, help => 'allow a body with no unsubscribe link' },
    };
}
sub read_scope ($class) {
    {   mailing      => [qw(search_read read)],
        list         => ['search_read'],
        subscription => ['search_read'],
        contact      => [qw(search_read search_count)],
        country      => ['search_read'],
        'ir.model'   => ['search_read'],
    };
}
sub write_scope ($class) { { mailing => [qw(create write read)] } }

sub scope_for ($self, $phase) { Odoo::Ops::Mailing::Common::scope( $self, $phase, $self->SUPER::scope_for($phase) ) }

sub plan ($self) {
    my $p = Odoo::Ops::Mailing::Common::ready($self);
    my $f = sub ($lf) { $p->field( mailing => $lf ) };
    my $upd = $self->param('mailing');

    my $body = $self->_body;
    my $plan = $self->new_plan( input_count => 1 );
    my $key  = defined $upd ? "mailing:$upd" : 'mailing:' . ( $self->param('subject') // '' );
    my $hold = sub ($bucket, $reason) { $plan->add( bucket => $bucket, action => 'hold', key => $key, reason => $reason ); return $plan };

    if ( !defined $upd ) {
        Odoo::Error->throw( kind => 'usage', message => 'mailing.create: parameter subject is required' )
            if !defined $self->param('subject') || $self->param('subject') !~ /\S/;
        Odoo::Error->throw( kind => 'usage', message => 'mailing.create: give a body (body_file or body)' ) if !defined $body;
        Odoo::Error->throw( kind => 'usage', message => 'mailing.create: give at least one list (lists)' ) if !@{ $self->param('lists') // [] };
    }
    my ( $cin, $cnot ) = map { $self->param($_) } qw(country_in country_not_in);
    Odoo::Error->throw( kind => 'usage', message => 'mailing.create: give country_in or country_not_in, not both',
        fix => 'country_in sends to those countries; country_not_in to every other country and to contacts with no country' )
        if defined $cin && defined $cnot;
    my $cmode = defined $cin ? 'in' : defined $cnot ? 'not_in' : undef;
    my ( $sfrom, $sbefore ) = $self->_slice;
    my $slice = defined $sfrom || defined $sbefore ? 1 : 0;
    my $countries = $cmode ? Odoo::Ops::Mailing::Common::countries( $self, $cmode eq 'in' ? $cin : $cnot ) : undef;
    my $current;
    if ( defined $upd ) {
        $current = $self->model('mailing')->read( [$upd], [ map { $f->($_) } qw(subject state lists body_html body_arch email_from reply_to schedule_date schedule_type model_real domain) ] )->[0]
            or Odoo::Error->throw( kind => 'refused', code => 'unknown-mailing', message => "mailing.create: no mailing $upd",
            fix => q(oom-ops run mailing.status --conf <conf> lists the mailings) );
        Odoo::Error->throw( kind => 'refused', code => 'not-draft',
            message => "mailing $upd is $current->{ $f->('state') }, not draft: only a draft can be changed" )
            if $current->{ $f->('state') } ne 'draft';
        Odoo::Error->throw( kind => 'refused', code => 'not-a-list-mailing',
            message => "mailing $upd is to " . Odoo::Ops::Mailing::Common::text( $current->{ $f->('model_real') } ) . ', not to mailing lists: a country filter or a slice is on the contacts of lists' )
            if ( $cmode || $slice ) && Odoo::Ops::Mailing::Common::text( $current->{ $f->('model_real') } ) ne $p->model_name('contact');
    }

    # lists: every name or id must exist (archived ones are not offered to a mailing)
    my ( @ids, @unknown );
    for my $ref ( @{ $self->param('lists') // [] } ) {
        my $found = Odoo::Ops::Mailing::Common::lists_by( $self, $ref );
        if    ( !@$found )    { push @unknown, $ref }
        elsif ( @$found > 1 ) { push @unknown, "$ref (names " . scalar(@$found) . ' lists; give the id)' }
        else                  { push @ids, $found->[0]{id} }
    }
    return $hold->( 'unknown-list', 'no list ' . join( ', ', map { "'$_'" } @unknown ) . ' (mailing.lists shows them)' ) if @unknown;

    my @problems;
    my $href = $p->action('unsubscribe_href');
    if ( defined $body && !Odoo::Ops::Mailing::Common::has_unsubscribe( $body, $href ) ) {
        if ( $self->param('allow_no_unsubscribe') ) {
            $plan->note("the body has no unsubscribe link ($href); allowed by allow_no_unsubscribe: recipients will have no way to opt out");
        }
        else {
            push @problems, [ 'no-unsubscribe-link',
                "the body has no anchor whose href is $href, so recipients would have no way to opt out; add one (docs/examples/mailing/newsletter.html), or allow_no_unsubscribe=1" ];
        }
    }
    # what the mailing's domain will read: the filter on the lists, or Odoo's default for them
    my @dom_lists = @ids ? @ids : ( $current ? @{ $current->{ $f->('lists') } // [] } : () );
    my $domtext = $cmode && @dom_lists ? Odoo::Ops::Mailing::Common::country_domain( $self, \@dom_lists, $cmode, [ map { $_->{id} } @$countries ] )
        : $slice && @dom_lists ? Odoo::Ops::Mailing::Common::list_domain( $self, \@dom_lists ) : undef;
    $domtext = Odoo::Ops::Mailing::Common::slice_domain( $domtext, $sfrom, $sbefore ) if $slice && defined $domtext;
    my $want_domain = $domtext // ( @dom_lists ? Odoo::Ops::Mailing::Common::list_domain( $self, \@dom_lists ) : undef );
    if ( !defined $upd && @ids ) {
        my %want = map { $_ => 1 } @ids;
        my $drafts = $self->model('mailing')->all( [ [ $f->('state'), '=', 'draft' ], [ $f->('subject'), '=', $self->param('subject') ] ],
            [ $f->('subject'), $f->('lists'), $f->('domain') ] );
        for my $d (@$drafts) {
            my %have = map { $_ => 1 } @{ $d->{ $f->('lists') } // [] };
            next if keys %have != keys %want || grep { !$have{$_} } keys %want;
            # the parts of one message share subject and lists and differ in the filter: a draft is the same one only with the same domain
            next if !Odoo::Ops::Mailing::Common::same_domain( Odoo::Ops::Mailing::Common::text( $d->{ $f->('domain') } ) || $want_domain, $want_domain );
            unshift @problems, [ 'exists', "a draft with this subject and these lists exists: mailing $d->{id}; pass mailing=$d->{id} to change it" ];
            last;
        }
    }
    if (@problems) {
        return $hold->( $problems[0][0], join( '; ', map { $_->[1] } @problems ) );
    }

    # A repeat after a send makes a new draft under the same subject; the reviewer
    # sees the earlier mailing before approving, not after (second try-out, item 3).
    my @sent_before = !defined $upd && @ids ? $self->_sent_before( \@ids, $want_domain ) : ();

    # a region of the lists: the contacts Odoo's own domain gives, counted by Odoo now
    my $parsed   = $domtext ? Odoo::Ops::Mailing::Common::parse_domain($domtext) : undef;
    my $matching = $parsed ? $self->model('contact')->count($parsed) : undef;
    my $aud_ids  = @ids ? \@ids : $cmode || $slice ? \@dom_lists : undef;
    my $aud = $aud_ids && @$aud_ids ? Odoo::Ops::Mailing::Common::audience( $self, $aud_ids, ( $parsed ? ( domain => $parsed ) : () ) ) : undef;
    my $note = sub () {
        return () if !$aud;
        my @n = ( sprintf 'audience now%s: %d reachable address(es) of %d subscription(s); %d opted out, %d blacklisted, %d without an address',
            ( $parsed ? ' in the filtered part' : '' ), @$aud{qw(reachable subscriptions opted_out blacklisted no_email)} );
        unshift @n, join '; ', ( $cmode ? 'country filter: ' . Odoo::Ops::Mailing::Common::country_words( $cmode, $countries ) : () ),
            ( $slice ? 'slice: ' . Odoo::Ops::Mailing::Common::slice_words( $sfrom, $sbefore ) . ' of the ' . ( $cmode ? 'part' : 'lists' ) : () ),
            "mailing_domain $domtext", "Odoo's own domain gives $matching contact(s) now (opted-out ones included, as its total counts them)"
            if $parsed;
        return @n;
    };

    # Odoo makes the plain-text part before it swaps the recipient's links into the HTML: nothing the author can do in the body, so a note and not a hold.
    # The body is read as Odoo's html2plaintext reads it; its relative links are judged by their path, as Odoo makes them absolute with the base URL.
    my $text_part = sub () {
        my (undef, $urls) = eval { Odoo::Ops::Mailing::Plaintext::html2plaintext($body) };
        return () if !$urls;
        return grep { defined } Odoo::Ops::Mailing::Plaintext::warning( Odoo::Ops::Mailing::Plaintext::text_links( $urls, series => $self->client->server_series ) );
    };

    if ( defined $upd ) {
        my ( %set, %before );
        my $same = sub ($old, $new) { Odoo::Ops::Mailing::Common::text($old) eq $new };
        my $want = sub ($fld, $val) { if ( !$same->( $current->{$fld}, $val ) ) { $set{$fld} = $val; $before{$fld} = $current->{$fld} } };
        $want->( $f->('subject'), $self->param('subject') ) if defined $self->param('subject');
        if ( defined $body ) { $want->( $f->('body_html'), $body ); $want->( $f->('body_arch'), $body ) }
        $want->( $f->('email_from'), $self->param('from') ) if defined $self->param('from');
        $want->( $f->('reply_to'), $self->param('reply_to') ) if defined $self->param('reply_to');
        if ( defined $self->param('schedule') ) {
            my $when = Odoo::Ops::Mailing::Common::datetime( 'mailing.create', 'schedule', $self->param('schedule') );
            $want->( $f->('schedule_date'), $when );
            if ( ( $current->{ $f->('schedule_type') } // '' ) ne 'scheduled' ) { $set{ $f->('schedule_type') } = 'scheduled'; $before{ $f->('schedule_type') } = $current->{ $f->('schedule_type') } }
        }
        my $lists_change = 0;
        if (@ids) {
            my %have = map { $_ => 1 } @{ $current->{ $f->('lists') } // [] };
            if ( keys %have != @ids || grep { !$have{$_} } @ids ) {
                $set{ $f->('lists') } = [ [ 6, 0, \@ids ] ];
                $before{ $f->('lists') } = $current->{ $f->('lists') };
                $lists_change = 1;
            }
        }
        # Odoo recomputes the domain whenever the lists are written: a filter on this mailing is kept only when it is asked for again
        my $cur_dom = Odoo::Ops::Mailing::Common::text( $current->{ $f->('domain') } );
        my $filtered_now = length $cur_dom
            && !Odoo::Ops::Mailing::Common::same_domain( $cur_dom, Odoo::Ops::Mailing::Common::list_domain( $self, $current->{ $f->('lists') } // [] ) );
        if ($domtext) {
            if ( !Odoo::Ops::Mailing::Common::same_domain( $cur_dom, $domtext ) ) {
                $set{ $f->('domain') } = $domtext;
                $before{ $f->('domain') } = $current->{ $f->('domain') };
            }
        }
        elsif ( $lists_change && $filtered_now ) {
            $plan->note("changing the lists makes Odoo recompute the mailing's domain: the filter it has now ($cur_dom) is lost; pass country_in, country_not_in or slice again to keep it");
        }
        # a slice written without the country filter the draft has replaces it: say so rather than keep a clause nobody asked for
        $plan->note("the slice replaces the filter the mailing has now ($cur_dom): pass country_in or country_not_in with it to keep a country filter")
            if $slice && !$cmode && $filtered_now && $domtext && !Odoo::Ops::Mailing::Common::same_domain( $cur_dom, $domtext );
        if ( !%set ) {
            $plan->add( bucket => 'unchanged', action => 'skip', key => $key, id => $upd, reason => "mailing $upd already reads as asked" );
            return $plan;
        }
        $plan->note($_) for $note->();
        $plan->note($_) for $text_part->();
        $plan->add( bucket => 'mailing-update', action => 'write', model => $p->model_name('mailing'), id => $upd, key => $key,
            vals => \%set, before => \%before, ( $set{ $f->('domain') } ? ( compare => [ $f->('domain') ] ) : () ),
            reason => 'changes ' . join( ', ', sort keys %set ) );
        return $plan;
    }

    my $ir = $self->client->model('ir.model')->search_read( [ [ 'model', '=', $p->model_name('list') ] ], ['id'], limit => 1 )->[0]
        or Odoo::Error->throw( kind => 'config', message => 'ir.model has no ' . $p->model_name('list') . ': mass_mailing is not installed' );
    my %vals = (
        $f->('subject')   => $self->param('subject'),
        $f->('body_html') => $body,
        $f->('body_arch') => $body,
        $f->('model')     => $ir->{id},
        $f->('lists')     => [ [ 6, 0, \@ids ] ],
        # given with the lists, Odoo keeps it; it recomputes the domain from the lists only for a mailing it was given none
        ( $domtext ? ( $f->('domain') => $domtext ) : () ),
        ( defined $self->param('from')     ? ( $f->('email_from') => $self->param('from') )         : () ),
        ( defined $self->param('reply_to') ? ( $f->('reply_to')   => $self->param('reply_to') )     : () ),
    );
    if ( defined $self->param('schedule') ) {
        $vals{ $f->('schedule_type') } = 'scheduled';
        $vals{ $f->('schedule_date') } = Odoo::Ops::Mailing::Common::datetime( 'mailing.create', 'schedule', $self->param('schedule') );
    }
    $plan->note($_) for $note->();
    $plan->note($_) for $text_part->();
    $plan->note($_) for @sent_before;
    $plan->note('a draft: nothing is sent until mailing.send; test it first with mailing.test');
    $plan->add( bucket => 'mailing-create', action => 'create', model => $p->model_name('mailing'), key => $key, vals => \%vals,
        readback => [ map { $f->($_) } qw(subject state total email_from reply_to lists model domain) ],
        ( $domtext ? ( compare => [ $f->('domain') ] ) : () ),
        reason => 'a draft mailing to ' . scalar(@ids) . ' list(s)' );
    return $plan;
}

# Mailings in any state but draft that carry this subject and exactly these
# lists, newest first (archived ones too: a cleaned-up send is still a send).
sub _sent_before ($self, $ids, $want_domain) {
    my $f = sub ($lf) { $self->profile->field( mailing => $lf ) };
    my %want = map { $_ => 1 } @$ids;
    my $rows = $self->model('mailing')->search_read(
        [ [ $f->('state'), '!=', 'draft' ], [ $f->('subject'), '=', $self->param('subject') ],
          [ $f->('active'), 'in', [ JSON::PP::true, JSON::PP::false ] ] ],
        [ map { $f->($_) } qw(subject state lists sent_date updated domain) ], order => 'id desc', limit => 20 );
    my @note;
    for my $m (@$rows) {
        my %have = map { $_ => 1 } @{ $m->{ $f->('lists') } // [] };
        next if keys %have != keys %want || grep { !$have{$_} } keys %want;
        # another part of the same message (same lists, another country filter) is not a send of this one
        next if defined $want_domain && !Odoo::Ops::Mailing::Common::same_domain( Odoo::Ops::Mailing::Common::text( $m->{ $f->('domain') } ) || $want_domain, $want_domain );
        my $when = Odoo::Ops::Mailing::Common::text( $m->{ $f->('sent_date') } ) || Odoo::Ops::Mailing::Common::text( $m->{ $f->('updated') } );
        $when = substr( $when, 0, 16 ) if length $when > 16;
        push @note, "sent before: mailing $m->{id} ($m->{ $f->('state') }" . ( length $when ? ", $when" : '' ) . ') has this subject and these lists; this plan makes a new draft';
        last if @note >= 3;
    }
    return @note;
}

# the slice param: a map of one or two contact ids, validated before anything is read
sub _slice ($self) {
    my $s = $self->param('slice');
    return () if !defined $s;
    my $fix = 'slice is {"from_id":N,"before_id":M}: the contacts with id >= from_id and id < before_id, either bound may be left out, not both (mailing.partition slices=N gives the cut points)';
    Odoo::Error->throw( kind => 'usage', message => 'mailing.create: slice must be a map with from_id and/or before_id', fix => $fix )
        if ref $s ne 'HASH' || grep { !/\A(?:from_id|before_id)\z/ } keys %$s;
    my @v = map { $s->{$_} } qw(from_id before_id);
    for my $i ( 0, 1 ) {
        next if !defined $v[$i];
        my $name = ( qw(from_id before_id) )[$i];
        Odoo::Error->throw( kind => 'usage', message => "mailing.create: slice $name must be a contact id (a whole number of at least 1), not '$v[$i]'", fix => $fix )
            if ref $v[$i] || $v[$i] !~ /\A[1-9]\d*\z/;
        $v[$i] += 0;
    }
    Odoo::Error->throw( kind => 'usage', message => 'mailing.create: give slice from_id, before_id or both', fix => $fix ) if !defined $v[0] && !defined $v[1];
    Odoo::Error->throw( kind => 'usage', message => "mailing.create: slice from_id $v[0] is not below before_id $v[1]: the range holds no contact", fix => $fix )
        if defined $v[0] && defined $v[1] && $v[0] >= $v[1];
    return @v;
}

sub _body ($self) {
    my ( $file, $text ) = ( $self->param('body_file'), $self->param('body') );
    Odoo::Error->throw( kind => 'usage', message => 'mailing.create: give body_file or body, not both' ) if defined $file && defined $text;
    return $text if defined $text;
    return undef if !defined $file;
    open my $fh, '<:raw', $file or Odoo::Error->throw( kind => 'usage', message => "mailing.create: cannot read $file: $!", fix => 'check the path exists and this user can read it' );
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $html = eval { Encode::decode( 'UTF-8', $raw, Encode::FB_CROAK ) }
        // Odoo::Error->throw( kind => 'usage', message => "mailing.create: $file is not valid UTF-8", fix => 'correct the file; oom-ops describe <op> shows what it holds' );
    Odoo::Error->throw( kind => 'usage', message => "mailing.create: $file is empty" ) if $html !~ /\S/;
    return $html;
}

1;
