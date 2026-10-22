package Odoo::Ops::Mailing::Plaintext;

use strict;
use warnings;
use feature qw(signatures unicode_strings);
no warnings 'experimental::signatures';

use Encode ();
use XML::LibXML ();

use Odoo::Error;

=head1 NAME

Odoo::Ops::Mailing::Plaintext - a mailing's plain-text part as Odoo makes it, and what its links will do

=head1 SYNOPSIS

    my ( $text, $urls ) = Odoo::Ops::Mailing::Plaintext::html2plaintext($html);
    my $links = Odoo::Ops::Mailing::Plaintext::text_links( $urls, base_url => 'http://odoo.example' );

=head1 DESCRIPTION

C<html2plaintext> is a port of C<odoo.tools.mail.html2plaintext>, the
function Odoo's mail sending calls to make the plain-text part of every mail
(C<mail.mail._send_prepare_values> on 16, C<_prepare_outgoing_list> on 18).
The two series carry the same function apart from the way each checks its
argument. It is a port and not an imitation: the HTML is parsed by libxml2's
HTML parser (the parser Odoo's C<lxml> uses), written back out the way
C<etree.tostring> writes it (XML syntax: C<< <br/> >>, text escaped, a
C<script> body escaped like any text), and then the same string
replacements run in the same order (C<< <strong> >> and C<< <b> >> to C<*>,
C<h1> and C<h2> to C<**>, C<h3> to C<*>, C<em> to C</>, rows and paragraph
ends to newlines, every other tag to a space, three entities decoded, every line
stripped, blank lines collapsed once), with Python's definitions of white space
and line ends. A link with an C<href> becomes C<text [n]>; its URL is listed
after the text as C<[n] url>. The tests compare it with Odoo's own output for the
fixtures in C<t/data/html2plaintext/> (C<t/144-html2plaintext.t>) and
C<t/146-mail39-live.t> compares it again on 16 and 18 through a mail Odoo sends.

In list context C<html2plaintext> returns the text and the list of URLs, in the
order of their numbers (links first, then images). It dies with kind C<fault>
when the body cannot be parsed (Odoo's own raises on such a body).

C<text_links> gives each URL a verdict. Odoo makes the plain-text part
B<before> C<mass_mailing> swaps the recipient's own links into the HTML
part, so a link that is Odoo's placeholder stays one in the text part:

=over 4

=item C<unsubscribe-placeholder>

The URL holds C<< <base_url>/unsubscribe_from_list >>. Odoo's route for it
is a dummy (Odoo fault 001, C<mass_mailing> text part): on 16 it answers 404, on 18 it
redirects to C</mailing/my>, a page that needs a login, so an anonymous recipient
reaches a login page and unsubscribes nobody (read on demo16 and demo18, 2026-10-20).
The HTML part and the C<List-Unsubscribe> header carry the recipient's own working link.

=item C<view-placeholder>

The URL holds C<< <base_url>/view >>: the same, for the "view in browser" link (16
answers 404, 18 redirects to the login page).

=item C<ok>

Anything else.

=back

=cut

# Python's str.strip() and str.splitlines() definitions, which Odoo's function uses
my $PYWS = "\\t\\n\\x0b\\x0c\\r\\x1c-\\x1f \\x85\\xa0\\x{1680}\\x{2000}-\\x{200a}\\x{2028}\\x{2029}\\x{202f}\\x{205f}\\x{3000}";
sub _strip ($s) { $s =~ s/\A[$PYWS]+//r =~ s/[$PYWS]+\z//r }
sub _lines ($s) {
    my @l = split /\r\n|[\n\r\x0b\x0c\x1c\x1d\x1e\x85\x{2028}\x{2029}]/, $s, -1;
    pop @l if @l && $l[-1] eq '';
    return @l;
}

# text of an element's start, as lxml's .text reads it (None when the first child is not text)
sub _lead_text ($el) {
    my ( $t, $any ) = ( '', 0 );
    for my $c ( $el->childNodes ) {
        my $ty = $c->nodeType;
        last if $ty != XML::LibXML::XML_TEXT_NODE && $ty != XML::LibXML::XML_CDATA_SECTION_NODE;
        $t .= $c->data;
        $any = 1;
    }
    return $any ? $t : undef;
}

# lxml's .text = value: the leading text nodes are replaced by one
sub _set_lead_text ( $el, $value ) {
    for my $c ( $el->childNodes ) {
        my $ty = $c->nodeType;
        last if $ty != XML::LibXML::XML_TEXT_NODE && $ty != XML::LibXML::XML_CDATA_SECTION_NODE;
        $el->removeChild($c);
    }
    my $n = $el->ownerDocument->createTextNode($value);
    my $first = $el->firstChild;
    if ($first) { $el->insertBefore( $n, $first ) } else { $el->appendChild($n) }
    return;
}

# etree.tostring(element) in its default (XML) method, UTF-8 characters left as they are
sub _esc_text ($s) { $s =~ s/&/&amp;/gr =~ s/</&lt;/gr =~ s/>/&gt;/gr =~ s/\r/&#13;/gr }
sub _esc_attr ($s) { $s =~ s/&/&amp;/gr =~ s/</&lt;/gr =~ s/>/&gt;/gr =~ s/"/&quot;/gr =~ s/\n/&#10;/gr =~ s/\r/&#13;/gr =~ s/\t/&#9;/gr }

sub _serialise ($n) {
    my $ty = $n->nodeType;
    return _esc_text( $n->data ) if $ty == XML::LibXML::XML_TEXT_NODE || $ty == XML::LibXML::XML_CDATA_SECTION_NODE;
    return '<!--' . $n->data . '-->' if $ty == XML::LibXML::XML_COMMENT_NODE;
    return '<?' . $n->nodeName . ( length( $n->data // '' ) ? ' ' . $n->data : '' ) . '?>' if $ty == XML::LibXML::XML_PI_NODE;
    return '' if $ty != XML::LibXML::XML_ELEMENT_NODE;
    my $name = $n->nodeName;
    my $attrs = join '', map { ' ' . $_->nodeName . '="' . _esc_attr( $_->value // '' ) . '"' } $n->attributes;
    my @kids = $n->childNodes;
    return "<$name$attrs/>" if !@kids;
    return "<$name$attrs>" . join( '', map { _serialise($_) } @kids ) . "</$name>";
}

=head1 FUNCTIONS

=head2 html2plaintext($html)

C<odoo.tools.mail.html2plaintext($html)>. Returns the text, and in list context
the list of URLs too.

=cut

sub html2plaintext ($html) {
    $html //= '';
    return wantarray ? ( '', [] ) : '' if $html !~ /[^$PYWS]/;

    my $doc = eval {
        my $p = XML::LibXML->new;
        $p->parse_html_string( Encode::encode( 'UTF-8', $html ),
            { encoding => 'UTF-8', recover => 2, no_network => 1, suppress_errors => 1, suppress_warnings => 1 } );
    };
    my $root = $doc ? $doc->documentElement : undef;
    Odoo::Error->throw( kind => 'fault', message => "the body cannot be parsed as HTML, so Odoo's html2plaintext would raise on it" ) if !$root;
    my ($body) = $root->findnodes('//body');
    my $tree = $body // $root;

    my ( @url, $i );
    for my $link ( $tree->findnodes('.//a') ) {
        my $url = $link->getAttribute('href');
        next if !defined $url || !length $url;
        $i++;
        $link->setNodeName('span');
        _set_lead_text( $link, ( _lead_text($link) // 'None' ) . " [$i]" );
        push @url, $url;
    }
    for my $img ( $tree->findnodes('.//img') ) {
        my $src = $img->getAttribute('src');
        next if !defined $src || !length $src;
        $i++;
        $img->setNodeName('span');
        my $name = $src =~ /^data:/ ? undef : ( $src =~ m{([^/]+)(?=\.[a-zA-Z]+(?:\?|$))} )[0];
        _set_lead_text( $img, ( defined $name ? $name : 'Image' ) . " [$i]" );
        push @url, $src;
    }

    my $h = _serialise($tree);
    $h =~ s/&#13;//g;
    $h =~ s{<strong>}{*}g;  $h =~ s{</strong>}{*}g;
    $h =~ s{<b>}{*}g;       $h =~ s{</b>}{*}g;
    $h =~ s{<h3>}{*}g;      $h =~ s{</h3>}{*}g;
    $h =~ s{<h2>}{**}g;     $h =~ s{</h2>}{**}g;
    $h =~ s{<h1>}{**}g;     $h =~ s{</h1>}{**}g;
    $h =~ s{<em>}{/}g;      $h =~ s{</em>}{/}g;
    $h =~ s{<tr>}{\n}g;
    $h =~ s{</p>}{\n}g;
    $h =~ s{<br\s*/?>}{\n}g;
    $h =~ s{<.*?>}{ }g;
    $h =~ s/  / /g;
    $h =~ s/&gt;/>/g;
    $h =~ s/&lt;/</g;
    $h =~ s/&amp;/&/g;
    $h =~ s/&nbsp;/\x{A0}/g;

    $h = join "\n", map { _strip($_) } _lines($h);
    $h =~ s/\n\n/\n/g;

    for my $k ( 0 .. $#url ) {
        $h .= "\n\n" if $k == 0;
        $h .= '[' . ( $k + 1 ) . "] $url[$k]\n";
    }
    $h = _strip($h);
    return wantarray ? ( $h, \@url ) : $h;
}

=head2 text_links($urls, base_url => $base, series => 16|18)

One row per URL of the text part: C<n> (its number), C<url> and C<verdict>
(see above); a row that is a placeholder also says C<answers> (what the link
does when followed: C<404> on 16, a redirect to a login page on 18; without
C<series> both are named), C<series> and C<fault> (what Odoo does, in a
sentence). A caller that does not know the base URL gets the placeholders found
by their path alone.

=cut

my $FAULT = 'Odoo makes the plain-text part before mass_mailing swaps the recipient\'s own links into the HTML part, so the placeholder stays in it (odoo/001-mass-mailing-text-part-unsubscribe-404: mass_mailing/models/mail_mail.py replaces them in the body only; the route is a dummy)';

my %ANSWERS = (
    'unsubscribe-placeholder' => { 16 => '404', 18 => '301 to /mailing/my, a page that needs a login: an anonymous recipient reaches the login page and unsubscribes nobody', 0 => '404 on 16; on 18 a redirect to /mailing/my, a page that needs a login' },
    'view-placeholder'        => { 16 => '404', 18 => '303 to the login page: the route needs a login', 0 => '404 on 16; on 18 a redirect to the login page' },
);

sub text_links ( $urls, %o ) {
    my $base = $o{base_url} // '';
    $base =~ s{/+\z}{};
    my @rows;
    my $n = 0;
    for my $u (@$urls) {
        $n++;
        my %r = ( n => $n, url => $u, verdict => 'ok' );
        # Odoo's test is a substring of the base URL and the path (mail.mail._send_prepare_values)
        my $unsub = length $base ? index( $u, "$base/unsubscribe_from_list" ) >= 0 : $u =~ m{^(?:https?://[^/]+)?/unsubscribe_from_list(?:[?#]|\z)};
        my $view  = length $base ? index( $u, "$base/view" ) >= 0 : $u =~ m{^(?:https?://[^/]+)?/view(?:[?#/]|\z)};
        my $s = $o{series} && $ANSWERS{'view-placeholder'}{ $o{series} } ? $o{series} : 0;
        if    ($unsub) { @r{qw(verdict answers fault)} = ( 'unsubscribe-placeholder', $ANSWERS{'unsubscribe-placeholder'}{$s}, $FAULT ); $r{series} = $s if $s }
        elsif ($view)  { @r{qw(verdict answers fault)} = ( 'view-placeholder', $ANSWERS{'view-placeholder'}{$s}, $FAULT ); $r{series} = $s if $s }
        push @rows, \%r;
    }
    return \@rows;
}

=head2 placeholders($rows)

The rows of C<text_links> that are not C<ok>.

=cut

sub placeholders ($rows) { [ grep { $_->{verdict} ne 'ok' } @$rows ] }

=head2 warning($rows)

The one line a plan carries when a placeholder remains, or undef.

=cut

sub warning ($rows) {
    my %v = map { $_->{verdict} => 1 } @$rows;
    return undef if !$v{'unsubscribe-placeholder'} && !$v{'view-placeholder'};
    my @which = ( ( $v{'unsubscribe-placeholder'} ? 'unsubscribe' : () ), ( $v{'view-placeholder'} ? 'view' : () ) );
    my ($series) = map { $_->{series} } grep { $_->{series} } @$rows;
    my $what = !$series ? 'will not work (404 on 16, a redirect to a login page on 18)' : $series == 16 ? 'will 404' : 'will not work (Odoo 18 redirects it to a login page)';
    return 'the text part\'s ' . join( ' and ', @which ) . " link $what (Odoo makes the text part before it swaps in the recipient's own); the HTML part and the List-Unsubscribe header work; see Odoo fault 001 (mass-mailing-text-part-unsubscribe-404)";
}

1;
