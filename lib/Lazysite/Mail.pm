package Lazysite::Mail;

# SM1017 (SM1010 F2): WHAT ONE MAIL ADDRESS IS, defined once.
#
# The site writes an address into a `To:` header in more than one place - the
# form handler's own copy, the SM877 acknowledgement to whatever a form field
# held, a password setup link, a notice to an account - and every one of them
# goes through `sendmail -t` or an SMTP RCPT, both of which read a header that
# names SEVERAL recipients as several recipients. The acknowledgement's check
# was "something, an @, something", which admits `root,victim@example.org`: one
# @, and two recipients once the header is parsed - a local mailbox and a
# stranger. The writer stripped `<` and `>` rather than refusing them, so
# `x<b@example.org>` arrived as a different address from the one typed.
#
# RULED 2026-10-12 (the release manager, SM1010 phase 0): an address the mail
# handler puts into a header is EXACTLY ONE ADDRESS - no , ; < > and no CR or LF
# - and anything else is REFUSED, never repaired. Repairing is how a refused
# value turns into a delivered one.
#
# So this is the shape and nothing more: a bare `local@domain`, with none of
# the characters a header parser treats as structure (the list separators, the
# angle brackets, quotes, parentheses, a backslash) and no whitespace or
# control character anywhere. It is deliberately not an RFC 5322 parser - an
# address that needs quoting to be valid is not one the site needs to send to.
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(one_address encode_header);

my $ATOM = qr/[^\s\@,;<>"()\\\x00-\x1f\x7f]+/;

# ( $address, '' ) when $v is exactly one address, else ( undef, $why ). The
# value is taken as given: a caller that wants surrounding spaces ignored trims
# them first, so this never silently changes what it was handed.
#
# The reason NEVER QUOTES THE VALUE. It travels into delivery notes and so into
# the audit trail, and SM877's rule is that the site keeps no list of addresses
# it was given - a refused address is still somebody's address.
sub one_address {
    my ($v) = @_;
    return ( undef, 'no address was given' ) unless defined $v && !ref $v && length $v;
    return ( undef, 'it is not exactly one address: it contains a line break' )
        if $v =~ /[\r\n]/;
    return ( undef, 'it is not exactly one address: it names more than one recipient '
            . '(no , ; < or > is allowed)' )
        if $v =~ /[,;<>]/;
    return ( undef, 'it is not an email address' ) unless $v =~ /\A$ATOM\@$ATOM\z/;
    return ( $v,    '' );
}


# SM1020: A HEADER VALUE THAT IS NOT ASCII, ENCODED (RFC 2047).
#
# A Subject carrying "é" or "—" went out as raw UTF-8 bytes in a header, which
# the RFCs do not allow and mail clients render as mojibake or reject. ASCII
# passes unchanged. Anything else becomes one or more `=?UTF-8?B?...?=` words of
# at most 45 bytes each (so every encoded word stays under 75 characters), split
# only between characters - an encoded word may not end inside one - and joined
# by a folding newline and space. CR and LF are refused by the caller first;
# this never emits a bare line break that is not a fold.
sub encode_header {
    my ($v) = @_;
    $v = '' unless defined $v;
    $v =~ s/[\r\n]+/ /g;
    return $v unless $v =~ /[^\x20-\x7e]/;
    require MIME::Base64;
    my ( @words, $buf );
    $buf = '';
    for my $ch ( split //, $v ) {
        my $b = $ch;
        utf8::encode($b);
        if ( length($buf) + length($b) > 45 ) { push @words, $buf; $buf = '' }
        $buf .= $b;
    }
    push @words, $buf if length $buf;
    return join "\n ", map { '=?UTF-8?B?' . MIME::Base64::encode_base64( $_, '' ) . '?=' } @words;
}

1;
