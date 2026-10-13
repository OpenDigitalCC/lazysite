package Lazysite::Odoo::Identity;

# SM747 C (OI1-OI4): WHO A SIGNED-IN PERSON IS IN ODOO, FOR A PAGE TO PRESENT -
# AND FOR NOTHING ELSE.
#
# THE RULE (OI4), in the code and in the docs: this is identity context for
# PRESENTATION ONLY, never for authorisation. Hiding a button from somebody who is
# not a manager is a convenience; the call still goes to Odoo if it is made, and
# Odoo is what refuses it. Nothing in the engine reads this cookie to permit
# anything: a call is run (or refused) on the person's SESSION (Lazysite::Odoo::
# Session), which Odoo checks. A path that used this to permit rather than to
# present would be a defect.
#
# It rides in a SECOND cookie, distinct from the credential (OI2):
#
#   * it is signed with the extension's secret, under a label of its own, so a
#     tampered one is rejected and a session cookie's signature cannot be
#     replayed as an identity;
#   * it is dated inside the signature and ends in `odoo_identity_ttl` seconds
#     (default 900): groups and companies change in Odoo and a cookie does not
#     know, so it is refreshed from the session on the next call after it ends;
#   * it carries a name, a language, a time zone, the companies and the groups -
#     never the session id, a user id, a login, an admin flag or anything a call
#     could be authorised by;
#   * HttpOnly (page script does not read it), SameSite=Lax (a link from another
#     site still greets the person; it carries nothing that can act), Secure over
#     HTTPS, and Max-Age the TTL.
use strict;
use warnings;
use JSON::PP       ();
use MIME::Base64   qw(encode_base64 decode_base64);
use Digest::SHA    qw(hmac_sha256_hex);
use Lazysite::Util qw(const_eq);

our $COOKIE   = 'lzs_odoo_identity';
our $TTL      = 900;
our $MAX_SIZE = 1500;                  # a cookie value, well inside a browser's 4 KB

sub _secret {
    require Lazysite::Odoo::Visitor;
    return Lazysite::Odoo::Visitor::secret();
}

sub _sig {
    my ( $body, $at, $secret ) = @_;
    return hmac_sha256_hex( "odoo-identity|$body|$at", $secret );
}

# What a page may be shown, from whatever the caller holds: only these keys, only
# plain values. Anything else is dropped here, so a field added to what OOM
# returns reaches a page only by being named below.
sub present {
    my ($id) = @_;
    return undef unless ref $id eq 'HASH';
    my %o;
    for my $k (qw(name lang tz)) {
        $o{$k} = "$id->{$k}" if defined $id->{$k} && !ref $id->{$k} && length $id->{$k};
    }
    $o{company_id} = 0 + $id->{company_id} if defined $id->{company_id} && !ref $id->{company_id} && $id->{company_id} =~ /\A[0-9]+\z/;
    $o{company_ids} = [ map { 0 + $_ } grep { defined && !ref && /\A[0-9]+\z/ } @{ ref $id->{company_ids} eq 'ARRAY' ? $id->{company_ids} : [] } ];
    $o{groups} = [ map { "$_" } grep { defined && !ref && length } @{ ref $id->{groups} eq 'ARRAY' ? $id->{groups} : [] } ];
    return \%o;
}

sub _b64u {
    my ($raw) = @_;
    my $s = encode_base64( $raw, '' );
    $s =~ tr{+/}{-_};
    $s =~ s/=+\z//;
    return $s;
}

sub _unb64u {
    my ($s) = @_;
    $s =~ tr{-_}{+/};
    $s .= '=' x ( ( 4 - length($s) % 4 ) % 4 );
    return decode_base64($s);
}

# The cookie value for an identity: body, the time it was minted, a signature over
# both. undef when there is nothing to carry, no secret, or it would not fit.
sub mint_cookie {
    my ( $id, %o ) = @_;
    my $p = present($id) // return undef;
    return undef unless %$p;
    my $secret = _secret() // return undef;
    my $body   = _b64u( JSON::PP->new->utf8->canonical->encode($p) );
    return undef if length($body) > $MAX_SIZE;
    my $at = $o{now} // time;
    return "$body.$at." . _sig( $body, $at, $secret );
}

# The identity a Cookie header carries: when this server minted it and it is
# inside its TTL. undef otherwise - and a page then renders as though nobody had
# signed in, which is the safe reading of a cookie that cannot be trusted.
sub identity_from_cookie {
    my ( $header, %o ) = @_;
    return undef unless defined $header && length $header;
    my ($v) = $header =~ m{(?:\A|;\s*) \Q$COOKIE\E = ( [A-Za-z0-9_-]{2,2100} [.] [0-9]{1,12} [.] [0-9a-f]{64} ) (?:;|\z)}x;
    return undef unless defined $v;
    my ( $body, $at, $sig ) = split /[.]/, $v, 3;
    my $secret = _secret() // return undef;
    return undef unless const_eq( $sig, _sig( $body, $at, $secret ) );
    my $now = $o{now} // time;
    my $ttl = $o{ttl} // $TTL;
    return undef if $at > $now + 60 || $now - $at > $ttl;
    my $d = eval { JSON::PP->new->utf8->decode( _unb64u($body) ) };
    return present($d);
}

sub set_cookie_header {
    my ( $cookie, %o ) = @_;
    my $ttl = ( defined $o{ttl} && $o{ttl} =~ /\A[0-9]+\z/ ) ? $o{ttl} : $TTL;
    return "Set-Cookie: $COOKIE=$cookie; Path=/; HttpOnly; SameSite=Lax; Max-Age=$ttl" . ( $o{secure} ? '; Secure' : '' );
}

sub clear_cookie_header {
    my (%o) = @_;
    return "Set-Cookie: $COOKIE=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT"
        . ( $o{secure} ? '; Secure' : '' );
}

1;
