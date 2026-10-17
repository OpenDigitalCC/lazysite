package Odoo::Ops::Totp;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Digest::SHA qw(hmac_sha1);

=head1 NAME

Odoo::Ops::Totp - the one-time code of RFC 6238, for turning two-factor on

=head1 SYNOPSIS

    my $code = Odoo::Ops::Totp->code( $secret_base32 );            # now
    my $code = Odoo::Ops::Totp->code( $secret_base32, time => 59 );

=head1 DESCRIPTION

Odoo's C<auth_totp> module (16 to 19) uses HMAC-SHA1, 6 digits, a
30-second step, and a secret in base32 shown to the person in groups of
four characters. This module computes the code a person's authenticator
would show, so that L<Odoo::Ops::Core::User>'s C<totp> action can walk
the same wizard a person walks. Nothing here talks to Odoo and nothing
keeps a secret.

=head2 base32_decode($text)

The bytes of an RFC 4648 base32 string. Spaces, hyphens and padding are
ignored; case does not matter. A character outside the alphabet dies.

=cut

my $ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

sub base32_decode ( $class, $text ) {
    ( my $t = uc( $text // '' ) ) =~ s/[\s\-=]//g;
    my $bits = '';
    for my $ch ( split //, $t ) {
        my $v = index( $ALPHABET, $ch );
        die "not a base32 character\n" if $v < 0;
        $bits .= sprintf '%05b', $v;
    }
    $bits = substr( $bits, 0, length($bits) - length($bits) % 8 );
    return pack 'B*', $bits;
}

=head2 code($secret, %opt)

The code for a base32 C<$secret>. Options: C<time> (seconds since the
epoch, default now), C<step> (30), C<digits> (6), C<offset> (a whole
number of steps added to the counter, default 0, for the step before or
after).

=cut

sub code ( $class, $secret, %o ) {
    my $key     = $class->base32_decode($secret);
    my $step    = $o{step}   // 30;
    my $digits  = $o{digits} // 6;
    my $counter = int( ( $o{time} // time ) / $step ) + ( $o{offset} // 0 );
    my $msg     = pack( 'N2', int( $counter / 4294967296 ), $counter % 4294967296 );
    my $mac     = hmac_sha1( $msg, $key );
    my $off     = ord( substr( $mac, -1 ) ) & 0x0f;
    my $bin     = unpack( 'N', substr( $mac, $off, 4 ) ) & 0x7fffffff;
    return sprintf "%0${digits}d", $bin % ( 10**$digits );
}

1;
