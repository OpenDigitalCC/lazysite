package Odoo::Ops::Mailing::Catcher;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use HTTP::Tiny;
use Odoo::JSON;

use Odoo::Ops::Mailing::Plaintext;

=head1 NAME

Odoo::Ops::Mailing::Catcher - read a delivered mail back from a mail catcher

=head1 SYNOPSIS

    my $seen = Odoo::Ops::Mailing::Catcher::known( $url, to => 'a@example.com' );
    ... send ...
    my $mail = Odoo::Ops::Mailing::Catcher::read_back( $url, to => 'a@example.com', subject => 'Hi', seen => $seen,
        base_url => 'https://odoo.example' );

=head1 DESCRIPTION

The catcher is a Mailpit (config key C<mailcatcher>, its address). C<read_back>
finds the newest mail to an address that was not there before the send (C<seen>,
the ids C<known> returned), and reports what a recipient's program would get:
C<text> and C<html> (the two parts), C<list_unsubscribe> and
C<list_unsubscribe_post> (the headers; Odoo writes a long one as RFC 2047
encoded words, which are decoded here, and C<list_unsubscribe_encoded> says it
was written so), C<one_click_url> (the address inside
C<List-Unsubscribe>) and C<text_links> (the verdicts of
L<Odoo::Ops::Mailing::Plaintext/text_links> over the links of the text part, found
in the text as C<[n] url> lines). It returns undef when no such mail arrives.

The HTTP client is C<HTTP::Tiny>; a test sets C<$Odoo::Ops::Mailing::Catcher::HTTP>
to an object with a C<get($url)> method.

=cut

our $HTTP;
sub _http () { $HTTP //= HTTP::Tiny->new( timeout => 15 ) }

sub _enc ($s) { $s =~ s/([^A-Za-z0-9_.~-])/sprintf '%%%02X', ord $1/ger }

sub _query (%o) {
    my @q;
    push @q, 'to:"' . ( $o{to} =~ s/"//gr ) . '"' if defined $o{to};
    push @q, 'subject:"' . ( $o{subject} =~ s/"//gr ) . '"' if defined $o{subject} && length $o{subject};
    return join ' ', @q;
}

sub _get_json ( $url ) {
    my $r = eval { _http()->get($url) } or return undef;
    return undef if !$r->{success};
    return eval { Odoo::JSON::decode( $r->{content} ) };
}

=head2 known($url, to => $address, subject => $subject)

The ids of the mails the catcher holds for the query now, as a hash.

=cut

sub known ( $url, %o ) {
    $url =~ s{/+\z}{};
    my $d = _get_json( "$url/api/v1/search?query=" . _enc( _query(%o) ) . '&limit=200' ) // {};
    return { map { $_->{ID} => 1 } @{ $d->{messages} // [] } };
}

=head2 read_back($url, to => ..., subject => ..., seen => \%known, base_url => ..., series => 16|18, tries => N)

See above. C<tries> is the number of half-second waits for the mail to arrive (default 10).

=cut

sub read_back ( $url, %o ) {
    $url =~ s{/+\z}{};
    my $seen = $o{seen} // {};
    my $hit;
    for ( 1 .. ( $o{tries} // 10 ) ) {
        my $d = _get_json( "$url/api/v1/search?query=" . _enc( _query(%o) ) . '&limit=200' ) // {};
        ($hit) = grep { !$seen->{ $_->{ID} } } @{ $d->{messages} // [] };
        last if $hit;
        select undef, undef, undef, 0.5;
    }
    return undef if !$hit;
    my $m = _get_json("$url/api/v1/message/$hit->{ID}") or return undef;
    my $h = _get_json("$url/api/v1/message/$hit->{ID}/headers") // {};
    # Odoo writes a long header as RFC 2047 encoded words (List-Unsubscribe is one); the catcher hands them over as written
    my %hdr = map { lc $_ => scalar( eval { Encode::decode( 'MIME-Header', $h->{$_}[0] ) } // $h->{$_}[0] ) } grep { ref $h->{$_} eq 'ARRAY' && @{ $h->{$_} } } keys %$h;
    my $encoded = ( $h->{'List-Unsubscribe'} && $h->{'List-Unsubscribe'}[0] =~ /=\?[\w-]+\?[QqBb]\?/ ) ? 1 : 0;
    my $text = $m->{Text} // '';
    $text =~ s/\r\n/\n/g;
    my @urls = $text =~ /^\[\d+\] (\S.*)$/mg;
    my ($one) = ( $hdr{'list-unsubscribe'} // '' ) =~ /<([^>]+)>/;
    return {
        to                    => $o{to},
        id                    => $hit->{ID},
        subject               => $m->{Subject},
        text                  => $text,
        html                  => $m->{HTML} // '',
        list_unsubscribe      => $hdr{'list-unsubscribe'},
        list_unsubscribe_post => $hdr{'list-unsubscribe-post'},
        list_unsubscribe_encoded => $encoded,
        one_click_url         => $one,
        text_links            => Odoo::Ops::Mailing::Plaintext::text_links( \@urls, base_url => $o{base_url}, series => $o{series} ),
    };
}

1;
