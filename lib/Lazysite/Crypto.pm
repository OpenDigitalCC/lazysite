package Lazysite::Crypto;

# SM1352, SM1363 (ruling 187): CRYPTX, ASKED FOR IN ONE PLACE.
#
# Passkeys verify a signature made by the person's authenticator (ECDSA P-256,
# RSA or Ed25519), and web push signs its VAPID token with the site's own P-256
# key. Core Perl does neither, so both lean on CryptX (Debian libcryptx-perl),
# which the deb RECOMMENDS rather than depends on: a site that uses neither
# feature never loads it, and nothing else in the engine needs it.
#
# LAZY, AND ONLY HERE. The two features ask cryptx_missing() before they do
# anything, and say its sentence - on the page, in the API answer and in
# `lazysite check` - when it is not installed. Every other path is unchanged by
# its absence, which is what lets it be a Recommends.
#
# Index
#   cryptx_missing   undef when CryptX loads, else the sentence to show
#   NEEDS            the sentence itself, for a caller that words its own refusal

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(cryptx_missing);

our $NEEDS = 'Passkeys and web push need the CryptX library on the server '
    . '(Debian package libcryptx-perl), which is not installed. Ask the site operator to install it.';

my $LOADED;    # undef = not asked yet; 1 = loads; 0 = does not

# undef when CryptX's public-key classes load, the sentence otherwise. Asked once
# per process: a module that failed to load will not load on the second asking.
sub cryptx_missing {
    unless ( defined $LOADED ) {
        local $@;
        $LOADED = eval { require Crypt::PK::ECC; 1 } ? 1 : 0;
    }
    return $LOADED ? undef : $NEEDS;
}

sub NEEDS { return $NEEDS }

1;
