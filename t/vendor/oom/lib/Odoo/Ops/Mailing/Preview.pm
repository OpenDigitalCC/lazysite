package Odoo::Ops::Mailing::Preview;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use HTML::Entities ();

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Mailing::Common;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Mailing::Preview - the mail one recipient would get, read without a catcher

=head1 SYNOPSIS

    oom-ops run mailing.preview --conf ops.conf --set mailing=7
    oom-ops run mailing.preview --conf ops.conf --set mailing=7 --set email=ann@example.com

=head1 DESCRIPTION

C<mailing.preview> renders mailing C<mailing> for one recipient and
returns what Odoo would send, so a person or an agent can read the mail
without sending it and without a mail catcher. The recipient is C<email>
(a contact's address) or C<contact> (a C<mailing.contact> id), else the
first reachable subscription of the mailing's lists (a valid address, not
opted out, not blacklisted). It never sends anything and writes nothing
that lasts.

B<How it renders (Odoo 16, proved on demo16).> The rendering methods of
C<mail.render.mixin> are private and cannot be called over RPC, but the
composer's C<get_mail_values> is public: it is the very method Odoo's own
send calls to build each recipient's mail, and it returns the values
without creating a mail or a trace. Preview makes a transient composer
(C<mail.compose.message>, mode C<mass_mail>, made from the mailing the
way C<action_send_mail> makes it; Odoo vacuums transient records), asks it
for the one recipient and reads the answer. So C<subject>, C<from>,
C<reply_to> and C<html> are Odoo's own rendering for that recipient
(C<rendered_by: odoo>): the QWeb of the body, links made absolute and the
mass-mailing layout around it. Nothing is persisted: no trace, no
C<mail.mail>, no C<link.tracker>.

B<What differs from the mail that goes out.> Three things happen in
Odoo's send after the composer, and cannot be reproduced here:

=over 4

=item * The unsubscribe anchor C</unsubscribe_from_list> is rewritten into
the recipient's own link by C<mail.mail._send_prepare_values> when the
mail is sent. That link carries a token, an HMAC of the mailing, the
recipient and the address under the database secret (C<database.secret>).
OOM does not read that secret, so the preview rewrites the anchor to the
real shape with the token left as C<TOKEN-SIGNED-BY-ODOO-AT-SEND>
(C<unsubscribe_url>, C<unsubscribe_token> says why): it shows where the
link goes, it does not unsubscribe anyone.

=item * Tracked links are shortened into C</r/E<lt>codeE<gt>> links only
when the composer runs with the mailing's link-tracker context, which
makes C<link.tracker> rows. The preview does not, so the links read as
written; after a send, C<tracked_links> lists the ones Odoo made (the
click path for a trace is its C<short_url> followed by C</m/E<lt>trace
idE<gt>>).

=item * The tracking image (C</mail/track/E<lt>mail idE<gt>/E<lt>tokenE<gt>/blank.gif>)
is appended to the sent body and needs the mail's id and a token. After a
send, C<tracking> names the recipient's trace and mail and the path with
the token left out; the mail is absent once Odoo deleted the delivered
mass mail.

=back

The C<text> part is derived here (C<text_derived_by: oom>, a close
imitation of Odoo's C<html2plaintext>), from the HTML before the unsubscribe
rewrite, because that is what Odoo does at send time: the plain-text part
keeps the raw C</unsubscribe_from_list> URL (16.0, proved by the try-out of
2026-10-15). C<placeholders> lists what the preview does not carry.

C<archived> reads an archived mailing. A mailing to a model other than
mailing lists is refused (C<not-a-list-mailing>); a mailing nobody can be
mailed for is refused (C<no-recipients>).

Series: written for Odoo 16; another series is refused by name until its
profile is probed.

=cut

sub op_name ($class) { 'mailing.preview' }
sub summary ($class) { 'Read the mail one recipient would get: subject, from, reply-to, HTML and text, rendered by Odoo (sends nothing)' }
sub pack    ($class) { 'mailing' }
sub params ($class) {
    {   mailing  => { type => 'int',  required => 1, help => 'the mailing id' },
        email    => { type => 'str',  help => 'render for the contact with this address' },
        contact  => { type => 'int',  help => 'render for this mailing.contact id' },
        archived => { type => 'bool', default => 0, help => 'allow an archived mailing' },
        html     => { type => 'str',  default => '1', help => '1 the full rendering (default), 0 no html string, inner the mailing body without the layout wrapper' },
    };
}
sub read_scope ($class) {
    {   mailing      => [qw(read search_count &base_url)],
        contact      => [qw(search_read read)],
        subscription => ['search_read'],
        composer     => [qw(create &render_one)],
        trace        => ['search_read'],
        mail         => ['search_count'],
        link_tracker => ['search_read'],
        'ir.mail_server'      => ['search_read'],
        'ir.config_parameter' => ['search_read'],
    };
}

sub scope_for ($self, $phase) { Odoo::Ops::Mailing::Common::scope( $self, $phase, $self->SUPER::scope_for($phase) ) }

sub report ($self) {
    my $p = Odoo::Ops::Mailing::Common::ready($self);
    my $f = sub ( $lm, $lf ) { $p->field( $lm => $lf ) };
    my $id = $self->param('mailing');
    my $mm = $self->model('mailing');
    my $htmlmode = lc( $self->param('html') // '1' );
    $htmlmode = { yes => 1, true => 1, no => 0, false => 0 }->{$htmlmode} // $htmlmode;
    Odoo::Error->throw( kind => 'usage', message => "mailing.preview: html must be 1, 0 or inner, not '$htmlmode'" )
        if $htmlmode !~ /^(?:1|0|inner)\z/;
    Odoo::Error->throw( kind => 'usage', message => 'mailing.preview: give email or contact, not both' )
        if defined $self->param('email') && defined $self->param('contact');

    my @read = map { $f->( mailing => $_ ) } qw(subject body_html state lists model_real email_from reply_to reply_to_mode active);
    my $m = $mm->read( [$id], \@read )->[0]
        or Odoo::Error->throw( kind => 'refused', code => 'unknown-mailing', message => "mailing.preview: no mailing $id",
            fix => q(oom-ops run mailing.status --conf <conf> lists the mailings) );
    Odoo::Error->throw( kind => 'refused', code => 'archived', message => "mailing.preview: mailing $id is archived; pass archived=1 to preview it", fix => 'pass --set archived=1' )
        if !$m->{ $f->( mailing => 'active' ) } && !$self->param('archived');
    Odoo::Error->throw( kind => 'refused', code => 'not-a-list-mailing',
        message => "mailing $id is to " . $m->{ $f->( mailing => 'model_real' ) } . ', not to mailing lists; mailing.preview does lists only' )
        if $m->{ $f->( mailing => 'model_real' ) } ne $p->model_name('contact');
    my @lists = @{ $m->{ $f->( mailing => 'lists' ) } // [] };

    my $who = $self->_recipient( $p, \@lists );

    # the composer as action_send_mail makes it (mass_mailing/models/mailing.py), for one recipient
    my $mode = $m->{ $f->( mailing => 'reply_to_mode' ) } // '';
    my %cv = (
        $f->( composer => 'mode' )    => 'mass_mail',
        $f->( composer => 'model' )   => $p->model_name('contact'),
        $f->( composer => 'subject' ) => $m->{ $f->( mailing => 'subject' ) },
        $f->( composer => 'body' )    => Odoo::Ops::Mailing::Common::text( $m->{ $f->( mailing => 'body_html' ) } ),
        $f->( composer => 'mailing' ) => $id,
        $f->( composer => 'lists' )   => [ map { [ 4, $_ ] } @lists ],
        $f->( composer => 'reply_to_force_new' ) => $mode eq 'new' ? JSON::PP::true : JSON::PP::false,
    );
    my $from = Odoo::Ops::Mailing::Common::text( $m->{ $f->( mailing => 'email_from' ) } );
    $cv{ $f->( composer => 'email_from' ) } = $from if length $from;
    $cv{ $f->( composer => 'reply_to' ) } = Odoo::Ops::Mailing::Common::text( $m->{ $f->( mailing => 'reply_to' ) } ) if $mode eq 'new';
    my $comp = $self->model('composer');
    my $cid  = $comp->create( \%cv );
    my $res  = $comp->call( $p->action('render_one'), [ [$cid], [ $who->{id} ] ],
        context => { active_ids => [ $who->{id} ], active_model => $p->model_name('contact') } );
    my $one = ref $res eq 'HASH' ? $res->{ $who->{id} } : undef;
    Odoo::Error->throw( kind => 'fault', message => "mailing.preview: Odoo rendered nothing for contact $who->{id}" ) if ref $one ne 'HASH';

    my $base = $mm->call( $p->action('base_url'), [ [$id] ] );
    $base = '' if ref $base || !defined $base;
    $base =~ s{/+\z}{};
    my $html = Odoo::Ops::Mailing::Common::text( $one->{body_html} );
    my $href = $p->action('unsubscribe_href');
    # the raw URL Odoo's send looks for in the body: the base URL and the path
    my $raw = "$base$href";
    my $text = _plain($html);
    my $has_anchor = index( $html, $raw ) >= 0;

    my $unsub = sprintf '%s/mailing/%d/confirm_unsubscribe?res_id=%d&email=%s&token=TOKEN-SIGNED-BY-ODOO-AT-SEND', $base, $id, $who->{id}, _urlenc( $who->{email} );
    ( my $unsub_html = $unsub ) =~ s/&/&amp;/g;
    $html =~ s/\Q$raw\E/$unsub_html/g if $has_anchor;

    my $from_text = Odoo::Ops::Mailing::Common::text( $one->{email_from} );
    my ( $sent_from, $from_note ) = $self->_sent_from($from_text);
    my %out = (
        mailing         => $id,
        rendered_by     => 'odoo',
        recipient       => { contact_id => $who->{id}, email => $who->{email}, name => $who->{name} },
        subject         => Odoo::Ops::Mailing::Common::text( $one->{subject} ),
        from            => $from_text,
        sent_from       => $sent_from,
        from_note       => $from_note,
        reply_to        => Odoo::Ops::Mailing::Common::text( $one->{reply_to} ),
        text            => $text,        text_derived_by => 'oom',
        unsubscribe_url => $has_anchor ? $unsub : undef,
        unsubscribe_token => 'signed by Odoo at send time (an HMAC under database.secret, which OOM does not read); the URL shows where the link goes and does not unsubscribe anyone',
        placeholders    => [
            ( $has_anchor ? 'the unsubscribe link: its token is a placeholder' : 'the body has no ' . $href . ' anchor: the mail goes out with no way to opt out' ),
            'links to other pages read as written: Odoo shortens them into tracked links only at send (see tracked_links after a send)',
            'no tracking image: Odoo appends it to the sent body (see tracking after a send)',
            'the text part is derived by OOM, not rendered by Odoo',
        ],
    );
    # text comes first: it is short and says what the mail reads like; the html follows
    if ( $htmlmode eq '1' ) { $out{html} = $html }
    elsif ( $htmlmode eq 'inner' ) {
        my $inner = Odoo::Ops::Mailing::Common::text( $m->{ $f->( mailing => 'body_html' ) } );
        $inner =~ s{\b(href|src)=(["'])/(?!/)}{$1=$2$base/}gi;
        $inner =~ s/\Q$raw\E/$unsub_html/g;
        $out{html} = $inner;
    }
    $out{state} = $m->{ $f->( mailing => 'state' ) };
    # after a send: what the trace and the link tracker hold for this recipient
    my %t = map { $_ => $f->( trace => $_ ) } qw(mailing res_id model mail status);
    my $tr = $self->model('trace')->search_read(
        [ [ $t{mailing}, '=', $id ], [ $t{res_id}, '=', $who->{id} ], [ $t{model}, '=', $p->model_name('contact') ] ], [ values %t ], order => 'id desc', limit => 1 )->[0];
    if ($tr) {
        my $mail = Odoo::Ops::Mailing::Common::id_of( $tr->{ $t{mail} } );
        # whether the mail still exists is a convenience: mail.mail needs Administration/Settings, so for a mailing
        # operator the trace's own mail id stands and the note says it is unchecked
        my $unchecked;
        if ($mail) {
            my ( $there, $why ) = Odoo::Ops::Mailing::Common::denied( sub { $self->model('mail')->count( [ [ 'id', '=', $mail ] ] ) }, 'whether the mail still exists' );
            if ( defined $why ) { $unchecked = $why } else { $mail = undef if !$there }
        }
        $out{tracking} = {
            trace_id => $tr->{id},
            status   => $tr->{ $t{status} },
            ( $mail ? ( mail_id => $mail, path => "/mail/track/$mail/<token>/blank.gif",
                token => 'signed by Odoo (an HMAC under database.secret); the image is appended to the sent body' ) : ( mail_id => undef ) ),
        };
        $out{tracking}{note} = 'Odoo deleted the delivered mail; the tracking image went out in it' if !$mail;
        $out{tracking}{note} = "$unchecked; mail_id is the trace's own record and Odoo may have deleted the mail since" if defined $unchecked;
    }
    my %l = map { $_ => $f->( link_tracker => $_ ) } qw(mailing url short_url count);
    my $links = $self->model('link_tracker')->search_read( [ [ $l{mailing}, '=', $id ] ], [ values %l ], order => 'id asc' );
    $out{tracked_links} = [ map { +{ url => $_->{ $l{url} }, short_url => $_->{ $l{short_url} }, clicks => $_->{ $l{count} } // 0 } } @$links ];
    $out{fields} = _fields();
    return \%out;
}

# Where the mail leaves from, worked out as Odoo 16 does it (ir.mail_server
# _find_mail_server and _prepare_email_message, mail.mail._split_by_mail_configuration)
# from the outgoing servers' from_filter and the mail.default.from and
# mail.catchall.domain parameters. Returns the From header the recipient's
# mail will carry and one sentence saying which case applied.
sub _sent_from ($self, $from) {
    my ( $name, $addr ) = $from =~ /\A\s*"?(.*?)"?\s*<([^>]+)>\s*\z/ ? ( $1, $2 ) : ( '', $from );
    my $e = Odoo::Ops::Mailing::Common::email($addr);
    return ( $from, 'the mailing has no sender address; Odoo fills in its default sender at send' ) if !defined $e;
    $name = ( split /\@/, $addr, 2 )[0] if !length $name;

    my ( @servers, %param );
    my ( $ok, $why_not ) = eval { Odoo::Ops::Mailing::Common::denied( sub {
        @servers = sort { ( $a->{sequence} // 0 ) <=> ( $b->{sequence} // 0 ) || $a->{id} <=> $b->{id} }
            @{ $self->client->model('ir.mail_server')->search_read( [ [ 'active', '=', JSON::PP::true ] ], [qw(name sequence from_filter active)] ) };
        %param = map { $_->{key} => Odoo::Ops::Mailing::Common::text( $_->{value} ) }
            @{ $self->client->model('ir.config_parameter')->search_read( [ [ 'key', 'in', [qw(mail.default.from mail.catchall.domain mail.default.from_filter)] ] ], [qw(key value)] ) };
        1;
    }, 'the outgoing mail servers and the sender parameters', 'the rewrite is not worked out and the header may differ' ) };
    # a mailing operator may not read either model: say which group would, and go on with the From as written
    return ( $from, $why_not ) if defined $why_not;
    return ( $from, 'the outgoing mail servers or the sender parameters could not be read, so the rewrite is not worked out; the header may differ' ) if !$ok;

    my $df = $param{'mail.default.from'} // '';
    my $cd = $param{'mail.catchall.domain'} // '';
    my $n  = $df =~ /\@/ ? Odoo::Ops::Mailing::Common::email($df) : ( length $df && length $cd ? lc "$df\@$cd" : undef );
    my $dom = sub ($a) { my ($d) = ( $a // '' ) =~ /\@(.+)\z/; return lc( $d // '' ) };
    my $match = sub ( $addr_, $filter ) {    # Odoo's _match_from_filter, for one server's filter
        return 1 if !length $filter;
        return $filter =~ /\@/ ? lc( Odoo::Ops::Mailing::Common::email($filter) // '' ) eq $addr_ : $dom->($addr_) eq lc $filter;
    };
    my $ff = sub ($s) { Odoo::Ops::Mailing::Common::text( $s->{from_filter} ) };
    my @filtered = grep { length $ff->($_) } @servers;

    my ( $smtp_from, $why );
    if ( my ($s) = grep { $ff->($_) =~ /\@/ && lc( Odoo::Ops::Mailing::Common::email( $ff->($_) ) // '' ) eq $e } @filtered ) {
        ( $smtp_from, $why ) = ( $e, "server '$s->{name}' has a from_filter for exactly $e" );
    }
    elsif ( ($s) = grep { $ff->($_) !~ /\@/ && lc $ff->($_) eq $dom->($e) } @filtered ) {
        ( $smtp_from, $why ) = ( $e, "server '$s->{name}' has a from_filter for the domain " . $dom->($e) );
    }
    elsif ( defined $n && ( ($s) = grep { $ff->($_) =~ /\@/ ? lc( Odoo::Ops::Mailing::Common::email( $ff->($_) ) // '' ) eq $n : lc $ff->($_) eq $dom->($n) } @filtered ) ) {
        ( $smtp_from, $why ) = ( $n, "no server's from_filter covers $e; server '$s->{name}' covers the default sender $n" );
    }
    elsif ( my ($open) = grep { !length $ff->($_) } @servers ) {
        ( $smtp_from, $why ) = ( $n // $e, "no server's from_filter covers $e and server '$open->{name}' has none" );
        $why .= defined $n ? ", so Odoo sends as the default sender $n (mail.default.from and mail.catchall.domain)" : ', and no default sender is set, so the address stands';
    }
    elsif (@servers) {
        ( $smtp_from, $why ) = ( $n // $e, "no server's from_filter covers $e and every server has one; Odoo falls back to the first server" );
        $why .= defined $n ? " and sends as the default sender $n" : ', and no default sender is set, so the address stands';
    }
    else {
        my $cf = $param{'mail.default.from_filter'} // '';
        if ( $match->( $e, $cf ) ) { ( $smtp_from, $why ) = ( $e, 'no outgoing mail server is defined (odoo-bin settings send; their from_filter is not read here)' ) }
        elsif ( defined $n && $match->( $n, $cf ) ) { ( $smtp_from, $why ) = ( $n, "no outgoing mail server is defined and mail.default.from_filter does not cover $e, so Odoo sends as $n" ) }
        else { ( $smtp_from, $why ) = ( $e, 'no outgoing mail server is defined and the sender cannot be worked out' ) }
    }

    # the header: an author replaced by the default sender keeps its name
    if ( lc $smtp_from ne $e ) {
        my $out = defined $n && lc $smtp_from eq $n ? sprintf( '"%s" <%s>', $name, $n ) : $smtp_from;
        return ( $out, "$why; the author's name stays in the header and the mailing's Reply-To is untouched" ) if defined $n && lc $smtp_from eq $n;
        return ( $out, $why );
    }
    return ( $from, "no rewrite: $why" );
}

# the contact asked for, or the first reachable subscription of the lists
sub _recipient ($self, $p, $lists) {
    my $f = sub ( $lm, $lf ) { $p->field( $lm => $lf ) };
    my @cf = map { $f->( contact => $_ ) } qw(name email_normalized blacklisted);
    my $cm = $self->model('contact');
    my $row;
    if ( defined $self->param('contact') ) {
        $row = $cm->read( [ $self->param('contact') ], \@cf )->[0]
            or Odoo::Error->throw( kind => 'refused', code => 'unknown-contact', message => 'mailing.preview: no contact ' . $self->param('contact'), fix => 'oom-ops run mailing.contacts --conf <conf> lists the contacts of a list' );
    }
    elsif ( defined $self->param('email') ) {
        my $e = Odoo::Ops::Mailing::Common::email( $self->param('email') )
            // Odoo::Error->throw( kind => 'usage', message => "mailing.preview: '" . $self->param('email') . "' is not an email address" );
        my $found = $cm->all( [ [ $f->( contact => 'email_normalized' ), '=', $e ] ], \@cf );
        Odoo::Error->throw( kind => 'refused', code => 'unknown-contact', message => "mailing.preview: no contact has the address $e", fix => 'oom-ops run mailing.contacts --conf <conf> lists the contacts of a list' ) if !@$found;
        # the contact on one of the mailing's lists is the one meant
        my %on;
        if (@$lists) {
            my $subs = $self->model('subscription')->all( [ [ $f->( subscription => 'list' ), 'in', $lists ], [ $f->( subscription => 'contact' ), 'in', [ map { $_->{id} } @$found ] ] ],
                [ $f->( subscription => 'contact' ) ] );
            $on{ Odoo::Ops::Mailing::Common::id_of( $_->{ $f->( subscription => 'contact' ) } ) } = 1 for @$subs;
        }
        ($row) = ( ( grep { $on{ $_->{id} } } @$found ), @$found );
    }
    else {
        my $page = 200;
        for ( my $off = 0 ; !$row ; $off += $page ) {
            my $subs = $self->model('subscription')->search_read(
                [ [ $f->( subscription => 'list' ), 'in', $lists ], [ $f->( subscription => 'opt_out' ), '=', JSON::PP::false ] ],
                [ $f->( subscription => 'contact' ) ], order => 'id asc', limit => $page, offset => $off );
            last if !@$subs;
            my %seen;
            my @cid = grep { !$seen{$_}++ } map { Odoo::Ops::Mailing::Common::id_of( $_->{ $f->( subscription => 'contact' ) } ) } @$subs;
            my %c = map { $_->{id} => $_ } @{ $cm->all( [ [ 'id', 'in', \@cid ] ], \@cf ) };
            ($row) = grep { $_ && length( Odoo::Ops::Mailing::Common::text( $_->{ $f->( contact => 'email_normalized' ) } ) ) && !$_->{ $f->( contact => 'blacklisted' ) } }
                map { $c{$_} } @cid;
            last if @$subs < $page;
        }
        Odoo::Error->throw( kind => 'refused', code => 'no-recipients',
            message => 'mailing.preview: no one on the mailing\'s lists can be mailed (opted out, blacklisted or without an address); name a contact with email= or contact=' )
            if !$row;
    }
    my $e = Odoo::Ops::Mailing::Common::text( $row->{ $f->( contact => 'email_normalized' ) } );
    Odoo::Error->throw( kind => 'usage', message => "mailing.preview: contact $row->{id} has no email address" ) if !length $e;
    return { id => $row->{id}, email => $e, name => Odoo::Ops::Mailing::Common::text( $row->{ $f->( contact => 'name' ) } ) };
}

sub _urlenc ($s) { $s =~ s/([^A-Za-z0-9_.~-])/sprintf '%%%02X', ord $1/ger }

# html2plaintext, near enough: Odoo's own is a regex pass of the same kind (odoo/tools/mail.py), links
# become "text [n]" with the addresses listed after
sub _plain ($html) {
    my $t = $html;
    $t =~ s{<(head|style|script)\b.*?</\1>}{}gis;
    $t =~ s{<!--.*?-->}{}gs;
    my @links;
    $t =~ s{<a\b[^>]*\bhref\s*=\s*(["'])(.*?)\1[^>]*>(.*?)</a>}{
        my ( $h, $label ) = ( $2, $3 );
        $label =~ s/<[^>]+>//g;
        if ( $h =~ m{^(?:https?:|/)}i ) { push @links, $h; "$label [" . scalar(@links) . ']' } else { $label }
    }gise;
    $t =~ s{<br\s*/?>}{\n}gi;
    $t =~ s{</(?:p|div|tr|h[1-6]|table|ul|ol)>}{\n\n}gi;
    $t =~ s{<li\b[^>]*>}{* }gi;
    $t =~ s{</li>}{\n}gi;
    $t =~ s{<hr\b[^>]*>}{\n}gi;
    $t =~ s{<[^>]+>}{}g;
    # named, decimal and hex entities become their characters (after the tags are gone, so an
    # escaped "<b>" stays text); a no-break space reads as the space it stands for
    $t = HTML::Entities::decode_entities($t);
    $t =~ tr/\x{A0}/ /;
    $t =~ s/[ \t]+\n/\n/g;
    $t =~ s/^[ \t]+//mg;
    $t =~ s/\n{3,}/\n\n/g;
    $t =~ s/\A\s+|\s+\z//g;
    $t .= "\n\n" . join( "\n", map { "[$_] $links[$_-1]" } 1 .. @links ) if @links;
    return "$t\n";
}

sub _fields () {
    my $s = sub ($t, $str) { { portable_type => $t, string => $str } };
    return {
        rendered_by     => $s->( 'text', 'odoo: subject, from, reply_to and html are Odoo\'s own rendering for this recipient' ),
        recipient       => $s->( 'object', 'The contact it was rendered for' ),
        subject         => $s->( 'text', 'Subject as Odoo renders it for the recipient' ),
        from            => $s->( 'text', 'The mailing\'s email_from, as Odoo renders it' ),
        sent_from       => $s->( 'text', 'The From header the mail will carry after Odoo\'s sender rewrite (from_filter of the outgoing servers, mail.default.from, mail.catchall.domain); equal to from when no rewrite applies' ),
        from_note       => $s->( 'text', 'One sentence: which case applied and why' ),
        reply_to        => $s->( 'text', 'Reply-to' ),
        html            => $s->( 'html', 'Absent with html=0. By default the body with the mass-mailing layout, links absolute, the unsubscribe link carrying a placeholder token; with html=inner the mailing\'s body_html alone (local links made absolute, the unsubscribe link rewritten, no per-recipient rendering), without the layout wrapper that the mail Odoo sends carries' ),
        text            => $s->( 'text', 'The plain-text part, derived from the HTML before the unsubscribe rewrite, as Odoo does at send (the raw unsubscribe URL stays in it)' ),
        text_derived_by => $s->( 'text', 'oom: the text part is not rendered by Odoo' ),
        unsubscribe_url => $s->( 'text', 'Where the recipient\'s unsubscribe link goes; its token is a placeholder (Odoo signs it at send)' ),
        placeholders    => $s->( 'list', 'What this preview does not carry compared with the sent mail' ),
        tracking        => $s->( 'object', 'After a send: the recipient\'s trace, and the mail whose tracking image carries the open' ),
        tracked_links   => $s->( 'list', 'After a send: the links Odoo shortened (url, short_url, clicks); a click is the short_url followed by /m/<trace id>' ),
    };
}

1;
