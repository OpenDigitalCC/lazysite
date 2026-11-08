package PasskeyFixture;

# SM1352: an authenticator, in the test. Keys are made with CryptX here, and the
# two answers a browser gives - to navigator.credentials.create (attestation
# 'none', the key from getPublicKey() as SPKI DER) and to .get (a signature over
# authenticator data || SHA-256(client data)) - are built byte for byte as the
# WebAuthn spec lays them out, so the engine verifies exactly what a phone sends.
#
#   my $k = PasskeyFixture::key(-7);            # -7 ES256, -257 RS256, -8 EdDSA
#   my %reg = PasskeyFixture::created( $k, challenge => $c, origin => $o, rp => $rp );
#   my %get = PasskeyFixture::asserted( $k, challenge => $c, origin => $o, rp => $rp, count => 1 );
#   PasskeyFixture::form(%get)                  # application/x-www-form-urlencoded

use strict;
use warnings;
use Digest::SHA  qw(sha256);
use JSON::PP     ();
use MIME::Base64 ();

sub b64u { return MIME::Base64::encode_base64url( $_[0] ) }

sub key {
    my ($alg) = @_;
    my $pk;
    if ( $alg == -7 ) {
        require Crypt::PK::ECC;
        $pk = Crypt::PK::ECC->new;
        $pk->generate_key('secp256r1');
    }
    elsif ( $alg == -257 ) {
        require Crypt::PK::RSA;
        $pk = Crypt::PK::RSA->new;
        $pk->generate_key( 256, 65537 );
    }
    else {
        require Crypt::PK::Ed25519;
        $pk = Crypt::PK::Ed25519->new;
        $pk->generate_key;
    }
    my $id = join '', map { chr int rand 256 } 1 .. 32;
    return { pk => $pk, alg => $alg, id => b64u($id), spki => $pk->export_key_der('public') };
}

sub _client_data {
    my (%o) = @_;
    return JSON::PP->new->canonical->encode( {
            type => $o{type}, challenge => $o{challenge}, origin => $o{origin}, crossOrigin => JSON::PP::false() } );
}

# Authenticator data's head: RP ID hash, flags (user present + verified), counter.
sub _auth_data {
    my (%o) = @_;
    return sha256( $o{rp} ) . chr( $o{flags} // 0x05 ) . pack( 'N', $o{count} // 0 );
}

# The fields navigator.credentials.create's answer gives the page.
sub created {
    my ( $k, %o ) = @_;
    my $cd = _client_data( type => $o{type} // 'webauthn.create', challenge => $o{challenge}, origin => $o{origin} );
    return (
        id                 => $k->{id},
        client_data        => b64u($cd),
        authenticator_data => b64u( _auth_data( rp => $o{rp}, flags => $o{flags}, count => 0 ) ),
        public_key         => b64u( $o{spki} // $k->{spki} ),
        alg                => $o{alg} // $k->{alg},
        label              => $o{label} // 'test phone',
    );
}

# The fields navigator.credentials.get's answer gives the page, signed by $k
# (or by $o{signer}, for a wrong signature).
sub asserted {
    my ( $k, %o ) = @_;
    my $cd  = _client_data( type => $o{type} // 'webauthn.get', challenge => $o{challenge}, origin => $o{origin} );
    my $ad  = _auth_data( rp => $o{rp}, flags => $o{flags}, count => $o{count} // 1 );
    my $msg = $ad . sha256($cd);
    my $s   = $o{signer} // $k;
    my $sig = $s->{alg} == -7 ? $s->{pk}->sign_message( $msg, 'SHA256' )
        : $s->{alg} == -257 ? $s->{pk}->sign_message( $msg, 'SHA256', 'v1.5' )
        :                     $s->{pk}->sign_message($msg);
    return (
        pk_id                 => $o{id} // $k->{id},
        pk_client_data        => b64u($cd),
        pk_authenticator_data => b64u($ad),
        pk_signature          => b64u($sig),
    );
}

# The stored form of a key, as passkey-add takes it.
sub stored {
    my ( $k, %o ) = @_;
    return { id => $k->{id}, key => b64u( $k->{spki} ), alg => $k->{alg}, label => $o{label} // 'fixture',
        count => $o{count} // 0 };
}

sub form {
    my (%f) = @_;
    my $enc = sub { my $v = shift // ''; $v =~ s/([^A-Za-z0-9_.~-])/sprintf '%%%02X', ord $1/ge; $v };
    return join '&', map { $enc->($_) . '=' . $enc->( $f{$_} ) } sort keys %f;
}

1;
